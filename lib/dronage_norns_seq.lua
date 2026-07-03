-- dronage-norns CV sequencer (the dronage-tui ModSequencer: 5 tracks x 5 steps x 2 targets)
-- Each track holds 5 stepped DC values (-1..+1). Each track sends its current step to up to
-- 2 targets {osc-or-group, param} scaled by a signed amount, summed ADDITIVELY into the SAME
-- modulation accumulator as the LFO matrix. Stepped, polymetric (per-track clock division).
-- Edited via the UI; persisted via scenes (dump/load). No params menu clutter.

local targets = include("dronage-norns/lib/dronage_norns_targets")

local M = {}

M.NUM_TRACKS  = 5
M.NUM_STEPS   = 5
M.NUM_TARGETS = 2
M.steps_per_beat = 4                              -- clock grid (x4 headroom for fast divisions)
M.divisions   = { 0.25, 0.5, 1, 2, 4 }
M.div_names   = { "/4", "/2", "x1", "x2", "x4" }
-- shared with the MACRO controller (dronage-tui: Macro + ModSeq use one SeqTargetParam list)
M.params_list = targets.target_cmds
M.param_labels = targets.target_labels
M.params_short = targets.target_shorts
M.osc_names   = { "1", "2", "3", "4", "A", "B", "C", "D", "E", "F" }

-- osc index 0..9 -> set of 1-based voices (single 1-4, then groups A..F)
local OSC_VOICES = {
  [0] = {1}, [1] = {2}, [2] = {3}, [3] = {4},
  [4] = {1,2}, [5] = {2,3}, [6] = {3,4}, [7] = {1,2,3}, [8] = {2,3,4}, [9] = {1,2,3,4},
}
function M.osc_voices(osc) return OSC_VOICES[osc] or {1} end

M.tracks = {}
M.dest_active = {}        -- d -> bool : this sequencer drives dest d (nonzero amount)
M.running = true
M.dest_index = nil        -- injected matrix.dest_index(voice, pname) -> dest id

local function new_track(i)
  return {
    steps   = { 0, 0, 0, 0, 0 },   -- per-step DC value, -1..+1
    length  = M.NUM_STEPS,         -- active steps 2..5
    div     = 3,                   -- index into M.divisions (3 = x1)
    current_step = 1,
    prev_phase   = 0,
    targets = { -1, -1 },          -- per-target osc index 0..9 ; -1 = unassigned (empty by default)
    param   = { 0, 0 },            -- per-target param idx (1-based into params_list); 0 = none (empty)
    amount  = { 0, 0 },            -- per-target signed depth -1..+1 (0 = inactive)
  }
end

function M.init(dest_index_fn)
  M.dest_index = dest_index_fn
  M.tracks = {}
  for i = 1, M.NUM_TRACKS do M.tracks[i] = new_track(i) end   -- all tracks start empty (no demo content)
  M.rebuild_active()
end

function M.rebuild_active()
  for d in pairs(M.dest_active) do M.dest_active[d] = false end
  if not M.dest_index then return end
  for t = 1, M.NUM_TRACKS do
    local tr = M.tracks[t]
    for g = 1, M.NUM_TARGETS do
      if tr.targets[g] >= 0 and tr.param[g] >= 1 and tr.amount[g] ~= 0 then
        local pname = M.params_list[tr.param[g]]
        for _, v in ipairs(M.osc_voices(tr.targets[g])) do
          M.dest_active[M.dest_index(v, pname)] = true
        end
      end
    end
  end
end

-- advance step positions from the transport beat phase (integer-beat-crossing, polymetric).
function M.advance(phase)
  if not M.running then return end
  for t = 1, M.NUM_TRACKS do
    local tr = M.tracks[t]
    local m = M.divisions[tr.div]
    local prev = math.floor(tr.prev_phase * m)
    local cur  = math.floor(phase * m)
    for _ = 1, (cur - prev) do
      tr.current_step = (tr.current_step % tr.length) + 1
    end
    tr.prev_phase = phase
  end
end

function M.reset()
  for t = 1, M.NUM_TRACKS do M.tracks[t].current_step = 1; M.tracks[t].prev_phase = 0 end
end

-- add seq CV (current_step value x amount) into the shared accumulator acc[dest].
function M.accumulate(acc)
  for t = 1, M.NUM_TRACKS do
    local tr = M.tracks[t]
    local sval = tr.steps[tr.current_step] or 0
    if sval ~= 0 then
      for g = 1, M.NUM_TARGETS do
        local amt = tr.amount[g]
        if tr.targets[g] >= 0 and tr.param[g] >= 1 and amt ~= 0 then
          local cv = sval * amt
          local pname = M.params_list[tr.param[g]]
          for _, v in ipairs(M.osc_voices(tr.targets[g])) do
            local d = M.dest_index(v, pname)
            acc[d] = (acc[d] or 0) + cv
          end
        end
      end
    end
  end
end

-- scene persistence
-- voiceset key -> this sequencer's osc index (0..9); nil if no combo matches
local function key_to_osc(key)
  for osc = 0, 9 do if targets.voiceset_key(OSC_VOICES[osc]) == key then return osc end end
  return nil
end

-- saved by STRING: each target's param as its `cmd`, its voice-combo as a voiceset key ("off" if
-- unassigned). So reordering the target list or the combos never remaps a saved track.
function M.dump()
  local out = { running = M.running, tracks = {} }
  for t = 1, M.NUM_TRACKS do
    local tr = M.tracks[t]
    local combo, cmd = {}, {}
    for g = 1, M.NUM_TARGETS do
      combo[g] = (tr.targets[g] >= 0) and targets.voiceset_key(M.osc_voices(tr.targets[g])) or "off"
      cmd[g]   = (tr.param[g] >= 1) and (M.params_list[tr.param[g]] or "timbre") or "none"
    end
    out.tracks[t] = { steps = {table.unpack(tr.steps)}, length = tr.length, div = tr.div,
                      combo = combo, cmd = cmd, amount = {table.unpack(tr.amount)} }
  end
  return out
end
function M.load(d)
  if not d or not d.tracks then return end
  M.running = (d.running ~= false)
  for t = 1, M.NUM_TRACKS do
    local s, tr = d.tracks[t], M.tracks[t]
    if s then
      for i = 1, M.NUM_STEPS do tr.steps[i] = (s.steps and s.steps[i]) or 0 end
      tr.length = s.length or M.NUM_STEPS
      tr.div = s.div or 3
      for g = 1, M.NUM_TARGETS do
        local ck = s.combo and s.combo[g]
        tr.targets[g] = (ck and ck ~= "off") and (key_to_osc(ck) or -1) or -1
        local cm = s.cmd and s.cmd[g]
        tr.param[g] = (cm and cm ~= "none" and targets.cmd_to_index(cm)) or 0
        tr.amount[g] = (s.amount and s.amount[g]) or 0
      end
    end
  end
  M.reset()
  M.rebuild_active()
end

return M
