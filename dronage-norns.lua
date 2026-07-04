-- DRONAGE-NORNS by boorch
-- an ambient/drone
-- workstation for norns
--
-- - 4-voice macrosynth
-- - 8-LFO mod matrix
-- - CV seq
-- - euclidean seq
-- - forward/reverse delay
-- - shimmer reverb
-- - tape sim
-- - macro controller
-- - 8 scenes, instant recall
--
-- CONTROLS
-- - hold K1: for minimap
-- - K1 + E1: browse views
-- - E1: view within row
-- - E2: focus parameter
-- - E3: tweak value
-- - K2: play/stop (most views)
-- - K2+K3: reset/delete
--
-- VIEW ACTIONS
-- - K3 toggles gate in Home,
-- Voice and Euclid views
-- - In Mod Matrix, E1 switches
-- LFO column
-- - In Scenes K2 recalls scene
-- and K3 stores scene
-- - In Project K2 saves,
-- K3 loads
--
-- CREDITS (external DSP)
-- - Plaits (Mutable Instruments)
-- - analog tape based on
-- ChowDSP/portedplugins
-- - Greyhole reverb
-- (sc3-plugins)
-- - also SuperCollider, mi-UGens
-- Please see LICENSES.txt for license
-- information
--



-- ---- performance mode (FULL vs LITE DSP graph) ----
-- Auto-detected from the board: Pi 4 class = FULL; original norns / Pi 3 class = LITE
-- (lighter tape stage + mono voice chain - see lib/dronage_norns_perf.lua and the README).
-- Set to true/false to force a mode for testing (this line stays ACTIVE, not commented,
-- because matron's Lua VM keeps globals across script reloads - always assigning means
-- every reload re-resolves the mode; nil = auto-detect).
DRONAGE_FORCE_LITE = nil
local perf = include("dronage-norns/lib/dronage_norns_perf")
print("dronage-norns: " .. (perf.lite and "LITE" or "FULL") .. " perf mode (" .. perf.model .. ")")

local install = include("dronage-norns/lib/dronage_norns_install")
local update = include("dronage-norns/lib/dronage_norns_update")
dronage_update = update   -- deliberate global: lets the maiden REPL inspect/drive the update flow
-- Only declare the engine once the custom UGen .so are installed in Extensions - otherwise norns
-- would try to build SynthDefs against UGens scsynth hasn't loaded. First run installs + asks to
-- restart (see init/redraw below).
if install.is_installed() then engine.name = "DronageNornsSC_Main" end
local eng    = include("dronage-norns/lib/dronage_norns_engine")
local mtx    = include("dronage-norns/lib/dronage_norns_matrix")
local options = include("dronage-norns/lib/dronage_norns_options")   -- keyed (reorder/rename-safe) option params
local seq    = include("dronage-norns/lib/dronage_norns_seq")
local mac    = include("dronage-norns/lib/dronage_norns_macro")
local scales = include("dronage-norns/lib/dronage_norns_scales")
local scenes = include("dronage-norns/lib/dronage_norns_scenes")
local project = include("dronage-norns/lib/dronage_norns_project")
local ui     = include("dronage-norns/lib/dronage_norns_ui")
local grd    = include("dronage-norns/lib/dronage_norns_grid")
local euclid = include("dronage-norns/lib/dronage_norns_euclid")
local scr    = include("dronage-norns/lib/dronage_norns_screens")
local D      = include("dronage-norns/lib/dronage_norns_defaults")   -- single source of truth for defaults
local project_new   -- forward-declared NEW handler; assigned below, passed into the screens UI
local cs     = require "controlspec"

local NOTE = { "C","C#","D","D#","E","F","F#","G","G#","A","A#","B" }
local PAGES = { "voices", "mod", "seq", "scene" }
local page = 1
local sel = 1               -- voice (voices)
local mdest, msrc = 1, 1    -- dest / LFO (mod)
local strk, sstp = 1, 1     -- track / step (seq)
local scursor = 1          -- scene slot cursor
local k1 = false
local screen_dirty = true
local needs_install = false   -- first-run: UGen .so not yet in Extensions; show restart prompt
local install_ok = false
local restarting = false      -- K3 pressed on the install screen -> restarting the audio stack
local splash               -- run-time splash art frame; dismissed (and consumed) by the first input
local redraw_metro, mod_clock, seq_clock, euclid_clock

