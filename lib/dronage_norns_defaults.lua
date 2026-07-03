-- dronage-norns - SINGLE SOURCE OF TRUTH for every parameter default.
--
-- Every params:add{...} across the app reads its default from this table (D.synth.harm,
-- D.euclid.fill, D.lfo.shape, D.reverb.mix, ...) instead of hardcoding a literal. So a new
-- project (params:default() / PROJECT > NEW) starts from exactly these values, and there is
-- one place to review or change any default. Option params store the 1-based option INDEX.

local D = {}

-- per-voice starting state (model index 0-based; pitch in semitones; level 0-1). Only pitch
-- is spread across voices (a chord) - model + level are uniform.
D.voice = {
  { model = 0, pitch = 36, level = 0.5 },   -- V1 virtual analog, low fundamental
  { model = 0, pitch = 48, level = 0.5 },   -- V2
  { model = 0, pitch = 55, level = 0.5 },   -- V3
  { model = 0, pitch = 60, level = 0.5 },   -- V4
}

-- synth / filter / send params shared across all 4 voices
D.synth = {
  harm = 0.5, timbre = 0.5, morph = 0.5,
  tune = 0,                -- post-quantizer semitone offset (bipolar, ±12.00)
  pan = 0,                 -- centered
  gate = 0,                -- off (boots silent even though transport plays)
  attack = 1, decay = 1,   -- fade in/out, seconds
  cut = 5000, res = 0.5,   -- LP filter
  hpcut = 30, hpq = 0.1,   -- HP filter
  drive = 0, chorus = 0, dlysend = 0, reverbsend = 0,
}

-- euclidean sequencer + LPG, per voice (esteps/erate store option indices)
D.euclid = {
  steps = 1,               -- option 1 = "drone"
  fill = 1, shift = 0, padding = 0, reset = 16,
  rate = 4,                -- option 4 = "1x"
  prob = 1,
  lpgcol = 0.0, lpgdecay = 0.5,
}

-- LFO sources, per LFO (shape/sync/div/polarity store option indices)
D.lfo = {
  shape = 1,               -- "sine"
  sync = 1,                -- "free"
  div = 9,                 -- "1/4"
  phase = 0, skew = 0, smooth = 0,
  length = 8, variation = 1, mutate = 0,
  polarity = 1,            -- "bi"
}
function D.lfo.rate(s) return 0.15 + 0.05 * s end   -- per-LFO free rate (Hz): L1 0.20 .. L8 0.55

-- global / mod (root/scale/sh_anchor store option indices; tempo is the norns clock param)
D.global = {
  tempo = 120,
  root = 1,                -- "C"
  scale = 3,               -- "major" (2 = chromatic, 1 = off)
  mod_depth = 1,
  seed = 0,
  sh_anchor = 2,           -- "on"
}

-- send FX. delay div + revdelay div store option indices into mtx.div_names.
D.delay    = { div = 9, fb = 0.45, tone = 0, mod = 0, gran = 0, rvbsend = 0, revfwd = 0 }   -- div 9 = "1/4"
D.revdelay = { div = 6, fb = 0.45, tone = 0, mod = 0 }             -- div 6 = "1/2" (2x forward length)
D.reverb   = { mix = 1, shimmer = 0, size = 2, time = 2, damp = 0.3, diff = 0.7, fb = 0.6, mod = 0.1 }
D.tape     = { age = 0, hiss = 0, compression = 0.5 }

D.macro     = { amount = 0 }
D.transport = 1            -- play on boot

return D
