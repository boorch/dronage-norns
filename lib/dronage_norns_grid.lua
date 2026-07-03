-- dronage-norns grid 128 support (OPTIONAL - the script is fully usable without a grid).
-- Layout (16x8):
--   rows 1-5, cols 1-5  : the 5x5 CV sequencer. brightness = |step value|, playhead boosted.
--                         press a step = toggle it on/off (quick pattern entry; fine values
--                         on the encoders). only steps within each track's length are lit.
--   row 7, cols 1-8     : live LFO scope (brightness = |LFO value|).
--   row 8, cols 1-4     : voice on/off (bright = playing). press = toggle that voice.
-- All grid ops are pcall-guarded by the host so a missing/erroring grid never breaks audio.

local M = {}
local g
local seq, mtx
local STEP_ON = 0.7

function M.init(seq_mod, mtx_mod)
  seq, mtx = seq_mod, mtx_mod
  g = grid.connect()
  g.key = function(x, y, z)
    if z ~= 1 then return end
    if y >= 1 and y <= seq.NUM_TRACKS and x >= 1 and x <= seq.NUM_STEPS then
      local tr = seq.tracks[y]
      tr.steps[x] = (math.abs(tr.steps[x] or 0) > 0.05) and 0 or STEP_ON
    elseif y == 8 and x >= 1 and x <= 4 then
      local on = params:get("v" .. x .. "_level") > 0.02
      params:set("v" .. x .. "_level", on and 0 or 0.7)
    end
  end
end

function M.redraw()
  if not g or g.device == nil then return end
  g:all(0)
  for t = 1, seq.NUM_TRACKS do
    local tr = seq.tracks[t]
    for s = 1, seq.NUM_STEPS do
      if s <= tr.length then
        local lv = util.round(math.abs(tr.steps[s] or 0) * 11)
        if s == tr.current_step then lv = math.min(15, math.max(lv, 5) + 4) end
        g:led(s, t, lv)
      end
    end
  end
  for s = 1, mtx.NUM_SRC do
    g:led(s, 7, util.round(math.abs(mtx.src[s].value) * 15))
  end
  for v = 1, 4 do
    g:led(v, 8, params:get("v" .. v .. "_level") > 0.02 and 12 or 2)
  end
  g:refresh()
end

return M