-- transport: drones ignore it; euclidean + CV seq only step while PLAYing, and every PLAY edge
-- re-zeros the transport-relative beat so LFOs (synced), the CV seq, and the euclidean all restart
-- from the top in sync. LFOs keep running while stopped (drone modulation) but reset on PLAY.
local transport = false
local transport_start = 0
local function mod_beats() return clock.get_beats() - transport_start end
local function set_transport(play)
  if play and not transport then
    transport_start = clock.get_beats()
    mtx.reset_phases()
    seq.reset()
    euclid.reset()
  end
  transport = play
  seq.running = play
end
local mod_acc = {}
local mod_result = {}      -- [param_id] = live post-mod value (or nil if unmodulated) -> UI shows it
local last_bpm = -1        -- delay tempo-sync watch
-- swappable widget: procedural orb now; swap to ui.Sprite.new{path=...} when art lands.
local orb = ui.Widget.new(ui.Shape.new{ kind = "orb", size = 5, min = 0, max = 0.25 })
local ui_amp = 0          -- live output amplitude (norns amp_out_l poll) -> sound-reactive UI
local amp_poll

local function quantize_pitch(midi) return scales.quantize(midi) end

-- forward delay: division (nullSEK list) + tempo -> delay length in samples; the UGen smooths
-- it (tape pitch-bend). ponytail: norns is 48k; read SR from the engine if that ever changes.
local function update_delay_times()
  local bpm = clock.get_tempo()
  engine.delaytime(mtx.div_beats[options.value("dronage_delay_div", params:get("dronage_delay_div"))]    * (60 / bpm) * 48000)
  engine.revtime( mtx.div_beats[options.value("dronage_revdelay_div", params:get("dronage_revdelay_div"))] * 2 * (60 / bpm) * 48000)  -- 2x: reverse buffer is twice as long
end

local function add_delay_params()
  params:add_separator("dronage_delay", "delay (forward)")
  -- forward delay controls also drive the reverse stage for now: each action mirrors into the
  -- matching dronage_revdelay_* param (so both values are set + saved, ready if the reverse stage
  -- gets its own UI later). Reverse TIME is 2x (its buffer is twice as long) via update_delay_times.
  params:add{ type = "option", id = "dronage_delay_div", name = "time",
    options = options.labels("div"), default = D.delay.div,   -- "1/4"
    action = function(v) params:set("dronage_revdelay_div", v); update_delay_times() end }
  params:add{ type = "control", id = "dronage_delay_fb", name = "feedback",
    controlspec = cs.new(0, 1, "lin", 0, D.delay.fb, ""),
    action = function(v) engine.delayfb(v); params:set("dronage_revdelay_fb", v) end }
  params:add{ type = "control", id = "dronage_delay_tone", name = "tone",
    controlspec = cs.new(-1, 1, "lin", 0, D.delay.tone, ""),
    action = function(v) engine.delaytone(v); params:set("dronage_revdelay_tone", v) end }
  params:add{ type = "control", id = "dronage_delay_mod", name = "wobble",
    controlspec = cs.new(0, 1, "lin", 0, D.delay.mod, ""),
    action = function(v) engine.delaymod(v); params:set("dronage_revdelay_mod", v) end }
  params:add{ type = "control", id = "dronage_delay_gran", name = "granular",
    controlspec = cs.new(-1, 1, "lin", 0, D.delay.gran, ""),
    action = function(v) engine.delaygran(v) end }
  -- delay -> reverb send (shared: drives BOTH delays); and reverse-delay wet -> forward-delay input
  params:add{ type = "control", id = "dronage_delay_rvbsend", name = "delay > rvb send",
    controlspec = cs.new(0, 1, "lin", 0, D.delay.rvbsend, ""),
    action = function(v) engine.delayrvb(v) end }
  params:add{ type = "control", id = "dronage_delay_revfwd", name = "rev > fwd send",
    controlspec = cs.new(0, 1, "lin", 0, D.delay.revfwd, ""),
    action = function(v) engine.revtofwd(v) end }

  -- reverse delay: shared with the forward delay for now (mirrored from the forward params above).
  params:add_separator("dronage_revdelay", "delay (reverse)")
  params:add{ type = "option", id = "dronage_revdelay_div", name = "time",
    options = options.labels("div"), default = D.revdelay.div,   -- "1/2"
    action = function() update_delay_times() end }
  params:add{ type = "control", id = "dronage_revdelay_fb", name = "feedback",
    controlspec = cs.new(0, 1, "lin", 0, D.revdelay.fb, ""),
    action = function(v) engine.revfb(v) end }
  params:add{ type = "control", id = "dronage_revdelay_tone", name = "tone",
    controlspec = cs.new(-1, 1, "lin", 0, D.revdelay.tone, ""),
    action = function(v) engine.revtone(v) end }
  params:add{ type = "control", id = "dronage_revdelay_mod", name = "wobble",
    controlspec = cs.new(0, 1, "lin", 0, D.revdelay.mod, ""),
    action = function(v) engine.revmod(v) end }
  -- hidden for now (driven by the forward params); kept + saved so the reverse stage can get its
  -- own UI later. Also removed from the dronage Delay view.
  for _, p in ipairs({ "div", "fb", "tone", "mod" }) do params:hide("dronage_revdelay_" .. p) end
