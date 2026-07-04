-- dronage-norns scenes - 8 in-RAM snapshots of the full musical state.
-- Snapshot = every relevant param (incl. each LFO's u16 seed -> reproducible S&H) +
-- the matrix cells + the sequencer tracks. Autosave-on-switch (dronage-tui model):
-- switching saves the live state into the current slot, then loads the target slot.
-- All 8 slots persist to disk in a pset sidecar (so they survive a reload/reboot).

local options = include("dronage-norns/lib/dronage_norns_options")   -- option params save by stable key

local M = {}
M.NUM = 8
M.current = 1
M.slots = {}          -- [1..8] = snapshot table (or nil if never visited)

local mtx, seq, mac

local function build_ids()
  local ids = { "clock_tempo", "mod_depth", "dronage_seed", "dronage_sh_anchor", "dronage_scale", "dronage_root",
                "dronage_delay_div", "dronage_delay_fb", "dronage_delay_tone", "dronage_delay_mod", "dronage_delay_gran", "dronage_delay_rvbsend", "dronage_delay_revfwd",
                "dronage_revdelay_div", "dronage_revdelay_fb", "dronage_revdelay_tone", "dronage_revdelay_mod",
                "dronage_reverb_mix", "dronage_reverb_shimmer", "dronage_reverb_size", "dronage_reverb_time",
                "dronage_reverb_damp", "dronage_reverb_diff", "dronage_reverb_fb", "dronage_reverb_mod",
                "dronage_tape_age", "dronage_tape_hiss", "dronage_tape_compression" }
  for v = 1, 4 do
    for _, p in ipairs({ "model", "pitch", "tune", "harm", "timbre", "morph", "level", "pan",
                         "gate", "attack", "decay",
                         "esteps", "etrig", "eshift", "epad", "ereset", "erate", "eprob", "lpgcol", "lpgdecay",
                         "cut", "res", "hpcut", "hpq", "drive", "chorus", "dlysend", "reverbsend", "out_mode" }) do
      ids[#ids + 1] = "v" .. v .. "_" .. p
    end
  end
  for s = 1, 8 do
    for _, p in ipairs({ "shape", "sync", "rate", "div", "phase", "skew", "smooth", "length", "variation", "mutate", "polarity" }) do
      ids[#ids + 1] = "lfo" .. s .. "_" .. p
    end
  end
  -- NOTE: macro slots are NOT here - they persist via mac.dump()/load() (string-keyed, so reordering
  -- targets/combos can't remap them). The global `dronage_macro_amount` is ephemeral (Control-All
  -- knob, reset to 0 on every scene switch, see M.recall).
  return ids
end
M.ids = nil

function M.init(matrix_mod, seq_mod, macro_mod)
  mtx, seq, mac = matrix_mod, seq_mod, macro_mod
  M.ids = build_ids()
end

function M.capture()
  local snap = { params = {}, matrix = mtx.dump(), seq = seq.dump(), macro = mac and mac.dump() }
  -- option params are stored by their STABLE KEY (reorder/rename-safe); everything else by value.
  for _, id in ipairs(M.ids) do
    snap.params[id] = options.keyed(id) and options.key(id, params:get(id)) or params:get(id)
  end
  return snap
end

-- write a snapshot's params + matrix/seq/macro into the live state. Shared by scene recall and
-- the undo module (which must NOT get recall's macro-amount reset).
function M.apply(snap)
  for _, id in ipairs(M.ids) do
    local v = snap.params[id]
    if v ~= nil then
      if options.keyed(id) and type(v) == "string" then
        local idx = options.index(id, v)   -- stable key -> current display index
        if idx then params:set(id, idx) end   -- unknown key (option removed) -> leave current/default
      else
        params:set(id, v)   -- plain value (or legacy numeric option index)
      end
    end
  end
  if snap.matrix then mtx.load(snap.matrix) end
  if snap.seq then seq.load(snap.seq) end
  if snap.macro and mac then mac.load(snap.macro) end
end

function M.recall(i)
  local snap = M.slots[i]
  if not snap then return false end
  M.apply(snap)
  -- Control-All: the global macro amount always returns to 0 on a scene switch (dronage-tui).
  params:set("dronage_macro_amount", 0)
  return true
end

-- autosave current slot, then move to + load target slot (empty target clones current)
function M.switch(i)
  if i == M.current then return end
  M.slots[M.current] = M.capture()
  M.current = i
  if M.slots[i] then M.recall(i) else M.slots[i] = M.capture() end
end

function M.store(i) M.slots[i] = M.capture(); M.current = i end   -- store live into slot i, make it active
function M.store_current() M.store(M.current) end
function M.clear(i) M.slots[i] = nil end                          -- forget slot i's snapshot (live sound unchanged)
function M.clear_current() M.clear(M.current) end
function M.clear_all() for i = 1, M.NUM do M.slots[i] = nil end; M.current = 1 end   -- NEW project: forget every scene
function M.modified(i) return M.slots[i] ~= nil end

-- persist all slots alongside the pset (norns fires these on PARAMS > save/load)
function M.add_pset_hooks()
  params.action_write = function(filename, name, number)
    M.slots[M.current] = M.capture()
    tab.save({ current = M.current, slots = M.slots }, filename .. ".scenes")
  end
  params.action_read = function(filename, silent, number)
    local d = tab.load(filename .. ".scenes")
    if d and d.slots then
      M.slots = d.slots
      M.current = d.current or 1
      M.recall(M.current)
    end
  end
end

return M
