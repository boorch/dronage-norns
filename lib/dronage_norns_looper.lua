-- dronage-norns live looper ("LL" view): ONE master loop of the engine output, softcut-backed.
-- Design + verified softcut facts: _docs/dronage/12-live-looper-plan.md (SEAMS spec adapted:
-- single loop, stereo, engine.duck live side, quantized-PLAY host grid).
--
-- Topology: the engine's jack output feeds softcut's input bus (audio.level_eng_cut). A stereo
-- recorder pair (v5/v6) writes it into a take region; two stereo deck pairs (v1/v2, v3/v4)
-- flip-flop playback so a re-record crossfades seamlessly from the old take to the new one.
-- Fresh records ALTERNATE between two take regions per buffer, so a capture never overwrites
-- the region the playing deck is still reading. The crossfader ducks the engine (equal-power)
-- against the deck levels; ducking also ducks the record tap (crone mixes level_eng BEFORE
-- level_eng_cut - serial, verified in MixerClient.cpp - so "record while faded out" cannot
-- exist on norns; we warn and record anyway).
--
-- Softcut rules honored (all device-verified): rec flag stays 1 on the recorder, punches ride
-- rec_level/pre_level via recpre_slew (rec toggles are NOT faded); punch-out restores
-- pre_level=1 (an engaged head with pre<1 erodes content every pass); loops free-run on the
-- audio clock, so a respin coroutine re-pins the playhead every cycle (drift never exceeds one
-- cycle's clock error, hidden under fade_time); play=0+rec=0 hard-stops a voice (idle = free).

local M = {}

-- stereo voice plan: pairs are {L, R}; L voices on buffer 1, R voices on buffer 2
local DECK_A, DECK_B, REC = { 1, 2 }, { 3, 4 }, { 5, 6 }
-- two take regions per buffer (identical offsets in both buffers). 1s lead-in margin for
-- fade reads; 0.5s tail guard between/after regions (rec head writes past loop_end by
-- fade_time during wrap fades, + the 8-sample write offset).
local REGLEN = 170.0
local REGION = { 1.0, 1.0 + REGLEN + 0.5 }
local GUARD = 0.010        -- playback loop_end extends past the musical end into the punch tail
local FADE = 0.010         -- seam fade: covers loop wrap, respin jumps, take morphs
local TAKE_XFADE = 0.5     -- old take -> new take morph on re-record/launch (seconds)

M.state = "idle"           -- idle | armed | rec  (armed/rec cover both fresh and overdub passes)
M.filled = false
M.len = 0                  -- measured wall seconds of the loop
M.beats = 0                -- musical length in beats
M.phase = 0                -- playhead 0..1 inside the loop (UI)
M.out_pending = false      -- early punch-out armed (K3 during rec)

local C                    -- host ctx: { duck = fn(x), toast = fn(msg) }
local inited = false
local front = DECK_A       -- deck pair carrying the loop side
local deck_w = { [1] = 0, [3] = 0 }  -- weight per deck pair, keyed by the pair's L voice
local deck_b0 = 0          -- absolute beat of the front deck's launch (overdub phase math)
local take = 1             -- region index the CURRENT loop lives in; fresh records flip it
local spin_clk, rec_clk, retire_clk, relaunch_clk
local out_req = false

local function other(pair) return (pair == DECK_A) and DECK_B or DECK_A end

local function quant() return ({ 1, 2, 4, 8 })[params:get("lp_quant")] end
local function rec_len() return ({ 4, 8, 16, 32, 64, 128 })[params:get("lp_len")] end

-- sleep until an absolute beat target; recomputes each hop so it self-corrects under tempo
-- drift (never clock.sleep a fixed musical duration - the error would be unbounded).
-- Returns false if the beat count went BACKWARDS: a Link/MIDI transport start (or the
-- CLOCK>reset trigger) re-zeros clock.get_beats(), which strands the target - and every
-- other launch-relative anchor - in a dead beat frame. Callers must bail out, not wait.
local function sleep_to_beat(target)
  local last = clock.get_beats()
  while true do
    local now = clock.get_beats()
    if now < last - 0.01 then return false end
    last = now
    local d = target - now
    if d <= 0.0005 then return true end
    clock.sleep(math.max(0.001, math.min(d * clock.get_beat_sec(), 0.05)))
  end
end

-- wait for the next multiple of q beats on the HOST grid: anchored to transport_start
-- while the transport plays (so q>1 punches land on the sequencer phrase, not on absolute
-- multiples of q since boot), absolute otherwise. Latched target (recomputing per wake is
-- the Zeno trap). Returns false on a beat-count reset, like sleep_to_beat.
local function sync_q(q)
  local a = (C.anchor and C.anchor()) or 0
  local k = math.ceil((clock.get_beats() - a) / q - 1e-4)
  return sleep_to_beat(a + k * q)
end

-- equal-power crossfade: live side ducks the ENGINE (lagged in SC), loop side = deck levels
function M.apply_levels()
  if not inited then return end
  local x = params:get("lp_xfade")
  C.duck(math.cos(x * math.pi * 0.5))
  local loop = math.sin(x * math.pi * 0.5)
  for _, pair in ipairs({ DECK_A, DECK_B }) do
    for _, v in ipairs(pair) do softcut.level(v, loop * deck_w[pair[1]]) end
  end
end

local function setup_voice(v, buf)
  softcut.enable(v, 1)
  softcut.buffer(v, buf)
  softcut.rate(v, 1)
  softcut.rate_slew_time(v, 0)
  softcut.loop(v, 1)
  softcut.play(v, 1)     -- motion + read path on; output gated by level instead
  softcut.level(v, 0)
  softcut.pan(v, (buf == 1) and -1 or 1)   -- L voices hard left, R voices hard right
  softcut.rec(v, 0)
  softcut.rec_level(v, 0)
  softcut.pre_level(v, 1)
  softcut.level_slew_time(v, 0.02)
  softcut.recpre_slew_time(v, 0.004)   -- punch ramps; the punch-out tail the wrap fade lands on
  softcut.fade_time(v, FADE)
  softcut.post_filter_dry(v, 1)
end

-- start the (re)captured loop on the back deck at absolute beat b0, morph decks, retire the old
local function do_launch(b0)
  -- a zero-length launch would loop a ~10ms buzz AND spin its respin coroutine without
  -- ever yielding (matron hard-lock) - refuse any degenerate state outright
  if not M.filled or M.beats <= 0 or M.len <= 0 then return end
  local back = other(front)
  local rstart = REGION[take]
  for _, v in ipairs(back) do
    softcut.loop_start(v, rstart)
    softcut.loop_end(v, rstart + M.len + GUARD)
    softcut.position(v, rstart)
    softcut.play(v, 1)
    softcut.level_slew_time(v, TAKE_XFADE)
    softcut.phase_quant(v, (v == back[1]) and 0.05 or 60)
  end
  for _, v in ipairs(front) do
    softcut.level_slew_time(v, TAKE_XFADE)
    softcut.phase_quant(v, 60)
  end
  deck_w[back[1]], deck_w[front[1]] = 1, 0
  M.apply_levels()

  -- respin: re-pin the playhead to loop start every L beats on the absolute grid (loops
  -- free-run on the audio clock; the position jump hides under fade_time)
  if spin_clk then clock.cancel(spin_clk) end
  deck_b0 = b0
  local L = M.beats
  spin_clk = clock.run(function()
    local k = 1
    while true do
      if not sleep_to_beat(b0 + k * L) then return end   -- beat reset: anchors dead; the
                                                         -- host's transport hook relaunches us
      -- if matron stalled (project load bursts hundreds of param actions) this fires LATE,
      -- after the loop already wrapped seamlessly on its own points - re-pinning now would
      -- yank the playhead back audibly. Skip the correction; next cycle re-pins on time.
      if (clock.get_beats() - (b0 + k * L)) * clock.get_beat_sec() < 0.03 then
        for _, v in ipairs(back) do softcut.position(v, rstart) end
      end
      k = k + 1
    end
  end)

  local old = front
  front = back
  if retire_clk then clock.cancel(retire_clk) end
  retire_clk = clock.run(function()
    clock.sleep(TAKE_XFADE + 0.1)
    if front == back then
      for _, v in ipairs(old) do softcut.play(v, 0) end
      for _, pair in ipairs({ DECK_A, DECK_B }) do
        for _, v in ipairs(pair) do softcut.level_slew_time(v, 0.02) end
      end
    end
    retire_clk = nil
  end)
end

-- K3 verb: idle+empty = arm fresh record · idle+filled = arm overdub · recording = arm early
-- punch-out at the next quantize boundary (recording auto-punches-out at Rec Length anyway,
-- so a long length + K3-out is effectively open-ended capture with a ceiling)
function M.record()
  if not inited then return end
  if M.state == "rec" then
    out_req = true
    M.out_pending = true
    return
  end
  if M.state == "armed" then return end   -- a punch, once armed, completes (no cancel in v1)

  local overdub = M.filled
  local L = overdub and M.beats or rec_len()
  local q = quant()
  local rtake = overdub and take or (3 - take)   -- fresh records go to the OTHER region, so the
  local rstart = REGION[rtake]                   -- playing deck's audio is never written under it
  if not overdub then
    if L * clock.get_beat_sec() + 1.0 > REGLEN then
      C.toast("TOO LONG AT THIS BPM"); return
    end
  end
  if params:get("lp_xfade") > 0.98 then C.toast("LIVE SIDE IS FADED OUT") end

  M.state = "armed"
  out_req = false
  M.out_pending = false

  rec_clk = clock.run(function()
    -- (buffers are bound once in init - never reassign mid-run: crone stops a voice on
    -- buffer reassignment, which would silently disengage the record head)
    for _, v in ipairs(REC) do
      if overdub then        -- the pass must wrap with the loop's own playback points
        softcut.loop_start(v, rstart); softcut.loop_end(v, rstart + M.len + GUARD)
      else                   -- single free pass: must NOT wrap during capture
        softcut.loop_start(v, rstart); softcut.loop_end(v, rstart + REGLEN - 0.5)
      end
    end

    if not sync_q(q) then   -- beat count reset while armed: the boundary we waited for is gone
      M.state = "idle"; rec_clk = nil
      C.toast("CLOCK RESET - ARM CANCELLED")
      return
    end
    local b0 = clock.get_beats()

    -- overdubbing mid-cycle: land the write head at the deck's current phase, not loop start.
    -- offset moved in real seconds at the CURRENT tempo since the last respin.
    local pos = rstart
    if overdub and M.filled then
      pos = rstart + ((b0 - deck_b0) % L) * clock.get_beat_sec()
    end
    for _, v in ipairs(REC) do softcut.position(v, pos) end
    for _, v in ipairs(REC) do
      softcut.pre_level(v, overdub and params:get("lp_od_pre") or 0)
      softcut.rec_level(v, 1)
    end
    M.state = "rec"
    local t0 = util.time()

    -- chase punch-out: auto at b0+L, or the next quantize boundary once K3 arms an early
    -- out. The early target is LATCHED when the request first arrives - recomputing it per
    -- iteration is a Zeno trap (every wake lands a hair past the boundary, ceil() pushes
    -- the target to the next one, and the punch-out never fires). Two abort tripwires:
    -- a beat-count reset strands b0 in a dead frame (the pass could never close), and a
    -- fresh pass approaching the region's WALL-TIME end (tempo dropped mid-pass) must stop
    -- before the recorder wraps and eats its own take.
    local Lact, early, aborted
    while true do
      local now = clock.get_beats()
      if now < b0 - 0.01 then aborted = "CLOCK RESET"; break end
      if not overdub and (util.time() - t0) > (REGLEN - 1.5) then aborted = "TOO LONG"; break end
      if out_req and not early then
        local e = math.ceil((now - b0) / q - 1e-4) * q
        if e < q then e = q end
        early = b0 + e
      end
      local target = b0 + L
      if early and early < target then target = early end
      if now >= target - 0.0005 then Lact = target - b0; break end
      clock.sleep(math.max(0.001, math.min((target - now) * clock.get_beat_sec(), 0.05)))
    end

    for _, v in ipairs(REC) do
      softcut.rec_level(v, 0)   -- 4ms slew writes the tail the wrap fade lands on
      softcut.pre_level(v, 1)   -- CRITICAL: an engaged head with pre<1 erodes the loop
    end
    local t1 = util.time()

    if aborted then
      C.toast((overdub and "OVERDUB ABORTED - " or "CAPTURE ABORTED - ") .. aborted)
    elseif not overdub then
      M.len = t1 - t0           -- measured wall seconds: exact even if tempo drifted mid-pass
      M.beats = Lact
      M.filled = true
      take = rtake
      do_launch(b0 + Lact)      -- gapless: the loop starts at the boundary the pass closed on
    end
    M.state = "idle"
    out_req = false
    M.out_pending = false
    rec_clk = nil
    if aborted == "CLOCK RESET" and M.filled then M.relaunch() end   -- surviving loop: re-pin on the new grid
  end)
end

-- re-pin the sounding loop to the fresh beat grid (Link/MIDI transport start resets
-- clock.get_beats(), invalidating every launch-relative anchor - relaunch rebuilds them).
-- Tracked handle (cancel-and-replace; erase/cleanup cancel it) and the launch conditions
-- are RE-CHECKED at the boundary: the state can change during the up-to-q-beat wait (an
-- erase mid-wait once launched a zero-length loop whose respin never yielded - hard-lock).
function M.relaunch()
  if not (inited and M.filled) or M.state ~= "idle" then return end
  if relaunch_clk then clock.cancel(relaunch_clk) end
  relaunch_clk = clock.run(function()
    local ok = sync_q(quant())
    relaunch_clk = nil
    if ok and M.filled and M.state == "idle" then do_launch(clock.get_beats()) end
  end)
end

-- erase everything (behind the host's confirm dialog). Refused mid-recording: K3's early
-- punch-out is the abort gesture. Buffer audio isn't zeroed - it's unreachable without metadata.
function M.erase()
  if not inited then return false, "LOOPER NOT READY" end
  if M.state == "armed" then return false, "PUNCH-IN ARMED" end
  if M.state ~= "idle" then return false, "STILL RECORDING" end
  if relaunch_clk then clock.cancel(relaunch_clk); relaunch_clk = nil end
  for _, pair in ipairs({ DECK_A, DECK_B }) do
    for _, v in ipairs(pair) do softcut.level_slew_time(v, 0.05) end
    deck_w[pair[1]] = 0
  end
  M.apply_levels()
  if spin_clk then clock.cancel(spin_clk); spin_clk = nil end
  if retire_clk then clock.cancel(retire_clk); retire_clk = nil end
  M.filled = false
  M.len, M.beats, M.phase = 0, 0, 0
  clock.run(function()
    clock.sleep(0.2)
    if not M.filled then
      for _, pair in ipairs({ DECK_A, DECK_B }) do
        for _, v in ipairs(pair) do softcut.play(v, 0) end
      end
    end
  end)
  return true
end

function M.init(ctx)
  C = ctx
  audio.level_eng_cut(1)        -- engine -> softcut input bus; without this we record silence
  softcut.buffer_clear()        -- predictable silence, no ghost audio from a previous script
  for _, pair in ipairs({ DECK_A, DECK_B, REC }) do
    for i, v in ipairs(pair) do setup_voice(v, i) end
  end
  for _, pair in ipairs({ DECK_A, DECK_B }) do
    for _, v in ipairs(pair) do softcut.play(v, 0) end   -- decks idle (heads stopped = free)
  end
  for _, v in ipairs(REC) do softcut.rec(v, 1) end   -- rec flag stays 1 forever; punches ride
                                                     -- rec_level/pre_level (toggles aren't faded)
  -- feed the cut input bus (carrying the engine, via level_eng_cut) into the recorder pair:
  -- bus ch1 -> REC L voice, ch2 -> REC R voice. Without this every recording is silence.
  softcut.level_input_cut(1, REC[1], 1.0)
  softcut.level_input_cut(2, REC[2], 1.0)
  softcut.event_phase(function(v, ph)
    if M.filled and v == front[1] and M.len > 0 then
      M.phase = util.clamp((ph - REGION[take]) / M.len, 0, 1)
    end
  end)
  for v = 1, 6 do softcut.phase_quant(v, 60) end
  softcut.poll_start_phase()
  inited = true
  M.apply_levels()
end

function M.cleanup()
  if not inited then return end
  if spin_clk then clock.cancel(spin_clk) end
  if rec_clk then clock.cancel(rec_clk) end
  if retire_clk then clock.cancel(retire_clk) end
  if relaunch_clk then clock.cancel(relaunch_clk) end
  softcut.poll_stop_phase()
  audio.level_eng_cut(0)   -- don't leak engine audio into the next script's softcut recordings
  C.duck(1)
  inited = false
end

return M
