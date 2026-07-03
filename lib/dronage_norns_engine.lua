-- dronage-norns engine lib: param specs, add_params, and the engine command mapping.
-- ENGINE params live here; SCRIPT params (MIDI/grid/etc.) are added in the main file.
local cs = require "controlspec"
local D = include("dronage-norns/lib/dronage_norns_defaults")   -- single source of truth for defaults
local options = include("dronage-norns/lib/dronage_norns_options")   -- keyed (reorder/rename-safe) option params

local M = {}

M.NUM_VOICES = 4
M.quantize = nil   -- set by main (scale snap); identity when nil. Applied to base pitch before the engine.

-- Plaits synthesis models, index 1..16 maps to engine 0..15.
M.models = {
  "virtual analog", "waveshaping", "fm", "grain", "additive", "wavetable",
  "chord", "speech", "swarm", "noise", "particle", "string", "modal",
  "bass drum", "snare drum", "hi hat",
}

-- per-voice starting state lives in the defaults module (D.voice); `level` drives Plaits LPG + VCA.
local defaults = D.voice

M.defaults = defaults

function M.add_params()
  for i = 1, M.NUM_VOICES do
    local d = defaults[i]
    params:add_separator("dronage_voice_" .. i, "voice " .. i)

    params:add{ type = "option", id = "v" .. i .. "_model", name = "model",
      options = options.labels("model"), default = d.model + 1,
      action = function(v) engine.engine(i, options.value("v" .. i .. "_model", v)) end }

    params:add{ type = "control", id = "v" .. i .. "_pitch", name = "pitch",
      controlspec = cs.new(12, 108, "lin", 0, d.pitch, "st", 1e-5),   -- fine quantum (~0.01 Hz low; E3 accel covers range)
      action = function(v) engine.pitch(i, M.quantize and M.quantize(v) or v) end }

    -- post-quantizer semitone offset (the vintage-detune knob): summed with pitch INSIDE the engine,
    -- so it always lands AFTER the scale quantizer no matter what drives it (knob, matrix, CV seq).
    params:add{ type = "control", id = "v" .. i .. "_tune", name = "tune",
      controlspec = cs.new(-12, 12, "lin", 0.01, D.synth.tune, "st", 0.01 / 24),   -- 0.01 st per detent
      action = function(v) engine.tune(i, v) end }

    params:add{ type = "control", id = "v" .. i .. "_harm", name = "harmonics",
      controlspec = cs.new(0, 1, "lin", 0, D.synth.harm, ""),
      action = function(v) engine.harm(i, v) end }

    params:add{ type = "control", id = "v" .. i .. "_timbre", name = "timbre",
      controlspec = cs.new(0, 1, "lin", 0, D.synth.timbre, ""),
      action = function(v) engine.timbre(i, v) end }

    params:add{ type = "control", id = "v" .. i .. "_morph", name = "morph",
      controlspec = cs.new(0, 1, "lin", 0, D.synth.morph, ""),
      action = function(v) engine.morph(i, v) end }

    -- single voice level (dronage-tui model): drives the Plaits LPG and the VCA.
    params:add{ type = "control", id = "v" .. i .. "_level", name = "level",
      controlspec = cs.new(0, 1, "lin", 0, d.level, ""),
      action = function(v) engine.level(i, v) end }

    params:add{ type = "control", id = "v" .. i .. "_pan", name = "pan",
      controlspec = cs.new(-1, 1, "lin", 0, D.synth.pan, "", 0.005),   -- quantum 0.005 -> 0.01 value step
      action = function(v) engine.pan(i, v) end }

    -- Gate + AHD slew (per voice). Toggle the gate: voice fades in over `attack`, out over `decay`,
    -- continuing from wherever the slew is (no click).
    params:add{ type = "binary", id = "v" .. i .. "_gate", name = "gate", behavior = "toggle",
      default = D.synth.gate,
      action = function(v) engine.gate(i, v) end }

    params:add{ type = "control", id = "v" .. i .. "_attack", name = "fade in",
      controlspec = cs.new(0.1, 30, "exp", 0, D.synth.attack, "s"),
      action = function(v) engine.attack(i, v) end }

    params:add{ type = "control", id = "v" .. i .. "_decay", name = "fade out",
      controlspec = cs.new(0.1, 30, "exp", 0, D.synth.decay, "s"),
      action = function(v) engine.decay(i, v) end }

    -- per-voice filters (Moog LP + utility SVF HP). cut/res are mod-matrix destinations.
    params:add{ type = "control", id = "v" .. i .. "_cut", name = "cutoff",
      controlspec = cs.new(20, 20000, "exp", 0, D.synth.cut, "Hz", 1e-5),   -- fine quantum; exp curve = coarser at high freq
      action = function(v) engine.cut(i, v) end }
    params:add{ type = "control", id = "v" .. i .. "_res", name = "resonance",
      controlspec = cs.new(0, 0.99, "lin", 0, D.synth.res, ""),
      action = function(v) engine.res(i, v) end }
    params:add{ type = "control", id = "v" .. i .. "_hpcut", name = "hp cutoff",
      controlspec = cs.new(20, 2000, "exp", 0, D.synth.hpcut, "Hz", 2e-5),   -- fine quantum; exp curve = coarser at high freq
      action = function(v) engine.hpcut(i, v) end }
    params:add{ type = "control", id = "v" .. i .. "_hpq", name = "hp q",
      controlspec = cs.new(0, 1, "lin", 0, D.synth.hpq, ""),
      action = function(v) engine.hpq(i, v) end }

    -- bipolar amp-sim drive: -1 Doom fuzz .. 0 bypass .. +1 Marshall tube. A mod dest too.
    params:add{ type = "control", id = "v" .. i .. "_drive", name = "drive",
      controlspec = cs.new(-1, 1, "lin", 0, D.synth.drive, "", 0.005),   -- quantum 0.005 -> 0.01 value step (span 2)
      action = function(v) engine.drive(i, v) end }
    -- bipolar stereo chorus: -1 warm .. 0 off .. +1 spacey. A mod dest too.
    params:add{ type = "control", id = "v" .. i .. "_chorus", name = "chorus",
      controlspec = cs.new(-1, 1, "lin", 0, D.synth.chorus, "", 0.005),   -- quantum 0.005 -> 0.01 value step (span 2)
      action = function(v) engine.chorus(i, v) end }
    -- bipolar DLY send: + -> forward delay, - -> reverse delay (reverse TBD). A mod dest too.
    params:add{ type = "control", id = "v" .. i .. "_dlysend", name = "dly send",
      controlspec = cs.new(-1, 1, "lin", 0, D.synth.dlysend, "", 0.005),   -- quantum 0.005 -> 0.01 value step (span 2)
      action = function(v) engine.dlysend(i, v) end }
    -- unipolar reverb send (per voice) -> the shimmer reverb. A mod dest too.
    params:add{ type = "control", id = "v" .. i .. "_reverbsend", name = "reverb send",
      controlspec = cs.new(0, 1, "lin", 0, D.synth.reverbsend, ""),
      action = function(v) engine.reverbsend(i, v) end }

    -- per-voice output routing (mono): MIX = (out+aux)/2, OUT = main, AUX = aux. Last VOICE param.
    params:add{ type = "option", id = "v" .. i .. "_out_mode", name = "out",
      options = options.labels("out_mode"), default = 1,   -- index 1 = MIX
      action = function(v) engine.outmode(i, options.value("v" .. i .. "_out_mode", v)) end }
  end
end

return M
