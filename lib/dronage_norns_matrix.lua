-- dronage-norns modulation matrix
-- 8 LFO sources -> N destinations, summed ADDITIVELY in normalized 0..1 space over
-- each destination's base (knob) value, then written to the engine each tick. SC-side
-- Lag in the engine smooths.
--
-- Each LFO: Waveform (Sine/Tri/Saw+/Saw-/Square/S&H RND/S&H SEED) + Rate (sync division
-- or free Hz) + Phase + Skew + Smoothing(=glide on S&H) + Length + Variation, plus
-- Polarity & Sync toggles. ONE global seed -> a shared 32-value base table; each S&H SEED
-- reader owns a walked copy (Variation) so readers never corrupt each other. See
-- plans/lfo-refactor.md.

local cs = require "controlspec"
local D = include("dronage-norns/lib/dronage_norns_defaults")
local options = include("dronage-norns/lib/dronage_norns_options")   -- keyed (reorder/rename-safe) option params

local M = {}

M.NUM_SRC = 8
M.tick_hz = 120   -- mod-engine sample rate; Nyquist 60Hz = the LFO rate cap (was 60/30)
M.depth = 1.0            -- global mod-depth master (0..1)
M.shapes = { "sine", "tri", "saw+", "saw-", "square", "sh rnd", "sh seed" }
M.src = {}              -- 8 sources, each .value in -1..1 (or 0..1 if unipolar)
M.dests = {}            -- list of {param_id, cmd, voice, label}
M.cell = {}             -- cell[d][s] signed depth -1..1
M.dest_active = {}      -- d -> bool (any non-zero cell) so we only write modulated dests

M.seed = 0              -- global S&H seed (0..4095); boot-randomized by host
M.anchor = true         -- "S&H step 1 = home": pin SEED reader step-0 output to 0
M.sh_base = {}          -- shared 32-value base table (regenerated on seed change)
M.SH_MAX = 32

M.HIST_LEN = 128        -- per-LFO output history (for the scope view); ~2.1 s @ 60 Hz
M.hist = {}             -- hist[s][1..HIST_LEN] ring of past .value
M.hist_ptr = 0          -- newest sample index

-- tempo-sync division list (slow -> fast), cycle length in beats (1 beat = 1/4 note)
M.div_names = { "8 bar","4 bar","2 bar","1 bar","1/2.","1/2","1/4.","1/2T","1/4",
                "1/8.","1/4T","1/8","1/16.","1/8T","1/16","1/32.","1/16T","1/32","1/32T" }
