-- dronage-norns euclidean sequencer (per-voice). Params-only for now (UI later).
--
-- Model (per doc 07, nullsek + dronage-move union):
--   STEPS: option "drone, 2..16" - ONE control sets both mode and length. drone = sustained (no
--          stepping); 2..16 = euclidean STEP mode of that length.
--   FILL (triggers), SHIFT (rotation), PADDING (empty cells), RATE (6 multipliers), PROBABILITY.
-- Pattern = runtime Bjorklund (canonical: first hit at index 0), then nullsek pad-then-rotate.
-- Stepping = a fine clock loop; on a hit step (passing the probability dice) we fire engine.trig(v),
-- which plucks the voice's per-step perc env (SC side). The slow gate-AHD stays the voice on/off.

local cs = require "controlspec"
local D = include("dronage-norns/lib/dronage_norns_defaults")
local options = include("dronage-norns/lib/dronage_norns_options")   -- keyed (reorder/rename-safe) option params
local M = {}

M.NUM = 4
M.running = true
M.tracks = {}
-- RATE multipliers (nullsek): step duration in beats = 0.25 / mult  (so 1x = a 16th note).
M.RATES = { 0.25, 0.5, 0.75, 1.0, 1.5, 2.0 }
M.RATE_LABELS = { "1/4x", "1/2x", "3/4x", "1x", "1.5x", "2x" }

