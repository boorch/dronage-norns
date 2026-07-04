-- dronage-norns UNDO: a 10-deep history of full musical-state snapshots. K2+E1 walks it.
--
-- The history stores SETTLED STATES (not diffs), one per gesture or destructive op, built on
-- the scenes module's capture/apply (params by stable key + matrix cells + CV seq + macro
-- slots). Knob edits are gesture-coalesced: any captured params:set/:delta stamps a dirty
-- clock, and one second of quiet turns the whole burst into a single "EDITS" checkpoint.
-- Destructive ops (randomize, scene recall/store/init, project load/new) go through
-- around(label, fn): settle pending edits, run the op with dirty-marking suppressed, record
-- the post-op state under the op's label - so undo steps land exactly on op boundaries.
--
-- Every entry also carries the scene-slot REFERENCES + current slot + project name. Sharing
-- slots by reference is safe because the scenes module only ever REPLACES a slot table, never
-- mutates one in place - that is what makes 10 levels cost ~nothing in RAM.
--
-- Deliberately NOT covered: dronage_macro_amount + dronage_master_vol (live-room knobs,
-- excluded from the scene id list), transport, project-file deletion (disk is disk), and
-- pmap set_raw writes (absolute MIDI CC bypasses params:set; those edits just coalesce into
-- the next checkpoint instead of stamping their own).

local M = {}

M.DEPTH = 10                -- max undo steps (history holds DEPTH+1 states incl. the current)
local C                     -- injected: { scenes, project }
local hist, pos = {}, 0     -- hist[pos] = the last settled state
local dirty_at, dirty_label = nil, nil
local suppress = false      -- true while restoring / inside around(): no dirty-marking
local captured = {}         -- param-id set the snapshot covers (dirty filter)

local function snapshot(label)
  local slots = {}
  for i = 1, C.scenes.NUM do slots[i] = C.scenes.slots[i] end   -- refs, not copies (see header)
  return { label = label, snap = C.scenes.capture(), slots = slots,
           scur = C.scenes.current, pname = C.project.current }
end

local function push(e)
  for i = #hist, pos + 1, -1 do hist[i] = nil end   -- a new state invalidates the redo tail
  hist[#hist + 1] = e
  if #hist > M.DEPTH + 1 then table.remove(hist, 1) end
  pos = #hist
end

local function restore(e)
  suppress = true
  for i = 1, C.scenes.NUM do C.scenes.slots[i] = e.slots[i] end
  C.scenes.current = e.scur
  C.project.current = e.pname
  local ok, err = pcall(C.scenes.apply, e.snap)
  suppress = false
  dirty_at, dirty_label = nil, nil   -- a restore is not an edit
  if not ok then print("dronage undo: restore failed: " .. tostring(err)) end
end

-- mark "something captured changed" (param wrap below + the screens module's matrix/seq/macro
-- edit sites, which mutate module tables without touching params)
function M.touch(label)
  if suppress then return end
  dirty_at = util.time()
  dirty_label = dirty_label or label or "EDITS"
end

-- settle a pending gesture into its own history entry
function M.flush()
  if not dirty_at then return end
  local l = dirty_label or "EDITS"
  dirty_at, dirty_label = nil, nil
  push(snapshot(l))
end

function M.record(label)
  dirty_at, dirty_label = nil, nil
  push(snapshot(label))
end

-- destructive-op wrapper: settle edits, run the op silently, record the result under `label`
function M.around(label, fn)
  M.flush()
  suppress = true
  local ok, err = pcall(fn)
  suppress = false
  if ok then M.record(label)
  else print("dronage undo: op '" .. tostring(label) .. "' failed: " .. tostring(err)) end
end

-- both return the label of the transition walked (for the toast), or nil at the history's end
function M.undo()
  M.flush()   -- fresh edits become the step being undone
  if pos <= 1 then return nil end
  local label = hist[pos].label
  pos = pos - 1
  restore(hist[pos])
  return label
end

function M.redo()
  M.flush()   -- edits after an undo invalidate redo (flush truncates the tail)
  if pos >= #hist then return nil end
  pos = pos + 1
  restore(hist[pos])
  return hist[pos].label
end

-- call at UI rate (piggybacks the redraw metro): 1 s of quiet after an edit = checkpoint
local SETTLE = 1.0
function M.tick()
  if dirty_at and util.time() - dirty_at > SETTLE then M.flush() end
end

-- maiden-REPL introspection: "3/5 [BOOT RANDOMIZE EDITS *RANDOMIZE EDITS] dirty=false"
function M.state()
  local t = {}
  for i = 1, #hist do t[i] = (i == pos and "*" or "") .. hist[i].label end
  return pos .. "/" .. #hist .. " [" .. table.concat(t, " ") .. "] dirty=" .. tostring(dirty_at ~= nil)
end

function M.init(ctx)
  C = ctx
  for _, id in ipairs(C.scenes.ids) do captured[id] = true end
  -- stamp the dirty clock on EVERY captured param write (our UI, the norns PARAMETERS menu,
  -- MIDI-mapped deltas). The params object OUTLIVES a script reload, so a wrap-once guard goes
  -- stale (bound to the previous run's dead module - knob edits silently stop registering).
  -- Instead: stash the true originals on the object once, and rebind the wrappers to THIS
  -- module instance on every init.
  if not params._dronage_orig_set then
    params._dronage_orig_set, params._dronage_orig_delta = params.set, params.delta
  end
  local oset, odelta = params._dronage_orig_set, params._dronage_orig_delta
  params.set = function(self, id, v, sil)
    local key = (type(id) == "number") and (self.params[id] and self.params[id].id) or id
    if captured[key] then M.touch() end
    return oset(self, id, v, sil)
  end
  params.delta = function(self, id, d)
    local key = (type(id) == "number") and (self.params[id] and self.params[id].id) or id
    if captured[key] then M.touch() end
    return odelta(self, id, d)
  end
end

return M