end

-- shimmer reverb (vendored DronageGreyhole + octave PitchShift feedback), sits PRE-tape.
-- mix/shimmer default 0 -> inaudible until dialled in. The tape is still strictly end-of-chain.
local function add_reverb_params()
  params:add_separator("dronage_reverb", "reverb (shimmer)")
  -- reverb is now a per-voice SEND effect: each voice's `reverb send` feeds it; this is the global
  -- wet RETURN level into the master mix (default full - raise a voice's send to hear reverb).
  params:add{ type = "control", id = "dronage_reverb_mix", name = "return",
    controlspec = cs.new(0, 1, "lin", 0, D.reverb.mix, ""), action = function(v) engine.reverbmix(v) end }
  params:add{ type = "control", id = "dronage_reverb_shimmer", name = "shimmer",
    controlspec = cs.new(0, 0.9, "lin", 0, D.reverb.shimmer, ""), action = function(v) engine.reverbshimmer(v) end }
  params:add{ type = "control", id = "dronage_reverb_size", name = "size",
    controlspec = cs.new(0.5, 3, "lin", 0, D.reverb.size, ""), action = function(v) engine.reverbsize(v) end }
  params:add{ type = "control", id = "dronage_reverb_time", name = "time",
    controlspec = cs.new(0.1, 4, "lin", 0, D.reverb.time, "s"), action = function(v) engine.reverbtime(v) end }
  params:add{ type = "control", id = "dronage_reverb_damp", name = "damp",
    controlspec = cs.new(0, 1, "lin", 0, D.reverb.damp, ""), action = function(v) engine.reverbdamp(v) end }
  params:add{ type = "control", id = "dronage_reverb_diff", name = "diffusion",
    controlspec = cs.new(0, 1, "lin", 0, D.reverb.diff, ""), action = function(v) engine.reverbdiff(v) end }
  params:add{ type = "control", id = "dronage_reverb_fb", name = "feedback",
    controlspec = cs.new(0, 0.75, "lin", 0, D.reverb.fb, ""), action = function(v) engine.reverbfb(v) end }
  params:add{ type = "control", id = "dronage_reverb_mod", name = "mod depth",
    controlspec = cs.new(0, 1, "lin", 0, D.reverb.mod, ""), action = function(v) engine.reverbmod(v) end }
end

-- master tape stage: everything sinks here before the output (tapedeck-style, minus reverb).

-- ramp: 0 until `from`, then linearly 0..`to` as `a` goes from..1. Gates the `amount` artifacts so
-- 0..0.3 is clean tape and they only ramp in above 0.3.
local function ramp(a, from, to) return math.max(0, (a - from) / (1 - from)) * to end

local function add_tape_params()
  params:add_separator("dronage_tape", "tape (master)")
  -- AGE is the single "tape wear" macro driving every aging artifact (saturation, head loss, chew,
  -- degrade, wow/flutter, mu-law colour); the fast/harsh ones are scaled back so the knob stays
  -- musical across its range. COMPRESSION stays on its own. Input drive and output trim are
  -- dropped - they sit at the engine's neutral defaults (0 dB).
  params:add{ type = "control", id = "dronage_tape_age", name = "tape age",
    controlspec = cs.new(0, 1, "lin", 0, D.tape.age, ""), action = function(a)
      -- wow/chew/degrade gate at 0.5; loss comes in last (off until 0.75) and tops out at 0.5.
      -- 0..0.5 is clean tape, then artifacts ramp in to their ceilings by age 1.0.
      engine.tapeloss(ramp(a, 0.75, 0.5))
      engine.tapewow(ramp(a, 0.5, 0.75))
      -- chew ceiling 0.2 = what the old 1.0-ceiling gave at age 60% (user-tuned 2026-07-04:
      -- even stereo-linked, full-wet chew was too violent - now age 100% = the old 60%).
      engine.tapechew(ramp(a, 0.5, 0.2))
      -- degrade ceiling 0.5 (= the old age-75% amount): its wet path is a ~2 kHz-lowpassed,
      -- ~-12 dB copy by design, so past ~0.8 mix it swallowed the signal + highs ("the 90% cliff").
      -- Capped at half, the dry always carries the level and the top end.
      engine.tapedegrade(ramp(a, 0.5, 0.5))
      -- colour: linear from 0, but ~19x weaker than the original 0.05 slope (old 5% = new 95%).
      engine.tapecolor(a * 0.0026)
      -- hysteresis saturation rides the same knob 1:1 (was its own param): mix + depth floor.
      -- depth span widened 0.5 -> 0.6 (satamt caps 0.9 = model ceiling M_s 0.6, ~1.3 dB more
      -- squash at the top; paired with model drive 0.65 in the engine, user-tuned 2026-07-04).
      engine.tapesat(a)
      engine.tapesatamt(0.3 + (a * 0.6))
    end }
  -- looping tape-hiss bed (samples/tapehiss_loop.wav, cached in a server buffer): this is its level.
  -- The wav is hot: raw 5% was already plenty, so the knob's full 0..100% maps to raw 0..0.05.
  params:add{ type = "control", id = "dronage_tape_hiss", name = "hiss",
    controlspec = cs.new(0, 1, "lin", 0, D.tape.hiss, ""), action = function(v) engine.tapehiss(v * 0.05) end }
  params:add{ type = "control", id = "dronage_tape_compression", name = "compression",
    controlspec = cs.new(0, 1, "lin", 0, D.tape.compression, ""), action = function(v) engine.tapecomp(v) end }
  -- master volume: plain gain at the very end of the chain (post master FX). 100% = unity = how the
  -- script always sounded. Deliberately NOT saved (psets or scenes) - it's a live-room knob.
  params:add{ type = "control", id = "dronage_master_vol", name = "master volume",
    controlspec = cs.new(0, 1, "lin", 0, 1, ""), action = function(v) engine.mastervol(v) end }
  params:set_save("dronage_master_vol", false)
end

local function unified_tick(dt)
  for d = 1, #mtx.dests do mod_acc[d] = 0 end
  mtx.advance(dt, mod_beats())
  mtx.accumulate(mod_acc)
  seq.accumulate(mod_acc)
  mac.accumulate(mod_acc)
  for d = 1, #mtx.dests do
    local dest = mtx.dests[d]
    if mtx.dest_active[d] or seq.dest_active[d] or mac.dest_active[d] then
      local p = params:lookup_param(dest.param_id)
      local val = p.controlspec:map(util.clamp(p.controlspec:unmap(params:get(dest.param_id)) + mod_acc[d], 0, 1))
      if dest.cmd == "pitch" then val = quantize_pitch(val) end
      engine[dest.cmd](dest.voice, val)
      mod_result[dest.param_id] = val          -- live post-mod value for the UI
    else
      mod_result[dest.param_id] = nil
    end
  end
  -- pitch snaps to the scale as the LAST step from any source: modulated pitch dests were quantized
  -- above; send the quantized base pitch for the unmodulated voices too, so a scale/root change
  -- re-snaps them on the next tick.
  for v = 1, eng.NUM_VOICES do
    local pd = mtx.dest_index(v, "pitch")
    if not (mtx.dest_active[pd] or seq.dest_active[pd] or mac.dest_active[pd]) then
      engine.pitch(v, quantize_pitch(params:get("v" .. v .. "_pitch")))
    end
    -- tune is tuning too: when its modulation goes inactive, return to the knob's base value
    -- (never quantized - it's the deliberate post-quantizer offset).
    local td = mtx.dest_index(v, "tune")
    if not (mtx.dest_active[td] or seq.dest_active[td] or mac.dest_active[td]) then
      engine.tune(v, params:get("v" .. v .. "_tune"))
    end
  end
  -- delay tempo-sync: resend the delay length when the transport tempo changes
  local bpm = clock.get_tempo()
  if bpm ~= last_bpm then last_bpm = bpm; pcall(update_delay_times) end
end

function init()
  -- First run: copy bundled UGen .so out to Extensions, then ask the user to restart (scsynth only
  -- scans Extensions at boot). Engine isn't declared this run, so we skip all engine-dependent setup.
  if not install.is_installed() then
    install_ok = install.install()
    needs_install = true
    redraw()
    return
  end

  -- dronage has its own reverb + tape glue comp, so silence the norns system reverb and compressor
  -- (the AUDIO menu ones) by default - the user can re-enable them in SYSTEM if they want.
  audio.rev_off()
  audio.comp_off()

  params:add_separator("dronage_transport_sep", "transport")
  params:add{ type = "binary", id = "dronage_transport", name = "transport (play/stop)",
    behavior = "toggle", default = D.transport, action = function(v) set_transport(v == 1) end }   -- plays on boot
  eng.quantize = quantize_pitch   -- scale-snap the base pitch as the final step before the engine
  eng.add_params()
  mtx.init(eng.NUM_VOICES)
  mtx.add_params()
  scales.add_params()
  add_delay_params()
  add_reverb_params()
  add_tape_params()
  seq.init(mtx.dest_index)
  euclid.add_params(eng.NUM_VOICES)
  mac.init(mtx.dest_index)
  mac.add_params()
  scenes.init(mtx, seq, mac)
  scenes.add_pset_hooks()
  scr.init({
    eng = eng, mtx = mtx, seq = seq, mac = mac, scenes = scenes, euclid = euclid, scales = scales,
    NOTE = NOTE,
    get_amp = function() return ui_amp end,
    transport = function() return transport end,
    set_transport = set_transport,
    project = project, project_new = project_new,
    mod_result = mod_result,   -- live post-mod values for the real-time value + +/- display
  })
  pcall(grd.init, seq, mtx)   -- optional grid 128 (safe no-op without one)
  -- splash: one of 3 bayer4x4-dithered art frames, shown until the first knob/button (consumed)
  math.randomseed(os.time())
  local ok, img = pcall(screen.load_png, norns.state.path .. "images/dronage" .. math.random(1, 3) .. ".png")
  if ok and img then splash = img end
  math.randomseed(os.time())
  params:set("dronage_seed", math.random(0, 4095))   -- fresh-start surprise; PSET load overrides
  params:set("clock_tempo", D.global.tempo)           -- enforce our default tempo on boot (PSET/scene overrides)
  params:bang()
  scenes.store_current()    -- baseline scene 1

  mod_clock = clock.run(function()
    local dt = 1 / mtx.tick_hz
    while true do clock.sleep(dt); pcall(unified_tick, dt); screen_dirty = true end
  end)
  seq_clock = clock.run(function()
    while true do
      clock.sync(1 / seq.steps_per_beat)
      if transport then pcall(seq.advance, mod_beats()) end
    end
  end)
  -- euclidean: fine grid (1/48 beat resolves binary + triplet step rates) so floor-detection never
  -- skips a step; only steps while PLAYing, off the transport-relative beat.
  -- before any euclid trigger fires, flush a mod tick (dt=0: recompute + resend, no phase advance)
  -- so the S&H value landing on this beat reaches the engine first; the synth then samples it at
  -- the (4ms-delayed) trigger. dronage-tui ordering.
  euclid.pre_trig = function() pcall(unified_tick, 0) end
  euclid_clock = clock.run(function()
    while true do
      clock.sync(1 / 48)
      if transport then pcall(euclid.advance, mod_beats()) end
    end
  end)
  redraw_metro = metro.init()
  redraw_metro.event = function()
    redraw()           -- always redraw (live LFO scopes/meters change every frame)
    pcall(grd.redraw)
  end
  redraw_metro:start(1 / 30)   -- 30 fps: smooth scopes/spectrogram, half the draw cost of 60

  amp_poll = poll.set("amp_out_l", function(v) ui_amp = v; screen_dirty = true end)
  amp_poll.time = 1 / 20
  amp_poll:start()

  -- async update check (lib/dronage_norns_update.lua): the overlay appears a moment after
  -- boot ONLY for clean git installs that are online and behind; everything else is silent.
  update.check()
end

-- ---------- UI: grid screens (lib/dronage_norns_screens) ----------
-- NEW project: reset every param to the centralized defaults, restore the default tempo, forget all
-- scenes. (Save/Load/Delete/naming live in the PROJECT browser via the `project` module + textentry.)
project_new = function()
  params:default()
  params:set("clock_tempo", D.global.tempo)
  scenes.clear_all()
  project.current = nil
end

-- K3 on the install screen: restart the audio stack OURSELVES, including jackd. SYSTEM > RESTART
-- only cycles sclang/crone/matron (not jackd), which can leave jack's semaphore registry corrupted
-- and hang at "restarting." - restarting jackd too replaces the corrupted registry, clean every time.
-- systemd-run runs the sequence in its own scope so it survives matron being restarted mid-way.
local function finish_install()
  if restarting then return end
  restarting = true
  redraw()   -- paint "restarting..." before the services go down
  os.execute("sudo systemd-run --no-block --collect bash -c '"
    .. "systemctl restart norns-jack.service; sleep 3; "
    .. "systemctl restart norns-sclang.service norns-crone.service norns-matron.service' >/dev/null 2>&1")
end

function redraw()
  if norns.menu.status() then return end   -- a norns overlay (textentry / system menu) owns the screen
  if needs_install then
    screen.clear(); screen.aa(0)
    screen.level(15); screen.move(64, 20); screen.text_center("dronage-norns")
    if restarting then
      screen.level(15); screen.move(64, 40); screen.text_center("restarting...")
    elseif install_ok then
      screen.level(15); screen.move(64, 36); screen.text_center("audio engine installed")
      screen.level(8);  screen.move(64, 48); screen.text_center("K3 = Finish and restart")
    else
      screen.level(15); screen.move(64, 36); screen.text_center("install failed")
      screen.level(3);  screen.move(64, 48); screen.text_center("UGen bundle missing")
    end
    screen.update()
    return
  end
  if update.state then   -- update overlay outranks splash + normal UI (install screen still wins)
    screen.clear(); screen.aa(0)
    screen.level(15); screen.move(64, 16); screen.text_center("dronage-norns")
    if update.state == "offer" then
      screen.level(15); screen.move(64, 31); screen.text_center("UPDATE AVAILABLE")
      if update.subject ~= "" then
        screen.level(5); screen.move(64, 42); screen.text_center(string.sub(update.subject, 1, 24))
      end
      screen.level(8); screen.move(64, 56); screen.text_center("K2 = later   K3 = update")
    elseif update.state == "pulling" then
      screen.level(15); screen.move(64, 38); screen.text_center("updating...")
    else   -- "failed"
      screen.level(15); screen.move(64, 34); screen.text_center("update failed")
      screen.level(8); screen.move(64, 50); screen.text_center("K3 = continue")
    end
    screen.update()
    return
  end
  if splash then
    screen.clear(); screen.display_image(splash, 0, 0); screen.update()
    return
  end
  scr.redraw()
end

function enc(n, d)
  if needs_install then return end
  if update.state then return end   -- update overlay owns the input
  if splash then splash = nil; screen_dirty = true; return end   -- dismiss only; do nothing else
  scr.enc(n, d); screen_dirty = true
end

function key(n, z)
  if needs_install then
    if install_ok and n == 3 and z == 1 then finish_install() end   -- K3 = finish + restart (incl jackd)
    return
  end
  if update.state then
    if update.state == "offer" then
      if n == 2 and z == 1 then update.dismiss(); screen_dirty = true end   -- later (asks again next boot)
      if n == 3 and z == 1 then
        update.pull(function(ok)
          -- success -> reload ourselves into the new version; if the update changed engine
          -- binaries, the reload trips the installer hash gate and its restart screen takes over.
          if ok then norns.script.load(norns.state.script) end
        end)
      end
    elseif update.state == "failed" then
      if n == 3 and z == 1 then update.dismiss(); screen_dirty = true end
    end
    return
  end
  if splash then if z == 1 then splash = nil; screen_dirty = true end; return end  -- dismiss only
  scr.key(n, z); screen_dirty = true
end
function cleanup()
  if amp_poll then amp_poll:stop() end
  if redraw_metro then redraw_metro:stop() end
  if mod_clock then clock.cancel(mod_clock) end
  if seq_clock then clock.cancel(seq_clock) end
  if euclid_clock then clock.cancel(euclid_clock) end
end
