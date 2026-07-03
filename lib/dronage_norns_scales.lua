-- dronage-norns scales / pitch quantization (CENTS domain)
-- 65 scales: norns musicutil 12-TET set + Hirajoshi/Iwato/Fifths + microtonal Scala scales baked
-- from dronage-tui UserScales/*.scl. Quantizer ported from dronage-tui src/core/scala.rs: each scale
-- is a list of cents intervals from the root (root 0 implicit, last entry = period/octave), sorted
-- ascending. Snapping happens in cents, then converts back to a FRACTIONAL MIDI note (Plaits voices
-- the microtones natively). Off = passthrough. The scale table (keyed set + cents) lives statically
-- in options.lua, its single source (rebuilt identically on every include); M.scales just points at
-- it. Keys are permanent (save-safe).

local D = include("dronage-norns/lib/dronage_norns_defaults")
local options = include("dronage-norns/lib/dronage_norns_options")   -- keyed (reorder/rename-safe) option params
local M = {}

-- M.scales[i] = the keyed "scale" option entry { key, label, value=i, cents={...} }. cents are the
-- intervals from the root (root 0 implicit, last entry = period/octave), sorted ascending.
M.scales = options.sets.scale.entries

M.root = D.global.root - 1   -- 0..11 (C..B); param option is 1-based
M.idx  = D.global.scale      -- current scale option index (1-based; 1 = Off)

-- ---- cents-domain quantizer (port of scala.rs ScaleDefinition) ----
-- nearest scale degree to `cents` (relative to root). `intervals` includes the period as its last
-- entry; the root (0) is implicit. Snaps within one period, then reconstructs absolute cents.
local function snap_cents(intervals, cents)
  local period = intervals[#intervals]
  local periods = math.floor(cents / period)
  local within = cents - periods * period
  local best, bestd = 0.0, math.abs(within)             -- distance to the implicit root (0)
  for _, iv in ipairs(intervals) do
    local dd = math.abs(within - iv)
    if dd < bestd then bestd, best = dd, iv end
  end
  if math.abs(within - period) < bestd then best = period end   -- snapping up to next root is closer
  if math.abs(best - period) < 0.001 then return (periods + 1) * period end
  return periods * period + best
end

-- scale degrees within one period, ascending: 0, then every interval except the period itself.
local function degrees_in_period(intervals)
  local d = { 0.0 }
  for i = 1, #intervals - 1 do d[#d + 1] = intervals[i] end
  return d
end

-- snap a (fractional) MIDI note to the active scale, relative to root. Returns a fractional MIDI note.
function M.quantize(midi)
  local sc = M.scales[M.idx]
  if not sc or #sc.cents == 0 then return midi end      -- Off = passthrough
  local snapped = snap_cents(sc.cents, (midi - M.root) * 100.0)
  return M.root + snapped / 100.0
end

-- the next scale note above/below `midi` (dir = +1 / -1) for note-by-note pitch nav. Fractional MIDI.
function M.next(midi, dir)
  local sc = M.scales[M.idx]
  if not sc or #sc.cents == 0 then return midi + dir end   -- Off: chromatic step
  local intervals = sc.cents
  local period = intervals[#intervals]
  local cents = (midi - M.root) * 100.0
  local periods = math.floor(cents / period)
  local within = cents - periods * period
  local degs = degrees_in_period(intervals)
  if dir > 0 then
    for _, d in ipairs(degs) do
      if d > within + 0.001 then return M.root + (periods * period + d) / 100.0 end
    end
    return M.root + ((periods + 1) * period) / 100.0           -- root of the next period
  else
    for i = #degs, 1, -1 do
      if degs[i] < within - 0.001 then return M.root + (periods * period + degs[i]) / 100.0 end
    end
    return M.root + ((periods - 1) * period + degs[#degs]) / 100.0   -- top degree of the previous period
  end
end

function M.add_params()
  params:add_separator("dronage_scale_sep", "scale")
  params:add{ type = "option", id = "dronage_scale", name = "scale",
    options = options.labels("scale"), default = D.global.scale,
    action = function(v) M.idx = options.value("dronage_scale", v) end }
  params:add{ type = "option", id = "dronage_root", name = "root",
    options = options.labels("root"), default = D.global.root,
    action = function(v) M.root = options.value("dronage_root", v) end }
end

return M