local DIV_BEATS = { 32,16,8,4, 3,2,1.5,4/3,1, 0.75,2/3,0.5,0.375,1/3,0.25, 0.1875,1/6,0.125,1/12 }
M.div_beats = DIV_BEATS  -- exposed: beats-per-cycle per division (for the delay's division->samples)
local DIV_DEFAULT = D.lfo.div   -- "1/4"

-- ---- deterministic PRNG: xorshift32 seeded from an int (reproducible S&H) ----
local function rng_new(seed)
  local s = ((seed & 0xFFFFFFFF) * 2654435761) & 0xFFFFFFFF
  if s == 0 then s = 0x9E3779B9 end
  return s
end
local function rng_next(s)
  s = s ~ ((s << 13) & 0xFFFFFFFF)
  s = s ~ (s >> 17)
  s = s ~ ((s << 5) & 0xFFFFFFFF)
  return s & 0xFFFFFFFF
end
local function rng01(s)            -- advance src rng, return 0..1
  s.rng_state = rng_next(s.rng_state)
  return s.rng_state / 4294967296.0
end

-- regenerate the shared base table from the global seed
function M.regen_base()
  local st = rng_new((M.seed or 0) + 1)
  for i = 1, M.SH_MAX do
    st = rng_next(st)
    M.sh_base[i] = (st / 4294967296.0) * 2 - 1
  end
end

-- reset an S&H reader: copy base[1..length] into its walked copy, reseed RND hold, and rewind the
-- stepper to step 0. cyc/prevp MUST rewind too: cyc is the wrap counter the step index derives from
-- (st = cyc % length), and a stale prevp makes the phase re-zero on PLAY read as an extra wrap - both
-- made every transport start resume the seeded melody from an arbitrary step (and broke "start at 0").
local function src_reset_sh(s)
  s.copy = {}
  for i = 1, s.length do s.copy[i] = M.sh_base[i] or 0 end
  s.step = -1
  s.cyc = 0
  s.prevp = 0
  s.held = rng01(s) * 2 - 1      -- RND holds a value until Variation walks it (SEED overwrites per step)
  s.prev_held = s.held
end

-- phase warp around a movable midpoint (skew -1..+1; 0 = identity)
local function warp(p, skew)
  if skew == 0 then return p end
  local m = 0.5 * (skew + 1)
  if m < 0.001 then m = 0.001 elseif m > 0.999 then m = 0.999 end
  if p < m then return 0.5 * (p / m) else return 0.5 + 0.5 * (p - m) / (1 - m) end
end

-- S&H step glide (nullSEK / grampus interpolate_sh): Smoothing morphs a hard step (0) -> linear
-- glide (0.5) -> cosine S-curve (1), glided over the step phase. SYMMETRIC up/down (no exp tail).
local function interpolate_sh(step_phase, smo, prev, held)
  local transition = math.min(smo * 2, 1)        -- 0..0.5: glide window grows 0 -> the full step
  local curve = math.max((smo - 0.5) * 2, 0)     -- 0.5..1: linear -> cosine blend
  local rawt = 1
  if transition >= 1 then rawt = step_phase
  elseif step_phase < transition then rawt = step_phase / transition end
  local easedt = 0.5 - 0.5 * math.cos(rawt * math.pi)
  local t = rawt + (easedt - rawt) * curve
  return prev + (held - prev) * t
end

-- one tick of one LFO. `beats` = clock.get_beats() for synced rate.
local function src_compute(s, dt, beats)
  -- 1. phasor: ONE cycle = one wave period (continuous) OR one held S&H step. So Rate/Div is the
  --    per-step duration for S&H ("a held sample is one cycle"); the loop is Length steps long.
  if s.sync then
    s.phase = (beats / DIV_BEATS[s.rate_div]) % 1.0
  else
    s.phase = (s.phase + dt * s.rate_free) % 1.0
  end
  -- phase offset: for S&H SEED the knob spans the WHOLE loop (100% = Length steps; whole steps
  -- rotate the sequence, the fraction shifts within a step). Everywhere else - continuous waves and
  -- S&H RND (no step table to rotate) - it spans one cycle/held step, as before.
  local off, step_add = s.phase_off, 0
  if s.shape == 7 then
    local t = s.phase_off * s.length
    step_add = math.floor(t)
    off = t - step_add
  end
  local p = warp((s.phase + off) % 1.0, s.skew)   -- phase offset + skew
  local wrapped = p < s.prevp
  s.prevp = p

  -- 2. waveform -> raw in [-1,1]
  local shp = s.shape
  local raw
  if shp < 6 then                                         -- continuous waves
    if shp == 1 then raw = math.sin(2 * math.pi * p)
    elseif shp == 2 then raw = (p < 0.5) and (4 * p - 1) or (3 - 4 * p)
    elseif shp == 3 then raw = 2 * p - 1
    elseif shp == 4 then raw = 1 - 2 * p
    else raw = (p < 0.5) and 1 or -1 end                  -- 5 = square
  else                                                    -- S&H: count phasor cycles -> step (mod Length)
    if wrapped then s.cyc = s.cyc + 1 end
    local st = (s.cyc + step_add) % s.length
    if st ~= s.step then                                  -- new step: shift held -> prev, make new held
      s.prev_held = s.held
      if shp == 6 then                                    -- S&H RND: random walk (Variation = step size)
        s.held = util.clamp(s.held + (rng01(s) * 2 - 1) * s.variation, -1, 1)
      else                                                -- S&H SEED: looped table; Mutate walks it (Turing)
        if s.mutate > 0 then
          s.copy[st + 1] = util.clamp((s.copy[st + 1] or 0) + (rng01(s) * 2 - 1) * s.mutate, -1, 1)
        end
        s.held = (M.anchor and st == 0) and 0 or (s.copy[st + 1] or 0)
      end
      s.step = st
    end
    raw = interpolate_sh(p, s.smooth, s.prev_held, s.held)   -- hard -> linear -> cosine step glide
  end

  -- 3. smoothing: S&H is glided above; continuous waves use a 2-pole LP (symmetric S-curve, no exp tail)
  local out
  if shp >= 6 or s.smooth <= 0 then
    out, s.sm, s.sm2 = raw, raw, raw                      -- no LP / keep state fresh for wave-switching
  else
    local coef = 1 - math.exp(-dt / (0.01 * (100 ^ s.smooth)))
    s.sm = s.sm + coef * (raw - s.sm)                     -- pole 1
    s.sm2 = s.sm2 + coef * (s.sm - s.sm2)                 -- pole 2 -> symmetric S-curve
    out = s.sm2
  end

  -- 4. polarity (M toggle): unipolar 0..1 or bipolar -1..1
  s.value = s.uni and (out * 0.5 + 0.5) or out
  return s.value
end

-- ---- destinations: per-voice continuous params ----
-- Master per-voice dest registry: every param the matrix/seq/macro can modulate. Appended
-- "hpcut" + "lpgdecay" so the shared macro/seq target list (dronage-tui parity) resolves via
-- dest_index. (chorus stays a matrix LFO dest, but is excluded from the macro/seq target list.)
local DEST_PARAMS = { "harm", "timbre", "morph", "pitch", "tune", "level", "pan", "cut", "res", "drive", "chorus", "dlysend", "hpcut", "lpgdecay", "reverbsend" }

function M.init(num_voices)
  M.regen_base()
  for s = 1, M.NUM_SRC do
    M.src[s] = { shape = D.lfo.shape, sync = false, rate_free = D.lfo.rate(s), rate_div = D.lfo.div,
                 phase_off = D.lfo.phase, skew = D.lfo.skew, smooth = D.lfo.smooth,
                 length = D.lfo.length, variation = D.lfo.variation, mutate = D.lfo.mutate, uni = false,
                 phase = (s - 1) / M.NUM_SRC, value = 0, sm = 0, sm2 = 0,
                 step = -1, copy = {}, cyc = 0, prevp = 0, held = 0, prev_held = 0,
                 rng_state = rng_new(0x2000 + s) }
    src_reset_sh(M.src[s])
  end
  M.hist = {}
  for s = 1, M.NUM_SRC do
    M.hist[s] = {}
    for i = 1, M.HIST_LEN do M.hist[s][i] = 0 end
  end
  M.hist_ptr = 0
  M.dests = {}
  for v = 1, num_voices do
    for _, p in ipairs(DEST_PARAMS) do
      table.insert(M.dests, { param_id = "v" .. v .. "_" .. p, cmd = p, voice = v,
                              label = v .. " " .. p })
    end
  end
  for d = 1, #M.dests do
    M.cell[d] = {}
    for s = 1, M.NUM_SRC do M.cell[d][s] = 0 end
    M.dest_active[d] = false
  end
end

-- find a destination index by (voice, param-name)
function M.dest_index(voice, pname)
  for i, d in ipairs(M.dests) do
    if d.voice == voice and d.cmd == pname then return i end
  end
  return 1
end

-- strict lookup for save/load: returns nil (not a fallback) if (voice, cmd) no longer exists,
-- so loading a save whose target was removed skips it instead of corrupting dest 1.
function M.find_dest(voice, cmd)
  for i, d in ipairs(M.dests) do
    if d.voice == voice and d.cmd == cmd then return i end
  end
  return nil
end

function M.set_cell(d, s, depth)
  M.cell[d][s] = util.clamp(depth, -1, 1)
  local active = false
  for i = 1, M.NUM_SRC do if M.cell[d][i] ~= 0 then active = true break end end
  M.dest_active[d] = active
end

-- show/hide context-dependent params (S&H-only + active rate mode). pcall-guarded by caller.
local function lfo_visibility(s)
  local sh = M.src[s].shape
  local synced = M.src[s].sync
  local function vis(id, on) if on then params:show(id) else params:hide(id) end end
  vis("lfo" .. s .. "_length", sh == 7)         -- loop length: S&H SEED only
  vis("lfo" .. s .. "_variation", sh == 6)      -- walk distance: S&H RND only
  vis("lfo" .. s .. "_mutate", sh == 7)         -- Turing mutation: S&H SEED only
  vis("lfo" .. s .. "_rate", not synced)
  vis("lfo" .. s .. "_div", synced)
  if _menu and _menu.rebuild_params then _menu.rebuild_params() end
end

function M.add_params()
  params:add_separator("dronage_mod", "mod matrix")
  params:add{ type = "control", id = "mod_depth", name = "mod depth",
    controlspec = cs.new(0, 1, "lin", 0, D.global.mod_depth, ""),
    action = function(v) M.depth = v end }
  params:add{ type = "number", id = "dronage_seed", name = "s+h seed (global)",
    min = 0, max = 4095, default = D.global.seed,
    action = function(v)
      M.seed = v; M.regen_base()
      for s = 1, M.NUM_SRC do src_reset_sh(M.src[s]) end
    end }
  params:add{ type = "option", id = "dronage_sh_anchor", name = "s+h seed start 0",
    options = options.labels("sh_anchor"), default = D.global.sh_anchor,
    action = function(v) M.anchor = options.value("dronage_sh_anchor", v) end }

  for s = 1, M.NUM_SRC do
    params:add_separator("lfo_" .. s, "lfo " .. s)
    params:add{ type = "option", id = "lfo" .. s .. "_shape", name = "shape",
      options = options.labels("shape"), default = D.lfo.shape,
      action = function(v) M.src[s].shape = options.value("lfo" .. s .. "_shape", v); pcall(lfo_visibility, s) end }
    params:add{ type = "option", id = "lfo" .. s .. "_sync", name = "sync",
      options = options.labels("sync"), default = D.lfo.sync,
      action = function(v) M.src[s].sync = options.value("lfo" .. s .. "_sync", v); pcall(lfo_visibility, s) end }
    params:add{ type = "control", id = "lfo" .. s .. "_rate", name = "rate",
      controlspec = cs.new(0.01, 60, "exp", 0, D.lfo.rate(s), "Hz"),   -- cap = tick Nyquist (120/2); >60 would alias
      action = function(v) M.src[s].rate_free = v end }
    params:add{ type = "option", id = "lfo" .. s .. "_div", name = "division",
      options = options.labels("div"), default = D.lfo.div,
      action = function(v) M.src[s].rate_div = options.value("lfo" .. s .. "_div", v) end }
    params:add{ type = "control", id = "lfo" .. s .. "_phase", name = "phase",
      controlspec = cs.new(0, 1, "lin", 0.00125, D.lfo.phase, "", 0.00125),   -- 0.125% detents
      action = function(v) M.src[s].phase_off = v end }
    params:add{ type = "control", id = "lfo" .. s .. "_skew", name = "skew",
      controlspec = cs.new(-1, 1, "lin", 0, D.lfo.skew, ""),
      action = function(v) M.src[s].skew = v end }
    params:add{ type = "control", id = "lfo" .. s .. "_smooth", name = "smoothing",
      controlspec = cs.new(0, 1, "lin", 0, D.lfo.smooth, ""),
      action = function(v) M.src[s].smooth = v end }
    params:add{ type = "number", id = "lfo" .. s .. "_length", name = "s+h length",
      min = 2, max = M.SH_MAX, default = D.lfo.length,
      action = function(v) M.src[s].length = v; src_reset_sh(M.src[s]) end }
    params:add{ type = "control", id = "lfo" .. s .. "_variation", name = "s+h variation",
      controlspec = cs.new(0, 1, "lin", 0, D.lfo.variation, ""),
      action = function(v) M.src[s].variation = v end }
    params:add{ type = "control", id = "lfo" .. s .. "_mutate", name = "s+h mutate",
      controlspec = cs.new(0, 1, "lin", 0, D.lfo.mutate, ""),
      action = function(v) M.src[s].mutate = v end }
    params:add{ type = "option", id = "lfo" .. s .. "_polarity", name = "polarity",
      options = options.labels("polarity"), default = D.lfo.polarity,
      action = function(v) M.src[s].uni = options.value("lfo" .. s .. "_polarity", v) end }
  end
end

-- transport PLAY: reset every LFO cycle to the top. Synced LFOs re-zero automatically because the
-- host passes a transport-relative beat (phase = beats/div), so we only need to home the FREE
-- accumulators + the S&H readers (the "step 1 = home" anchor).
function M.reset_phases()
  for s = 1, M.NUM_SRC do
    M.src[s].phase = 0
    src_reset_sh(M.src[s])
  end
end

-- advance the LFO phases (call once per control tick). beats = clock.get_beats() for sync.
local hist_skip = false
function M.advance(dt, beats)
  beats = beats or 0
  -- scope history decimation: keep the ~2.1s window (128 samples @ ~60/s) now that the tick is
  -- 120Hz - push every OTHER real tick. dt=0 flushes (euclid pre-trigger) never push.
  local push = dt > 0
  if push then hist_skip = not hist_skip; push = hist_skip end
  local p = M.hist_ptr
  if push then
    M.hist_ptr = M.hist_ptr % M.HIST_LEN + 1
    p = M.hist_ptr
  end
  for s = 1, M.NUM_SRC do
    src_compute(M.src[s], dt, beats)
    if push then M.hist[s][p] = M.src[s].value end
  end
end

-- add this matrix's LFO contributions (normalized offsets) into the shared acc[dest].
-- The engine write is done by the host (so the CV sequencer can sum into the same acc).
function M.accumulate(acc)
  for d = 1, #M.dests do
    if M.dest_active[d] then
      local row, a = M.cell[d], 0
      for s = 1, M.NUM_SRC do
        local c = row[s]
        if c ~= 0 then a = a + M.src[s].value * c end
      end
      acc[d] = (acc[d] or 0) + a * M.depth
    end
  end
end

-- serialize / restore matrix routing (cells + master depth) for scenes.
-- Per-LFO shaping + global seed/anchor are plain params -> handled by the scene param snapshot.
-- cells are keyed by "<voice>:<cmd>" (string) so reordering DEST_PARAMS never remaps saved cells.
function M.dump()
  local t = { cell = {}, depth = M.depth }
  for d = 1, #M.dests do
    local de = M.dests[d]
    local row = {}
    for s = 1, M.NUM_SRC do row[s] = M.cell[d][s] end
    t.cell[de.voice .. ":" .. de.cmd] = row
  end
  return t
end
function M.load(t)
  if not t then return end
  M.depth = t.depth or M.depth
  for d = 1, #M.dests do
    for s = 1, M.NUM_SRC do M.cell[d][s] = 0 end
    M.dest_active[d] = false
  end
  if t.cell then
    for key, row in pairs(t.cell) do
      local vs, cmd = string.match(key, "^(%d+):(.+)$")
      local d = vs and M.find_dest(tonumber(vs), cmd)   -- nil-skips removed/unknown targets
      if d then for s = 1, M.NUM_SRC do M.set_cell(d, s, row[s] or 0) end end
    end
  end
end

return M