-- Bjorklund (classic bucket-merge); returns a boolean list of length `steps`.
local function bjorklund(hits, steps)
  if hits <= 0 then local t = {}; for i = 1, steps do t[i] = false end; return t end
  if hits >= steps then local t = {}; for i = 1, steps do t[i] = true end; return t end
  local pattern = {}; for i = 1, hits do pattern[i] = { true } end
  local remainder = {}; for i = 1, steps - hits do remainder[i] = { false } end
  while #remainder > 1 do
    local take = math.min(#remainder, #pattern)
    for i = 1, take do
      local r = table.remove(remainder)                 -- pop last
      for _, b in ipairs(r) do pattern[i][#pattern[i] + 1] = b end
    end
    if #pattern > take then                              -- split_off(take)
      local newrem = {}
      for i = take + 1, #pattern do newrem[#newrem + 1] = pattern[i] end
      for i = #pattern, take + 1, -1 do pattern[i] = nil end
      remainder = newrem
    end
  end
  local out = {}
  for _, bucket in ipairs(pattern) do for _, b in ipairs(bucket) do out[#out + 1] = b end end
  for _, bucket in ipairs(remainder) do for _, b in ipairs(bucket) do out[#out + 1] = b end end
  return out
end

-- rotate so the first hit sits at index 1 (canonical, like nullsek's stored masks)
local function canonical(p)
  local fh; for i = 1, #p do if p[i] then fh = i; break end end
  if not fh or fh == 1 then return p end
  local r = {}; for i = 0, #p - 1 do r[i + 1] = p[((fh - 1 + i) % #p) + 1] end
  return r
end

-- (re)build a voice's live pattern from its params. e.steps: 0 = drone, else N steps.
function M.build_pattern(v)
  local e = M.tracks[v]
  if e.steps < 2 then e.pattern = {}; e.patLen = 0; return end   -- drone / degenerate
  local nsteps = e.steps
  local base = canonical(bjorklund(util.clamp(e.triggers, 0, nsteps), nsteps))
  local total = math.min(nsteps + e.padding, 32)
  local pat = {}
  for i = 0, total - 1 do
    local src = (i - e.shift) % total           -- Lua % is floored for positive total
    pat[i + 1] = (src < nsteps) and base[src + 1] or false   -- pad cells (src>=nsteps) are rests
  end
  e.pattern, e.patLen = pat, total
end

-- advance all voices from the (transport-relative) beat position; fire triggers on hit steps.
-- RESET: the step counter hard-restarts to step 0 every `reset` BEATS, regardless of pattern length,
-- so the sequence stays phrase-locked and never drifts. Since `beats` is transport-relative, the
-- reset cycle (and step 0) also restart on every PLAY edge - same as the LFOs.
function M.advance(beats)
  if not M.running then return end
  local flushed = false   -- refresh mods at most once per grid tick, and only when something fires
  for v = 1, M.NUM do
    local e = M.tracks[v]
    if e.patLen and e.patLen > 0 then
      local stepDur = 0.25 / (M.RATES[e.rate] or 1.0)
      local cyc = math.floor(beats / e.reset)             -- which reset window
      local win = beats - cyc * e.reset                   -- beats into this window
      local siw = math.floor(win / stepDur)               -- step index within the window
      if cyc ~= e.prev_cyc then e.prev_cyc = cyc; e.prev_siw = -1 end   -- new window -> restart at 0
      if siw > e.prev_siw then
        e.prev_siw = siw
        local step = siw % e.patLen
        e.cur_step = step
        if e.pattern[step + 1] and (e.prob >= 1.0 or math.random() < e.prob) then
          -- fresh mods BEFORE the trigger (dronage-tui order): the synth samples pitch at the hit,
          -- so the S&H step landing on this exact beat must already be in the engine.
          if M.pre_trig and not flushed then M.pre_trig(); flushed = true end
          engine.trig(v)
          if M.on_trig then M.on_trig(v) end   -- optional observer (grid pad pings), post-probability
        end
      end
    end
  end
end

function M.add_params(num_voices)
  M.NUM = num_voices
  local stepopts = { "drone" }; for n = 2, 16 do stepopts[#stepopts + 1] = tostring(n) end
  for v = 1, num_voices do
    M.tracks[v] = { steps = 0, triggers = D.euclid.fill, shift = D.euclid.shift, padding = D.euclid.padding,
                    rate = D.euclid.rate, prob = D.euclid.prob, reset = D.euclid.reset,
                    pattern = {}, patLen = 0, prev_cyc = -1, prev_siw = -1, cur_step = 0 }
    local e = M.tracks[v]
    params:add_separator("dronage_euclid_" .. v, "euclid " .. v)

    -- one knob = mode + length: idx1 drone, idx2..16 -> 2..16 steps
    params:add{ type = "option", id = "v" .. v .. "_esteps", name = "steps", options = options.labels("esteps"), default = D.euclid.steps,
      action = function(idx) local val = options.value("v" .. v .. "_esteps", idx); e.steps = (val == 1) and 0 or val; M.build_pattern(v)
        engine.seqmode(v, e.steps >= 2 and 1 or 0) end }

    params:add{ type = "control", id = "v" .. v .. "_etrig", name = "fill",
      controlspec = cs.new(0, 16, "lin", 1, D.euclid.fill, ""),
      action = function(val) e.triggers = util.round(val); M.build_pattern(v) end }

    params:add{ type = "control", id = "v" .. v .. "_eshift", name = "shift",
      controlspec = cs.new(-16, 16, "lin", 1, D.euclid.shift, ""),
      action = function(val) e.shift = util.round(val); M.build_pattern(v) end }

    params:add{ type = "control", id = "v" .. v .. "_epad", name = "padding",
      controlspec = cs.new(0, 16, "lin", 1, D.euclid.padding, ""),
      action = function(val) e.padding = util.round(val); M.build_pattern(v) end }

    params:add{ type = "control", id = "v" .. v .. "_ereset", name = "reset (beats)",
      controlspec = cs.new(1, 64, "lin", 1, D.euclid.reset, ""),
      action = function(val) e.reset = util.round(val) end }

    params:add{ type = "option", id = "v" .. v .. "_erate", name = "rate",
      options = options.labels("erate"), default = D.euclid.rate,
      action = function(idx) e.rate = options.value("v" .. v .. "_erate", idx) end }

    params:add{ type = "control", id = "v" .. v .. "_eprob", name = "probability",
      controlspec = cs.new(0, 1, "lin", 0, D.euclid.prob, ""),
      action = function(val) e.prob = val end }

    -- LPG (Plaits' low-pass gate). colour drives filtering + resonance together (knob up = more of
    -- both, dronage-move direction); decay = the ring/pluck length. BOTH are no-ops in drone mode -
    -- the engine forces the LPG transparent unless steps >= 2 - so they only shape euclidean plucks.
    params:add{ type = "control", id = "v" .. v .. "_lpgcol", name = "lpg color",
      controlspec = cs.new(0, 1, "lin", 0, D.euclid.lpgcol, ""),
      action = function(val) engine.lpgColour(v, val) end }

    params:add{ type = "control", id = "v" .. v .. "_lpgdecay", name = "lpg decay",
      controlspec = cs.new(0.01, 4, "exp", 0, D.euclid.lpgdecay, "s"),
      action = function(val) engine.lpgdecay(v, val) end }
  end
end

-- transport PLAY: re-zero every voice's reset cycle + step counter so it restarts on step 0.
function M.reset()
  for v = 1, M.NUM do
    local e = M.tracks[v]
    if e then e.prev_cyc = -1; e.prev_siw = -1; e.cur_step = 0 end
  end
end

return M
