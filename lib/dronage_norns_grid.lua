-- dronage-norns GRID 128 (OPTIONAL - the script behaves identically without one).
-- A MIRROR of the norns UI, never a second brain: every pad routes through the screens
-- module's semantic API (scr.grid_*), which shares the exact code paths of the physical
-- keys/encoders - same per-param feel, same undo, same confirms, same toasts.
--
-- Layout (16 x 8): cols 1-8 = the MINIMAP MIRROR (pad (x,y) = the view at registry
-- row y, col x-1 - identical geometry to the on-screen minimap):
--   row 1: HOME                   cols 13..16 (rows 1-2): S1..S8 scene launch pads
--   row 2: V1-V4 (SHIFT+pad = gate; SHIFT+scene-pad: hold 1.5s = COPY, tap = PASTE)
--   row 3: E1-E4
--   row 4: L1-L8 (live value brightness)
--   row 5: MM x8 (jump straight to that LFO's matrix column, same dest row)
--   row 6: DELAY REVERB MASTER    rows 5-8, cols 13-16 control block:
--   row 7: MACRO CVSEQ SCENES       RST RND  NO YES
--   row 8: GLOBAL PROJECT           SHF MAP UDO RDO
--                                    +  <<   ^  >>
-- HOME held 2s = visualizer         -   <   v   >
-- (any press exits).
-- Brightness grammar: 0 = strictly no-op; every actionable pad >= INACT (value-mapped
-- pads floor there too). Blink = a dialog waits for YES/NO. All ops pcall-guarded.

local M = {}
local g
local C   -- injected: { scr, mtx, euclid, scenes, mod_result, blocked }

-- +/- key-repeat, frame-quantized from the host's 30 fps tick (deterministic; the bounded
-- rate keeps the encoders' turn-speed accel multiplier constant instead of exploding).
-- ponytail: tune all of these on the device by feel.
-- user-tuned 2026-07-05: plain +/- runs what used to be the SHIFT curve; SHIFT doubles
-- everything again (half delay, twice accel, twice rate); arrows ride the SHIFT feel
-- (delta always 1); << >> ride the plain +/- feel (delta always 1).
local REP  = { delay = 0.30,  r0 = 7.5, r1 = 15, ramp = 1.0, dmax = 6, dramp = 1.0 }   -- plain + -
local REPS = { delay = 0.075, r0 = 15,  r1 = 30, ramp = 0.5, dmax = 12, dramp = 1.0 }  -- SHIFT + - (delta 1->12 in 1s)
local NAV  = { delay = 0.20,  r0 = 15,  r1 = 30, ramp = 0.5 }                          -- arrows (decoupled: own delay)
local PAGE = { delay = 0.30,  r0 = 7.5, r1 = 15, ramp = 1.0 }                          -- << >>

local shift, viz = false, false
local shift_used = false   -- another pad pressed during the SHIFT hold -> release is NOT a tap
local sc_hold = nil        -- SHIFT+scene-pad gesture: { i, t0, done } (1.5s = copy, tap = paste)
local home_hold = nil      -- HOME pad press time; 3s hold = enter the visualizer
local SC_COPY_HOLD, HOME_VIZ_HOLD = 1.5, 2.0
local rep = {}            -- held-repeat state: [id] = { t0, at, sign|dy }
local last_activity = 0   -- grid presses + host enc/key pokes (idle -> visualizer)
local had_device = false  -- hotplug edge detect (clear stale holds on re-attach)
local last_frame = nil
local env  = { 0, 0, 0, 0 }   -- simulated per-voice gate fade envelope 0..1
local ping = { 0, 0, 0, 0 }   -- per-voice euclid trigger flash 0..1 (decays per lpgdecay)
local stars = {}

-- control block (x >= 13, y >= 5) -> action id
local CB = {
  [5] = { [13] = "rst",  [14] = "rnd",  [15] = "no",   [16] = "yes" },
  [6] = { [13] = "shf",  [14] = "map",  [15] = "udo",  [16] = "rdo" },
  [7] = { [13] = "plus", [14] = "prev", [15] = "up",   [16] = "next" },
  [8] = { [13] = "minus",[14] = "left", [15] = "down", [16] = "right" },
}

local function ready() return g and g.device ~= nil and g.cols >= 16 and g.rows >= 8 end
function M.connected() return ready() end   -- host/screens: GLOBAL's Grid Brightness row gate

function M.activity() last_activity = util.time() end   -- host enc()/key() poke this too

-- master LED dimmer (the GLOBAL "grid brightness" param): every draw goes through led(),
-- scaled by the level's factor; nonzero floors at 2 - hardware level 1 reads as OFF, and
-- a lit pad must stay visibly lit at every dimmer setting (the no-op rule).
local BSCALE = { 0.25, 0.75, 1.0 }
local bright = 1.0   -- refreshed once per frame in M.redraw
local function led(x, y, b)
  if b > 0 then b = math.max(2, util.round(b * bright)) end
  g:led(x, y, b)
end
-- viz-only variant: scaled by the dimmer but NO floor - nothing there is pressable, so
-- bullets and tails may fade all the way to black
local function led_raw(x, y, b)
  g:led(x, y, math.min(15, util.round(b * bright)))
end

-- ---------- visualizer (display-only; driven by real post-mod signals) ----------
-- The viz composites ADDITIVELY: every element adds into a 16x8 framebuffer (overlaps
-- blend and bloom instead of overwriting), clamped to 15 on flush through led().
local sparks = {}   -- euclid trigger flashes: { x, y, t0, dur } (dur = that voice's lpgdecay)
local glows = {}    -- change halos: the 8 pads around a moved/appeared note light up + fade
local GLOW_LIFE, GLOW_B = 0.5, 8       -- s, halo launch brightness (under the note's own 12+)
local GLOW_COOLDOWN = 0.25             -- per-star: no re-halo faster than this (popcorn guard)
local fb = {}
local function fb_clear() for i = 1, 128 do fb[i] = 0 end end
local function fb_add(x, y, b)
  if b > 0 and x >= 1 and x <= 16 and y >= 1 and y <= 8 then
    local i = (y - 1) * 16 + x
    fb[i] = fb[i] + b
  end
end
local function glow(x, y)   -- halo around (x, y)
  glows[#glows + 1] = { x = x, y = y, t0 = util.time() }
  while #glows > 24 do table.remove(glows, 1) end
end

local function pitch_band(vo)   -- post-mod pitch -> CONTINUOUS row (high notes near the top)
  local m = (C.mod_result and C.mod_result["v" .. vo .. "_pitch"]) or params:get("v" .. vo .. "_pitch") or 60
  return 8 - (m - 12) / 96 * 7
end

local function init_stars()
  stars = {}
  for i = 1, 14 do
    stars[i] = { x = math.random(16), voice = (i - 1) % 4 + 1, off = math.random(-1, 1),
                 ph = math.random() * 6.28, rate = 0.25 + math.random() * 0.6 }
  end
end

function M.spark(v)   -- called from the euclid on_trig hook while the visualizer is up
  local x, y = math.random(16), util.clamp(util.round(pitch_band(v)), 1, 8)
  sparks[#sparks + 1] = { x = x, y = y, t0 = util.time(),
                          dur = math.max(0.15, params:get("v" .. v .. "_lpgdecay") or 0.5) }
  if #sparks > 16 then table.remove(sparks, 1) end
  glow(x, y)   -- every trigger appearance halos
end

local function draw_viz(now)
  fb_clear()
  -- LFO shimmer layer (dim): each ROUTED LFO is a pixel bobbing with its live value in its
  -- own column - modulation weather stays visible while drones hold still
  for s = 1, 8 do
    local routed = false
    for d = 1, #C.mtx.dests do
      if (C.mtx.cell[d][s] or 0) ~= 0 then routed = true; break end
    end
    if routed then
      local v = util.clamp(C.mtx.src[s].value or 0, -1, 1)
      fb_add(s * 2 - 1, util.clamp(4 - util.round(v * 3), 1, 8), 2 + util.round(math.abs(v) * 3))
    end
  end
  -- stars: existence/brightness = gate fade envelope, twinkle speed = post-mod cutoff,
  -- vertical position FOLLOWS post-mod pitch continuously (S&H melodies step their stars).
  -- Any star that APPEARS or lands on a new cell bursts (that's the visible event grammar:
  -- something moved -> light shoots out of it).
  for _, s in ipairs(stars) do
    local vis = env[s.voice]
    if vis > 0.03 then
      local cut = (C.mod_result and C.mod_result["v" .. s.voice .. "_cut"])
                  or params:get("v" .. s.voice .. "_cut") or 5000
      local rmul = 0.4 + util.clamp(math.log(cut / 100) / math.log(200), 0, 1) * 1.6
      local tw = 0.5 + 0.5 * math.sin(s.ph + now * s.rate * rmul * 2 * math.pi)
      local y = util.clamp(util.round(pitch_band(s.voice) + s.off), 1, 8)
      if (s.lx ~= s.x or s.ly ~= y) and now - (s.lb or 0) > GLOW_COOLDOWN then
        glow(s.x, y); s.lb = now   -- appeared or changed place (cooldown tames popcorn)
      end
      s.lx, s.ly = s.x, y
      fb_add(s.x, y, util.round(vis * (1 + tw * 11)))
    else
      s.lx, s.ly = nil, nil   -- gone dark: next appearance bursts again
    end
  end
  -- euclid trigger sparks: full-bright flashes decaying at that voice's LPG decay
  for i = #sparks, 1, -1 do
    local sp = sparks[i]
    local a = 1 - (now - sp.t0) / sp.dur
    if a <= 0 then table.remove(sparks, i)
    else fb_add(sp.x, sp.y, util.round(3 + a * 12)) end
  end
  -- change halos: the 8 neighbors of a moved/appeared note, fading out over GLOW_LIFE
  for i = #glows, 1, -1 do
    local gl = glows[i]
    local a = 1 - (now - gl.t0) / GLOW_LIFE
    if a <= 0 then table.remove(glows, i)
    else
      local b = util.round(GLOW_B * a * a)   -- squared = soft landing
      if b > 0 then
        for dy = -1, 1 do
          for dx = -1, 1 do
            if dx ~= 0 or dy ~= 0 then fb_add(gl.x + dx, gl.y + dy, b) end
          end
        end
      end
    end
  end
  if math.random() < 0.01 then   -- occasional drift: a star relocates (the move itself
    local s = stars[math.random(#stars)]   -- bursts via the cell-change detection above)
    s.x, s.off, s.ph = math.random(16), math.random(-1, 1), math.random() * 6.28
  end
  fb_add(16, 8, 1 + util.round((0.5 + 0.5 * math.sin(now * 0.4)) * 2))   -- heartbeat
  for y = 1, 8 do   -- additive flush; dimmer-scaled, NO floor (viz may fade to black)
    local row = (y - 1) * 16
    for x = 1, 16 do
      local v = fb[row + x]
      if v > 0 then led_raw(x, y, math.min(15, v)) end
    end
  end
end

-- ---------- input ----------
local function press(x, y)
  local id = CB[y] and CB[y][x]
  if shift and id ~= "shf" then shift_used = true end   -- SHIFT acted as a modifier this hold
  if id then
    if id == "shf" then shift = true; shift_used = false
    elseif id == "map" then C.scr.grid_map(1)
    elseif id == "plus" or id == "minus" then
      local sign = (id == "plus") and 1 or -1
      C.scr.grid_tweak(sign)
      rep[id] = { t0 = util.time(), at = util.time(), sign = sign }
    elseif id == "up" or id == "down" or id == "left" or id == "right" then
      local dx = (id == "right" and 1) or (id == "left" and -1) or 0
      local dy = (id == "down" and 1) or (id == "up" and -1) or 0
      C.scr.grid_nav(dx, dy, shift)   -- SHIFT+up/down on the matrix = whole-voice jump
      rep[id] = { t0 = util.time(), at = util.time(), dx = dx, dy = dy }
    elseif id == "prev" or id == "next" then
      local dir = (id == "next") and 1 or -1
      C.scr.grid_page(dir)
      rep[id] = { t0 = util.time(), at = util.time(), page = dir }
    elseif id == "rst" then C.scr.grid_reset()
    elseif id == "rnd" then C.scr.grid_random()
    elseif id == "no" then C.scr.grid_no()
    elseif id == "yes" then C.scr.grid_yes()
    elseif id == "udo" then C.scr.grid_undo()
    elseif id == "rdo" then C.scr.grid_redo() end
    return
  end
  if (y == 1 or y == 2) and x >= 13 then   -- scene pads: launch, or SHIFT hold/tap = copy/paste
    local i = (y - 1) * 4 + (x - 13) + 1
    if shift then sc_hold = { i = i, t0 = util.time() }
    else C.scr.grid_scene(i) end
  elseif x <= 8 then                        -- the minimap mirror (view at row y, col x-1)
    if y == 2 and x <= 4 and shift then     -- SHIFT+Vn = gate toggle (fades apply as always)
      params:set("v" .. x .. "_gate", params:get("v" .. x .. "_gate") == 1 and 0 or 1)
    else
      C.scr.grid_jump_rc(y, x - 1)
      if y == 1 and x == 1 then home_hold = util.time() end   -- keep holding 3s -> visualizer
    end
  end
end

local function release(x, y)
  local id = CB[y] and CB[y][x]
  if x == 1 and y == 1 then home_hold = nil end
  if sc_hold and x == 13 + (sc_hold.i - 1) % 4 and y == 1 + math.floor((sc_hold.i - 1) / 4) then
    if not sc_hold.done and not viz and ready() and not C.blocked() then
      C.scr.grid_scene_paste(sc_hold.i)   -- released before the copy threshold = paste
    end
    sc_hold = nil
    return
  end
  if id == "shf" then
    local tap = shift and not shift_used   -- clean tap = the view's K3-style execute
    shift = false
    if tap and not viz and ready() and not C.blocked() then C.scr.grid_execute() end
  elseif id == "map" then C.scr.grid_map(0)
  elseif id and rep[id] then rep[id] = nil end
end

local function handle_key(x, y, z)
  M.activity()
  if z == 0 then release(x, y); return end   -- releases ALWAYS processed (clears holds)
  if not ready() or C.blocked() then return end
  if viz then viz = false; return end        -- any press exits the visualizer (consumed)
  press(x, y)
end

-- ---------- per-frame engine (rides the host's 30 fps redraw call; no metros) ----------
local function tick(now, dt, st)
  -- SHIFT+scene-pad: the copy fires AT the hold threshold (pad ramps toward it, see LEDs)
  if sc_hold and not sc_hold.done and now - sc_hold.t0 >= SC_COPY_HOLD then
    sc_hold.done = true
    if not C.blocked() then C.scr.grid_scene_copy(sc_hold.i) end
  end
  if home_hold and not viz and now - home_hold >= HOME_VIZ_HOLD then
    home_hold = nil; viz = true
  end
  if C.blocked() then
    for id in pairs(rep) do rep[id] = nil end   -- an overlay took over mid-hold: stop repeating
    sc_hold, home_hold = nil, nil
  else
    for id, r in pairs(rep) do
      local held = now - r.t0
      if r.sign then   -- +/- : slow start, accelerate, then widen the delta
        local cfg = shift and REPS or REP
        if held >= cfg.delay then
          local p = math.min(1, (held - cfg.delay) / cfg.ramp)
          if now - r.at >= 1 / (cfg.r0 + (cfg.r1 - cfg.r0) * p) then
            r.at = now
            local dp = util.clamp((held - cfg.delay - cfg.ramp) / cfg.dramp, 0, 1)
            local d = util.round(1 + (cfg.dmax - 1) * dp)
            -- matrix depth cells are 0.1%-step bipolar (2000 steps): SHIFT gets 10x there
            -- so both rails are reachable in a hold (user-tuned 2026-07-05)
            if shift and st.kind == "matrix" then d = d * 10 end
            C.scr.grid_tweak(r.sign * d)
          end
        end
      elseif r.page and held >= PAGE.delay then
        local p = math.min(1, (held - PAGE.delay) / PAGE.ramp)
        if now - r.at >= 1 / (PAGE.r0 + (PAGE.r1 - PAGE.r0) * p) then
          r.at = now
          C.scr.grid_page(r.page)
        end
      elseif (r.dx or r.dy) and held >= NAV.delay then
        local p = math.min(1, (held - NAV.delay) / NAV.ramp)
        if now - r.at >= 1 / (NAV.r0 + (NAV.r1 - NAV.r0) * p) then
          r.at = now
          C.scr.grid_nav(r.dx or 0, r.dy or 0, shift)
        end
      end
    end
  end
  -- voice pad life: gate fade envelope sim (attack/decay secs) + euclid trigger pings
  for v = 1, 4 do
    local on = params:get("v" .. v .. "_gate") == 1
    local t = params:get("v" .. v .. (on and "_attack" or "_decay")) or 1
    local step = dt / math.max(0.05, t)
    local target = on and 1 or 0
    if env[v] < target then env[v] = math.min(target, env[v] + step)
    elseif env[v] > target then env[v] = math.max(target, env[v] - step) end
    if ping[v] > 0 then
      ping[v] = math.max(0, ping[v] - dt / math.max(0.05, params:get("v" .. v .. "_lpgdecay") or 0.5))
    end
  end
  -- idle -> visualizer (0 = never)
  local idlemin = params:get("dronage_grid_idle") or 0
  if idlemin > 0 and not viz and now - last_activity > idlemin * 60 then viz = true end
end

-- ---------- LEDs ----------
-- the house brightness system: INACT (2) = present/inactive, ACT (12) = active/current.
-- Value pads (voice envelopes 2..12, LFOs 2..15) are the only exceptions, floored at INACT.
local ACT, INACT = 12, 2

local function draw_pads(now, st)
  -- the minimap mirror: one pad per view, active view = ACT; voice + LFO rows are value-driven
  for lin, vw in ipairs(C.scr.VIEWS) do
    local x, y = vw.col + 1, vw.row
    local b = (lin == st.lin) and ACT or INACT
    if y == 2 then        -- voice views: breathing gate fades, or trigger pings in euclid mode
      local e = C.euclid.tracks[x]
      if e and e.steps and e.steps >= 2 then b = INACT + util.round(ping[x] * (ACT - INACT))
      else b = INACT + util.round(env[x] * (ACT - INACT)) end
      if lin == st.lin then b = math.min(15, b + 3) end
    elseif y == 4 then    -- LFO views: live value, -1..+1 -> 2..15 (floored: pressable)
      b = INACT + util.round((util.clamp(C.mtx.src[x].value or 0, -1, 1) + 1) / 2 * (15 - INACT))
      if lin == st.lin then b = math.min(15, b + 3) end
    end
    led(x, y, b)
  end
  local lock = st.confirm_up
  for i = 1, 8 do   -- scene launch pads (dark while a dialog waits - launches no-op then)
    local x, y = 13 + (i - 1) % 4, 1 + math.floor((i - 1) / 4)
    local b = (i == C.scenes.current) and ACT or INACT
    if sc_hold and sc_hold.i == i then   -- SHIFT-hold copy: ramp to full, land bright
      b = sc_hold.done and 15 or (INACT + util.round(math.min(1, (now - sc_hold.t0) / SC_COPY_HOLD) * (15 - INACT)))
    end
    led(x, y, lock and 0 or b)
  end
end

local function draw_cb(now, st)
  local lock = st.confirm_up
  local blink = (now % 0.8 < 0.4) and 15 or 8
  led(13, 5, (st.rst_ok and not lock) and 8 or 0)              -- RST
  led(14, 5, (st.rnd_ok and not lock) and 8 or 0)              -- RND
  led(15, 5, lock and blink or (st.playing and INACT or ACT))  -- NO  = STOP; lit while stopped
  led(16, 5, lock and blink or (st.playing and ACT or INACT))  -- YES = PLAY; lit while playing
  led(13, 6, shift and ACT or INACT)                           -- SHIFT
  led(14, 6, lock and 0 or (st.map_held and ACT or INACT))     -- MAP
  led(15, 6, 6); led(16, 6, 6)                               -- UNDO REDO
  local live = lock and 0 or 8
  local tw = (st.tweak_ok and not lock) and 8 or 0               -- + - : dark where no focused value
  led(13, 7, tw); led(13, 8, tw)                             -- + -   (HOME/SCENES/PROJECT = no-op)
  led(14, 7, live); led(16, 7, live)                         -- << >>
  local yb = (st.nav_y or st.map_held) and live or 0
  local xb = (st.nav_x or st.map_held) and live or 0
  led(15, 7, yb); led(15, 8, yb)                             -- ^ v
  led(14, 8, xb); led(16, 8, xb)                             -- < >
end

-- ---------- public ----------
function M.init(ctx)
  C = ctx
  last_activity = util.time()
  init_stars()
  g = grid.connect()
  g.key = function(x, y, z) pcall(handle_key, x, y, z) end
  -- accurate voice-pad pings: fires post-probability, right where engine.trig fires
  C.euclid.on_trig = function(v)
    if ping[v] then ping[v] = 1 end
    if viz then M.spark(v) end
  end
end

M.key = handle_key                       -- REPL/testing entry (same fn the device drives)
M._press, M._release = press, release    -- REPL/testing: bypass the device/blocked gates

function M.redraw()
  if not g then return end
  local dev = g.device ~= nil
  if dev and not had_device then rep = {}; shift = false; sc_hold, home_hold = nil, nil end   -- replug: stale holds cleared
  had_device = dev
  if not ready() then return end
  local now = util.time()
  local dt = last_frame and (now - last_frame) or 0.033
  last_frame = now
  bright = BSCALE[params:get("dronage_grid_bright") or 3] or 1
  local st = C.scr.grid_state()
  tick(now, dt, st)
  g:all(0)
  if viz then draw_viz(now)
  else
    draw_pads(now, st)
    draw_cb(now, st)
  end
  g:refresh()
end

return M
