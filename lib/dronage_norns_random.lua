-- dronage-norns PAGE RANDOMIZER: K1+K2+K3 rolls curated dice for the CURRENT view.
--
-- Per-page rules (agreed 2026-07-04):
--   HOME / PROJECT   nothing.
--   VOICE i          model (all 28) + harmonics/timbre/morph.
--   EUCLID i         everything; steps never "drone"; total length (steps+padding) favors
--                    8/16/32 half the time; padding > steps rare; full fills rare.
--   LFO s            everything EXCEPT mutate; sync 75% ON. S&H SEED is sticky: press A rolls
--                    the (global!) seed only, press B rolls seed + length + div, alternating.
--   MOD MATRIX       the focused voice's routing only. Presses alternate: A = fresh sparse
--                    batch (replace), B = another sparse batch on top (overlay). A batch =
--                    3-5 of the 10 visible params, one distinct LFO each, ~10% one doubles up.
--   DELAY            everything, full range.       REVERB   shimmer 10%-steps, size/time ints.
--   MASTER FX        tape age + hiss only.         MACRO    3 slots, depths ±25% steps.
--   CV SEQUENCER     the cursor's track only; dest depths ±25% steps.
--   SCENES           recall another populated scene (none -> no-op).
--   GLOBAL           root + scale (never Off/Chromatic) + s&h seed.
-- GENERAL RULE: every percentage-style param lands on whole percents.
--
-- Every roll runs inside undo.around(), so K2+E1 steps straight back over it.

local options = include("dronage-norns/lib/dronage_norns_options")

local M = {}
local C   -- injected: { mtx, seq, mac, scenes, undo }

function M.init(ctx) C = ctx; M.C = ctx end   -- C exposed for maiden-REPL inspection

-- ---------- alternating-press phase (matrix replace/overlay, S&H SEED a/b) ----------
-- Key = target identity ("lfo3" / "mtx2"). A different key OR any navigation (the screens
-- module calls M.nav) re-arms phase A, so "second press" always means "again, right here".
local last_key, phase_b = nil, false
function M.nav() last_key = nil end
local function flip(key)
  phase_b = (key == last_key) and (not phase_b) or false
  last_key = key
  return phase_b   -- false = press A, true = press B
end

