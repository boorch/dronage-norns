-- Shared modulation-target registry (dronage-tui's SeqTargetParam list).
-- BOTH the MACRO controller and the CV/MOD sequencer use this list so they share identical
-- targets, exactly like dronage-tui (where Macro + ModSeq reference one SeqTargetParam enum).
--
-- These are the continuous per-voice params that exist in the norns engine. dronage-tui's full
-- list also has ReverbSend and Engine(model); both are TODO here:
--   * reverbsend  - needs a per-voice reverb send in the SC engine (currently reverb is on the
--                   summed mix; restoring per-voice sends is a separate engine change).
--   * model/Engine - a discrete option param, so it can't ride the matrix unmap/map path; needs
--                    its own (round-to-nearest) handling.
-- chorus is intentionally NOT a target: per-voice chorus is already a modulation effect, so
-- modulating it adds no useful flavour (dronage-tui likewise never made chorus a target).

local M = {}

-- ordered like dronage-tui's SeqTargetParam (cmd = engine command + param suffix; label = UI long
-- name; short = canonical 3-char name used in space-constrained views - the app's single source).
M.TARGETS = {
  { cmd = "pitch",    label = "pitch",      short = "Pit" },
  { cmd = "tune",     label = "tune",       short = "Tun" },
  { cmd = "harm",     label = "harmonics",  short = "Har" },
  { cmd = "timbre",   label = "timbre",     short = "Tim" },
  { cmd = "morph",    label = "morph",      short = "Mor" },
  { cmd = "cut",      label = "cutoff",     short = "Cut" },
  { cmd = "res",      label = "resonance",  short = "Res" },
  { cmd = "level",    label = "level",      short = "Lvl" },
  { cmd = "pan",      label = "pan",        short = "Pan" },
  { cmd = "hpcut",      label = "hp cutoff",   short = "HPF" },
  { cmd = "drive",      label = "drive",       short = "Drv" },
  { cmd = "dlysend",    label = "dly send",    short = "Dly" },
  { cmd = "lpgdecay",   label = "lpg decay",   short = "LPD" },
  { cmd = "reverbsend", label = "reverb send", short = "Rvb" },
}

M.target_cmds = {}    -- index -> engine command / param suffix
M.target_labels = {}  -- index -> display label (long)
M.target_shorts = {}  -- index -> canonical 3-char short name
for i, t in ipairs(M.TARGETS) do
  M.target_cmds[i]   = t.cmd
  M.target_labels[i] = t.label
  M.target_shorts[i] = t.short
end
M.NUM_TARGETS = #M.TARGETS

-- Voice-combo selector: OFF + dronage-tui's ten osc groupings (singles 1-4, then A-F).
-- Option index 1 = OFF; 2..11 map to the voice sets below.
M.COMBO_NAMES = { "OFF", "1", "2", "3", "4", "1+2", "2+3", "3+4", "1+2+3", "2+3+4", "1+2+3+4" }
local COMBO_VOICES = {
  {},                 -- 1  OFF
  {1}, {2}, {3}, {4}, -- 2..5  singles
  {1,2}, {2,3}, {3,4},-- 6..8  pairs (A,B,C)
  {1,2,3}, {2,3,4},   -- 9,10  triples (D,E)
  {1,2,3,4},          -- 11    all (F)
}
function M.combo_voices(opt) return COMBO_VOICES[opt] or {} end

-- ---- stable string keys for save/load (so reordering/adding targets or combos never remaps a
-- saved value). A target is keyed by its `cmd`; a voice-combo by its canonical voice set. ----

-- canonical voice-set key: {} -> "off", {2,1} -> "1+2". Order-independent, addition-proof.
function M.voiceset_key(voices)
  if not voices or #voices == 0 then return "off" end
  local v = { table.unpack(voices) }; table.sort(v)
  return table.concat(v, "+")
end

-- resolve a cmd string -> current target index (nil if that target no longer exists)
function M.cmd_to_index(cmd)
  for i, c in ipairs(M.target_cmds) do if c == cmd then return i end end
  return nil
end

-- resolve a voiceset key -> current macro-combo (tracks) option index (nil if no combo matches)
function M.key_to_combo(key)
  for i = 1, #COMBO_VOICES do if M.voiceset_key(COMBO_VOICES[i]) == key then return i end end
  return nil
end

return M
