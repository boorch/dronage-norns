-- dronage-norns MACRO controller (the dronage-tui Macro: 1 macro, 3 destination slots).
--
-- Each slot is a destination IDENTICAL to the CV sequencer's: a voice/group (osc index -1..9,
-- -1 = none) x a target param (0 = none, 1..N into the shared registry) x a bipolar depth
-- (-1..+1 = -100%..+100%). ONE global `amount` (-2..+2 = -200%..+200%) scales ALL slots at once --
-- an Elektron-style Control-All performance knob -- and is ephemeral: reset to 0 on scene switch.
--
-- Output = amount * depth, added into the SAME per-dest accumulator the LFO matrix and the CV
-- sequencer write to (via the injected dest_index), so base + matrix + seq + macro all stack and
-- the existing unified_tick apply loop clamps once and writes the engine. The macro never calls
-- engine.* itself.

local targets = include("dronage-norns/lib/dronage_norns_targets")
local cs = require "controlspec"
local D = include("dronage-norns/lib/dronage_norns_defaults")

local M = {}
M.NUM_SLOTS  = 3
M.amount     = 0          -- global Control-All amount (-2..+2); ephemeral, reset on scene switch
M.slots      = {}         -- [i] = { osc = -1, param = 0, depth = 0 } (CV-seq destination model)
M.dest_active = {}        -- d -> bool : a slot drives dest d (osc + param + depth all set)
M.dest_index = nil        -- injected matrix.dest_index(voice, cmd) -> dest id
M.targets    = targets

-- osc index 0..9 -> the shared voice-combo option (1 = OFF, 2..11 = the ten groupings)
local function osc_voices(osc) return targets.combo_voices(osc + 2) end

function M.init(dest_index_fn)
  M.dest_index = dest_index_fn
  M.amount = 0
  M.slots = {}
  for i = 1, M.NUM_SLOTS do M.slots[i] = { osc = -1, param = 0, depth = 0 } end
  M.rebuild_active()
end

-- which dests are touched by a configured slot (so the apply loop fires even at amount 0)
function M.rebuild_active()
  for d in pairs(M.dest_active) do M.dest_active[d] = false end
  if not M.dest_index then return end
  for i = 1, M.NUM_SLOTS do
    local s = M.slots[i]
    if s.osc >= 0 and s.param >= 1 and s.depth ~= 0 then
      local cmd = targets.target_cmds[s.param]
      for _, v in ipairs(osc_voices(s.osc)) do
        M.dest_active[M.dest_index(v, cmd)] = true
      end
    end
  end
end

-- add amount*depth into the shared accumulator acc[dest], per active slot/voice
function M.accumulate(acc)
  if M.amount == 0 then return end
  for i = 1, M.NUM_SLOTS do
    local s = M.slots[i]
    if s.osc >= 0 and s.param >= 1 and s.depth ~= 0 then
      local cv = M.amount * s.depth
      local cmd = targets.target_cmds[s.param]
      for _, v in ipairs(osc_voices(s.osc)) do
        local d = M.dest_index(v, cmd)
        acc[d] = (acc[d] or 0) + cv
      end
    end
  end
end

function M.set_amount(a) M.amount = a end

-- the master AMOUNT stays a mappable control param (-2..+2). The 3 slots (osc/param/depth) are
-- edited in the MACRO CONTROLLER view and saved via dump/load -- not the params menu, exactly like
-- the CV sequencer's tracks. `amount` is intentionally NOT scene-saved (reset to 0 on switch).
function M.add_params()
  params:add_separator("dronage_macro_sep", "macro")
  params:add{ type = "control", id = "dronage_macro_amount", name = "macro amount",
    controlspec = cs.new(-2, 2, "lin", 0, D.macro.amount, "", 0.0025),   -- 0.01 value step = 1% (span 4, -200%..+200%)
    action = function(v) M.amount = v end }
end

-- Scene persistence by STRING (not index): each slot's param as its target `cmd` ("none" if unset),
-- its voice-combo as a voiceset key ("off" if unset). So reordering targets/combos never remaps a
-- saved macro. `amount` is NOT saved (ephemeral Control-All, reset to 0 on scene switch).
function M.dump()
  local out = { slots = {} }
  for i = 1, M.NUM_SLOTS do
    local s = M.slots[i]
    out.slots[i] = {
      combo = (s.osc >= 0) and targets.voiceset_key(osc_voices(s.osc)) or "off",
      cmd   = (s.param >= 1) and (targets.target_cmds[s.param] or "timbre") or "none",
      depth = s.depth,
    }
  end
  return out
end
function M.load(d)
  if not d or not d.slots then return end
  for i = 1, M.NUM_SLOTS do
    local sd, s = d.slots[i], M.slots[i]
    if sd and s then
      local combo = sd.combo and sd.combo ~= "off" and targets.key_to_combo(sd.combo)   -- option 1..11
      s.osc   = (combo and combo >= 2) and (combo - 2) or -1
      s.param = (sd.cmd and sd.cmd ~= "none" and targets.cmd_to_index(sd.cmd)) or 0
      s.depth = util.clamp(sd.depth or 0, -1, 1)
    end
  end
  M.rebuild_active()
end

return M