-- ---------- dice ----------
local function pct(lo, hi) return math.random(lo, hi) / 100 end   -- whole percents only
local function sig(x) return (math.random() < 0.5) and -x or x end
local function pick(t)   -- weighted choice: { {item, weight}, ... }
  local sum = 0
  for _, e in ipairs(t) do sum = sum + e[2] end
  local r = math.random() * sum
  for _, e in ipairs(t) do r = r - e[2]; if r <= 0 then return e[1] end end
  return t[#t][1]
end
local function shuffled(n)
  local t = {}
  for i = 1, n do t[i] = i end
  for i = n, 2, -1 do local j = math.random(i); t[i], t[j] = t[j], t[i] end
  return t
end

-- ---------- VOICE ----------
local function rand_voice(v)
  params:set("v" .. v .. "_model", math.random(1, #options.sets.model.entries))
  params:set("v" .. v .. "_harm", pct(0, 100))
  params:set("v" .. v .. "_timbre", pct(0, 100))
  params:set("v" .. v .. "_morph", pct(0, 100))
end

-- ---------- EUCLID ----------
local function rand_euclid(v)
  -- total pattern length: 50% a musical anchor {8,16,32}, else free 3..24
  local L = (math.random() < 0.5) and pick({ {8,40}, {16,40}, {32,20} }) or math.random(3, 24)
  -- split into steps (2..16) + padding: pad=0 45% / small pad 45% / padding-heavy ~10%
  local steps, pad
  if L > 16 then                       -- long patterns force padding (steps caps at 16)
    steps = (math.random() < 0.90) and 16 or math.random(math.max(2, L - 16), 16)
    pad = L - steps
  else
    local r = math.random()
    if r < 0.45 then steps, pad = L, 0
    elseif r < 0.90 then
      pad = math.random(1, math.max(1, math.floor(L / 3)))
      steps = L - pad
      if steps < 2 then steps, pad = 2, L - 2 end
    else
      steps = math.random(2, math.max(2, math.floor(L / 2)))
      pad = L - steps
    end
  end
  -- fill density: 1 trig 10% / sparse 25% / medium 35% / busy 25% / full 5%
  local dens = pick({ {"one",10}, {0.25,25}, {0.45,35}, {0.67,25}, {"full",5} })
  local trig
  if dens == "one" then trig = 1
  elseif dens == "full" then trig = steps
  else
    trig = util.clamp(util.round(steps * (dens + (math.random() - 0.5) * 0.15)), 1, steps)
    if trig == steps and steps > 2 then trig = steps - 1 end   -- full fills only via the 5% bucket
  end
  params:set("v" .. v .. "_esteps", steps)   -- option index N = N steps (idx 1 = drone, never rolled)
  params:set("v" .. v .. "_etrig", trig)
  params:set("v" .. v .. "_epad", pad)
  params:set("v" .. v .. "_eshift", (math.random() < 0.40) and 0 or math.random(1, math.min(L - 1, 16)))
  params:set("v" .. v .. "_ereset", pick({ {8,25}, {16,40}, {32,25}, {64,10} }))
  -- erate option order: 1/4x 1/2x 3/4x 1x 1.5x 2x -> favor 1x, then halves/doubles
  params:set("v" .. v .. "_erate", pick({ {4,35}, {2,20}, {6,15}, {1,10}, {3,10}, {5,10} }))
  local pr = math.random()
  params:set("v" .. v .. "_eprob", (pr < 0.55) and 1 or (pr < 0.95) and pct(60, 95) or pct(30, 55))
end

-- ---------- LFO ----------
-- div weights over the 19 sync divisions: favor the 1bar..1/8 musical band
local DIVW = { {1,2},{2,4},{3,6},{4,10},{5,6},{6,10},{7,6},{8,3},{9,12},{10,5},
               {11,4},{12,10},{13,3},{14,3},{15,8},{16,1},{17,2},{18,4},{19,1} }
local function rand_div() return pick(DIVW) end
local function rand_rate()   -- log-uniform 0.05..2 Hz, 20% tail 2..8 Hz (never audio-rate)
  local lo, hi = 0.05, 2
  if math.random() < 0.2 then lo, hi = 2, 8 end
  return lo * (hi / lo) ^ math.random()
end

local function rand_lfo(s)
  local function id(p) return "lfo" .. s .. "_" .. p end
  if C.mtx.src[s].shape == 7 then   -- S&H SEED is sticky: never re-roll its waveform
    local b = flip("lfo" .. s)
    params:set(id("sync"), 2)                       -- sync always ON for S&H SEED
    params:set("dronage_seed", math.random(0, 4095))
    if b then
      params:set(id("length"), math.random(2, 32))
      params:set(id("div"), rand_div())
      return "RANDOMIZED SEED+LEN+DIV"
    end
    return "RANDOMIZED SEED"
  end
  local shape = math.random(1, 7)
  params:set(id("shape"), shape)
  local synced = (shape == 7) or (math.random() < 0.75)
  params:set(id("sync"), synced and 2 or 1)
  if synced then params:set(id("div"), rand_div())
  else params:set(id("rate"), rand_rate()) end
  params:set(id("phase"), pct(0, 99))
  params:set(id("skew"), sig(math.random(0, 100)) / 100)
  params:set(id("smooth"), pct(0, 100))
  params:set(id("polarity"), (math.random() < 0.75) and 1 or 2)
  if shape == 6 then params:set(id("variation"), pct(0, 100)) end
  if shape == 7 then params:set(id("length"), math.random(2, 32)) end
  -- mutate: NEVER randomized (the Turing dial is the player's)
  M.nav()   -- full roll re-arms the phase: landing on S&H SEED, the next press = seed-only
  return "RANDOMIZED LFO " .. s
end

-- ---------- MOD MATRIX ----------
-- the 10 UI-visible dest params + their depth ceilings (whole %; the 5 hidden dests are never
-- touched - the player can't see them to clean them up)
local MPARAMS = { "pitch","tune","harm","timbre","morph","cut","res","lpgdecay","pan","level" }
local MDEPTH  = { pitch=50, tune=2, pan=50, level=50, harm=100, timbre=100, morph=100,
                  cut=100, res=100, lpgdecay=100 }
local function rand_matrix(voice)
  local overlay = flip("mtx" .. voice)
  if not overlay then   -- press A: fresh routing for this voice's visible params
    for _, cmd in ipairs(MPARAMS) do
      local d = C.mtx.find_dest(voice, cmd)
      if d then for s = 1, C.mtx.NUM_SRC do C.mtx.set_cell(d, s, 0) end end
    end
  end
  local porder, lorder = shuffled(#MPARAMS), shuffled(C.mtx.NUM_SRC)
  local k, li = math.random(3, 5), 0
  local function roll(cmd)
    local d = C.mtx.find_dest(voice, cmd)
    if d and li < #lorder then
      li = li + 1
      C.mtx.set_cell(d, lorder[li], sig(math.random(1, MDEPTH[cmd])) / 100)
    end
  end
  for i = 1, k do roll(MPARAMS[porder[i]]) end
  if math.random() < 0.10 then roll(MPARAMS[porder[math.random(1, k)]]) end   -- rare double-up
  return (overlay and "ADDED V" or "RANDOMIZED V") .. voice .. " MODS"
end

-- ---------- FX / MASTER / GLOBAL ----------
local function rand_delay()
  params:set("dronage_delay_div", math.random(1, #options.sets.div.entries))
  params:set("dronage_delay_fb", pct(0, 100))
  params:set("dronage_delay_tone", sig(math.random(0, 100)) / 100)
  params:set("dronage_delay_mod", pct(0, 100))
  params:set("dronage_delay_gran", sig(math.random(0, 100)) / 100)
  params:set("dronage_delay_rvbsend", pct(0, 100))
  params:set("dronage_delay_revfwd", pct(0, 100))
end

local function rand_reverb()
  params:set("dronage_reverb_shimmer", math.random(0, 9) / 10)   -- 10% steps (spec max 0.9)
  params:set("dronage_reverb_size", math.random(1, 3))           -- whole sizes
  params:set("dronage_reverb_time", math.random(1, 4))           -- whole seconds
  params:set("dronage_reverb_damp", pct(0, 100))
  params:set("dronage_reverb_diff", pct(0, 100))
  params:set("dronage_reverb_fb", pct(0, 75))                    -- spec max 0.75
  params:set("dronage_reverb_mod", pct(0, 100))
end

local function rand_master()   -- tape age + hiss ONLY (compression + volume are the player's)
  params:set("dronage_tape_age", pct(0, 100))
  params:set("dronage_tape_hiss", pct(0, 100))
end

local function rand_macro()
  for g = 1, C.mac.NUM_SLOTS do
    local s = C.mac.slots[g]
    s.osc = math.random(0, 9)
    s.param = math.random(1, #C.mac.targets.target_cmds)
    s.depth = sig(math.random(1, 4)) * 0.25   -- ±25/50/75/100%, never 0 (a dead slot)
  end
  C.mac.rebuild_active()
end

local function rand_modseq(t)
  local tr = C.seq.tracks[t]
  for i = 1, C.seq.NUM_STEPS do tr.steps[i] = sig(math.random(0, 100)) / 100 end
  tr.length = math.random(2, C.seq.NUM_STEPS)
  tr.div = math.random(1, #C.seq.divisions)
  for g = 1, C.seq.NUM_TARGETS do
    tr.targets[g] = math.random(0, 9)
    tr.param[g] = math.random(1, #C.seq.params_list)
    tr.amount[g] = sig(math.random(1, 4)) * 0.25
  end
  C.seq.rebuild_active()
end

local function pick_scene()   -- another populated slot: 1 other -> it; several -> random
  local others = {}
  for i = 1, C.scenes.NUM do
    if i ~= C.scenes.current and C.scenes.modified(i) then others[#others + 1] = i end
  end
  if #others == 0 then return nil end
  return others[math.random(#others)]
end

local function rand_global()
  params:set("dronage_root", math.random(1, 12))
  -- scale: 70% western (idx 3..34) / 20% world (35..45) / 10% microtonal (46..65);
  -- never Off or Chromatic. Indices track the options list order - revisit if it's reshuffled.
  local r = math.random()
  params:set("dronage_scale", (r < 0.70) and math.random(3, 34)
                           or (r < 0.90) and math.random(35, 45) or math.random(46, 65))
  params:set("dronage_seed", math.random(0, 4095))
end

-- ---------- dispatcher ----------
-- vw = the screens VIEWS entry; focus = matrix voice / CV-seq track (view-dependent).
-- Returns the toast text, or nil for silent no-op pages.
function M.page(vw, focus)
  local kind, name = vw.kind, vw.name or ""
  if kind == "home" or kind == "project" then return nil end

  if kind == "panel" then
    local vn = name:match("^VOICE (%d+)")
    if vn then
      C.undo.around("RANDOMIZE", function() rand_voice(tonumber(vn)) end)
      return "RANDOMIZED VOICE " .. vn
    elseif name == "DELAY" then C.undo.around("RANDOMIZE", rand_delay); return "RANDOMIZED DELAY"
    elseif name == "REVERB" then C.undo.around("RANDOMIZE", rand_reverb); return "RANDOMIZED REVERB"
    elseif name == "MASTER FX" then C.undo.around("RANDOMIZE", rand_master); return "RANDOMIZED TAPE"
    elseif name == "GLOBAL" then C.undo.around("RANDOMIZE", rand_global); return "RANDOMIZED GLOBAL"
    end
    return nil
  elseif kind == "euclid" then
    C.undo.around("RANDOMIZE", function() rand_euclid(vw.v) end)
    return "RANDOMIZED EUCLID " .. vw.v
  elseif kind == "lfo" then
    local msg
    C.undo.around("RANDOMIZE", function() msg = rand_lfo(vw.src) end)
    return msg
  elseif kind == "matrix" then
    local msg
    C.undo.around("RANDOMIZE", function() msg = rand_matrix(focus) end)
    return msg
  elseif kind == "modseq" then
    C.undo.around("RANDOMIZE", function() rand_modseq(focus) end)
    return "RANDOMIZED CV TRACK " .. focus
  elseif kind == "macro" then
    C.undo.around("RANDOMIZE", rand_macro)
    return "RANDOMIZED MACRO"
  elseif kind == "scenes" then
    local target = pick_scene()
    if not target then return "NO OTHER SCENE" end
    C.undo.around("SCENE", function() C.scenes.switch(target) end)
    return "SCENE " .. target
  end
  return nil
end

return M
