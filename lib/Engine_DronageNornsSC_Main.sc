// Engine_DronageNornsSC_Main.sc
// dronage-norns - 4 fixed MiPlaits drone voices (MVP).
//
// Requires the mi-UGens SuperCollider plugins (MiPlaits) installed on the norns
// (~/.local/share/SuperCollider/Extensions/). emplaitress depends on the same.
//
// NAMING (load-bearing - do not relax): norns compiles EVERY .sc under ~/dust into
// ONE global class library at boot; a duplicate class name OR SynthDef name fails the
// whole compile and bricks audio for EVERY script. So the class is uniquely prefixed
// (Engine_DronageNornsSC_Main, filename == class name) and every SynthDef symbol is
// \dronageNornsSC_*. Per-voice control comes via 1-based voice index from Lua.

Engine_DronageNornsSC_Main : CroneEngine {
	classvar numVoices = 4;

	var voices, voiceGroup, fxGroup, dlySendBus, revSendBus, rvbSendBus, delaySynth, revSynth;
	var mixBus, reverbSynth, tapeSynth, wobbleBuf, compressBuf, expandBuf, hissBuf;
	var specForwarder, matronAddr;   // forward the master-out spectrum SendReply to matron for the HOME viz
	var scopeBuf, scopeRoutine;      // circular master-out L/R window, polled to matron for the vectorscope

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		// All voices live in one group at the engine's processing group (context.xg).
		voiceGroup = Group.new(context.xg);
		dlySendBus = Bus.audio(context.server, 1);  // mono forward-delay send
		revSendBus = Bus.audio(context.server, 1);  // mono reverse-delay send
		rvbSendBus = Bus.audio(context.server, 1);  // mono reverb send (per-voice)
		mixBus = Bus.audio(context.server, 2);      // master pre-tape mix (everything sinks here)
		// tape: mu-law compand wavetables (tapedeck "color") + wow/flutter buffer
		wobbleBuf = Buffer.alloc(context.server, 48000, 2);
		// looping tape-hiss bed, cached in RAM (stereo 48k wav). Missing file -> tiny silent buffer,
		// so the tape synth still builds and the HISS knob is just a no-op.
		hissBuf = if (File.exists("/home/we/dust/code/dronage-norns/samples/tapehiss_loop.wav"),
			{ Buffer.read(context.server, "/home/we/dust/code/dronage-norns/samples/tapehiss_loop.wav") },
			{ Buffer.alloc(context.server, 48, 2) });
		scopeBuf = Buffer.alloc(context.server, 256, 2);   // last 256 master-out L/R frames (vectorscope window)
		{
			var nn = 1024, mu = 510;
			var unit = Array.fill(nn, { |i| i.linlin(0, nn - 1, -1, 1) });
			var comp = unit.collect({ |x| x.sign * log(1 + (mu * x.abs)) / log(1 + mu) });
			var expd = unit.collect({ |y| (y.sign / mu) * (((1 + mu) ** y.abs) - 1) });
			compressBuf = Buffer.loadCollection(context.server, Signal.newFrom(comp).asWavetableNoWrap);
			expandBuf   = Buffer.loadCollection(context.server, Signal.newFrom(expd).asWavetableNoWrap);
		}.value;

		// One Plaits drone voice. trigger stays 0; `level` holds the internal low-pass
		// gate open so the voice sustains continuously. Continuous params are Lag'd so
		// sweeps from Lua (and, later, the mod matrix) don't zipper. `engine` (the model
		// selector) is an integer and is NOT lagged (no interpolation between models).
		SynthDef(\dronageNornsSC_voice, {
			arg out = 0, gate = 1, attack = 4, decay = 4,
				t_trig = 0, seqMode = 0, lpgDecay = 0.3,
				pitch = 48, tune = 0, engine = 0,
				harm = 0.5, timbre = 0.5, morph = 0.5,
				level = 0.5, pan = 0.0,
				lpgColour = 0.5, outMode = 0,
				cut = 8000, res = 0.15, hpCut = 30, hpQ = 0.1,
				drive = 0.0, chorus = 0.0,
				dlySend = 0.0, dlyBus = 0, revBus = 0,
				reverbSend = 0.0, rvbBus = 0,
				lag = 0.1;
			var sig, env, pluck, lpgLvl, lpgCol, l, r, g, oL, oR, selfEnv, plaitsTrig, selfVca, seqRaw, trig, pitchSeq;
			seqRaw = seqMode;                    // pre-Lag 0/1 copy - switches the pitch path below
trig   = TDelay.kr(t_trig, 0.004);   // dronage-tui: the audible trigger fires ~4ms after the step,
			                                     // so the freshly-sent mod/pitch values land first
			// pitch: DRONE glides (the long Lag = portamento feature). SEQ samples-and-holds like dronage-tui:
			// TRACK the incoming (already-quantized) pitch for 33ms after each hit (covers the Lua mod tick
			// landing late, tui's "multi-sample capture"), then HOLD it until the next hit - no more gliding
			// into S&H notes. 3ms de-zipper. tune stays continuous on purpose (the vinyl-drift knob).
			pitchSeq = Lag.kr(Gate.kr(pitch, Trig.kr(t_trig + Impulse.kr(0), 0.033)), 0.003);
			pitch    = Select.kr(seqRaw, [Lag.kr(pitch, 0.015), pitchSeq]) + Lag.kr(tune, 0.015);
			// ^ drone pitch + tune: 15ms = just enough to de-zipper the 60Hz mod tick, NOT portamento.
			//   Glide, when wanted, is the LFO Smooth param's job - no bespoke invisible glide here.
			harm      = Lag.kr(harm, lag);
			timbre    = Lag.kr(timbre, lag);
			morph     = Lag.kr(morph, lag);
			level     = Lag.kr(level, lag);
			pan       = Lag.kr(pan, lag);
			lpgColour = Lag.kr(lpgColour, lag);
			lpgDecay  = Lag.kr(lpgDecay, lag);
			seqMode   = Lag.kr(seqMode, 0.05);   // smooth drone<->step morph

			// LPG drive (gate-vs-ping handled here, not in C++): in DRONE (seqMode=0) the Plaits LPG
			// gets a steady `level` and lpg_colour is forced to 1 -> hf_bleed=1 -> transparent, so the
			// LPG colour + decay knobs are no-ops. In STEP (seqMode=1) `level` is pinged per t_trig (the
			// vactrol follows it = the pluck) and lpg_colour = 1 - knob (dronage-move direction: knob up
			// -> more filtering, and the C++ couples resonance to that). lpgDecay = the LPG ring time.
			pluck  = EnvGen.kr(Env.perc(0.003, lpgDecay), trig);
			lpgLvl = level * ((1 - seqMode) + (seqMode * pluck));
			lpgCol = 1 - (seqMode * lpgColour);

			// Self-enveloped engines (string/modal/drums 11-15, 6-op FM banks 18-20) bypass the LPG, so the
			// level-ping can't articulate them - they need Plaits' own trigger. Feed a RELEASED gate: its
			// rising edge advances the engine's OWN round-robin + attacks, then it drops after ~Decay so
			// each note decays and rings on its voice and consecutive notes overlap - natural round-robin/
			// polyphony (a single amp envelope over the pool forced monophonic cutting = the squelch).
			// Held HIGH in drone to sustain. 0 elsewhere, so LPG engines keep their level->LPG pluck.
			selfEnv    = ((engine >= 11) * (engine <= 15)) + ((engine >= 18) * (engine <= 20)) + ((engine >= 24) * (engine <= 25));
			// chiptune (23) is LPG-enveloped (not self-enveloped), but it STILL needs Plaits' rising edge
			// to clock its arp - HARMONICS (chord) + TIMBRE (arp pattern) latch on the edge, so with no
			// trigger the arp freezes and both knobs look dead. Add a clean per-hit impulse for it in SEQ.
			// dip: gate forced LOW for 3ms at each incoming hit (tui's force_gate_low) so consecutive hits
			// closer than LPG Decay still hand Plaits a rising edge - string/modal round-robin + 6-op FM
			// re-articulate instead of silently swallowing notes. The delayed trigger then re-opens it.
			plaitsTrig = (selfEnv * ((1 - seqMode) + (seqMode * (Trig.kr(trig, lpgDecay.max(0.005)) * (1 - Trig.kr(t_trig, 0.003)))))) + (((engine >= 23) * (engine <= 23)) * seqMode * trig);
			// LPG Decay ALSO as a secondary amplitude decay on their output - a clean amp taper on top of
			// the engine's own DX/model envelope + MORPH. One VCA over the pool: short Decay = plucky/
			// separate, long Decay = notes still ring. 1 for LPG engines (they decay via their LPG) + drone.
			selfVca = (selfEnv * seqMode * pluck) + (1 - (selfEnv * seqMode));

			// Our vendored, namespaced build of Plaits (DronageMacrosynth.so). LPG engines are level-
			// patched (internal LPG follows lpgLvl; colour drives filtering+resonance). Self-enveloped
			// engines instead take the plaitsTrig gate above and run their own DX / physical envelope.
			sig = DronageMacrosynth.ar(
				pitch: pitch, engine: engine,
				harm: harm, timbre: timbre, morph: morph,
				trigger: plaitsTrig, level: lpgLvl,
				decay: lpgDecay, lpg_colour: lpgCol,
				drone: (1 - seqMode)   // reference parity: drone -> trigger_patched=false (free-run/patch-load)
			);
			// OUT routing (dronage-tui parity), ALWAYS-STEREO from here -> sig = [L, R]. outMode 0-4:
			// MIX/OUT/AUX put the SAME signal on L+R (centred mono); STEREO=out->L/aux->R; INV=aux->L/out->R.
			sig = [ Select.ar(outMode, [(sig[0] + sig[1]) * 0.5, sig[0], sig[1], sig[0], sig[1]]),   // L
				        Select.ar(outMode, [(sig[0] + sig[1]) * 0.5, sig[0], sig[1], sig[1], sig[0]]) ]; // R: STEREO out->L/aux->R, INV swaps
			// (self-enveloped amp decay = selfVca is applied POST-filter, folded into `g` below. Applying
			// it here, pre-MoogFF, fed exact 0.0 into the resonant ladder/SVF between hits and drove their
			// empty recursive state into denormals = the "squelch for the first few hits then clean".)

			// Per-voice filters, faithful to dronage's chain: Plaits -> Moog 4-pole ladder LP
			// -> 2-pole SVF HP. MoogFF `gain` IS the resonance (0..4, self-osc near 4 -> clip
			// below). The SVF HP doubles as a DC blocker for anything the ladder adds.
			// cut/res are mod-matrix destinations (drive stage comes later, with the cab sim).
			sig = MoogFF.ar(sig, Lag.kr(cut, lag).clip(20, 18000), (Lag.kr(res, lag) * 3.96).clip(0, 3.96), 0);
			// Bipolar amp-sim (custom UGen): drive<0 Doom fuzz, >0 Marshall tube, 0 bypass.
			// Smooths drive internally, so pass it raw. Sits between LP and HP (dronage order).
			sig = DronageBipolarDist.ar(sig, drive.clip(-1, 1));
			sig = SVF.ar(sig, Lag.kr(hpCut, lag).clip(20, 4000), Lag.kr(hpQ, lag).clip(0, 1), 0, 0, 1, 0, 0);

			// Gate AHD as a persistent linear slew (faithful to dronage-tui's "fake AD"): env walks
			// toward 1 while gate is on (attack rate) and toward 0 while off (decay rate), always
			// continuing from its CURRENT value - so toggling mid-ramp just reverses direction, no
			// click, no reset. Slew clamps at 1 (= Hold) / 0 (= Idle); node stays alive.
			env = Slew.kr(gate, 1 / attack.max(0.001), 1 / decay.max(0.001));

			// The per-step pluck is now done INSIDE Plaits' LPG (via lpgLvl above), so the VCA is just
			// the slow gate-AHD swell × level (single voice level, dronage-tui model: level feeds
			// both the LPG and the VCA).
			g = level * env * selfVca;  // × self-enveloped decay, POST-filter (filters never see the zero cut)
			// Bipolar stereo chorus (custom UGen): stereo [L,R] -> [L,R]. <0 warm, >0 spacey, 0 bypass.
			// Replaces Pan2 - the chorus does the stereo-ization (dronage chain: chorus -> VCA -> pan).
			# l, r = DronageChorus.ar(sig[0], sig[1], chorus.clip(-1, 1));   // stereo-in: L/R -> chorused L/R
			// VCA + dronage balance-pan (attenuate the opposite channel). Out.ar sums the 4 voices.
			oL = l * g * (1 - pan.max(0));
			oR = r * g * (1 + pan.min(0));
			Out.ar(out, [oL, oR]);
			// per-voice bipolar DLY send: positive -> forward delay, negative -> reverse delay.
			Out.ar(dlyBus, (oL + oR) * 0.5 * dlySend.max(0));
			Out.ar(revBus, (oL + oR) * 0.5 * dlySend.neg.max(0));
			// per-voice unipolar reverb send (mono) -> the shimmer reverb reads this bus
			Out.ar(rvbBus, (oL + oR) * 0.5 * reverbSend.clip(0, 1));
		}).add;

		// Shared forward delay (signature granular delay UGen). Reads the summed send bus,
		// adds wet to the master in parallel, then clears the bus for the next block.
		SynthDef(\dronageNornsSC_delay, {
			arg out = 0, dlyBus = 0, rvbBus = 0,
				delaySamps = 24000, feedback = 0.5, tone = 0.0, mod = 0.0, granular = 0.0, delayToReverb = 0.0;
			var snd, wet;
			snd = In.ar(dlyBus, 1);
			wet = DronageGranularDelay.ar(snd, delaySamps, feedback.clip(0, 1),
				tone.clip(-1, 1), mod.clip(0, 1), granular.clip(-1, 1));
			Out.ar(out, wet);
			Out.ar(rvbBus, (wet[0] + wet[1]) * 0.5 * delayToReverb.clip(0, 1));   // Delay > Rvb send
			ReplaceOut.ar(dlyBus, Silent.ar(1));
		}).add;

		// Shared reverse delay (own division). Negative DLY send routes here.
		SynthDef(\dronageNornsSC_revdelay, {
			arg out = 0, revBus = 0, rvbBus = 0, dlyBus = 0,
				delaySamps = 24000, feedback = 0.5, tone = 0.0, mod = 0.0, granular = 0.0, delayToReverb = 0.0, revToFwd = 0.0;
			var snd, wet;
			snd = In.ar(revBus, 1);
			wet = DronageReverseDelay.ar(snd, delaySamps, feedback.clip(0, 1),
				tone.clip(-1, 1), mod.clip(0, 1), granular.clip(-1, 1));
			Out.ar(out, wet);
			Out.ar(rvbBus, (wet[0] + wet[1]) * 0.5 * delayToReverb.clip(0, 1));   // Delay > Rvb send
			Out.ar(dlyBus, (wet[0] + wet[1]) * 0.5 * revToFwd.clip(0, 1));        // Rev > Fwd: reverse wet -> forward input
			ReplaceOut.ar(revBus, Silent.ar(1));
		}).add;

		// Master TAPE stage (portable tapedeck chain, minus reverb). Everything (voices + both
		// Shimmer reverb (our vendored DronageGreyhole + octave-up PitchShift feedback), PRE-tape.
		// Reads the mix (dry + delays), adds reverb wet back into the mix. The shimmer loop pitches the
		// reverb tail up an octave each pass (LocalIn/LocalOut) for the rising-shimmer wash. Tape stays
		// strictly end-of-chain (post-reverb). mix/shimmer default 0 -> inaudible until dialled in.
		SynthDef(\dronageNornsSC_reverb, {
			arg rvbBus = 0, mixBus = 0, size = 2.0, time = 2.0, damp = 0.3, diff = 0.7, feedback = 0.85,
				mod = 0.1, shimmer = 0.0, mix = 1.0, lag = 0.1;
			var send, wet, shifted, fb, fbk;
			send = In.ar(rvbBus, 1);                               // per-voice reverb sends (mono)
			fb   = LocalIn.ar(2);
			// shimmer = octave-up PitchShift in the feedback loop; at 0 it's a plain reverb.
			wet = DronageGreyhole.ar(send + fb,
				delayTime: Lag.kr(time, lag), damp: Lag.kr(damp, lag), size: Lag.kr(size, lag),
				diff: Lag.kr(diff, lag), feedback: Lag.kr(feedback, lag),
				modDepth: Lag.kr(mod, lag), modFreq: 2.0);
			// Sanitize Greyhole's output at the SOURCE so both the shimmer loop and the mix get a
			// clean signal: DC-block, hard-clip its transition transients, zap NaN/inf. (Greyhole's
			// raw feedback can throw huge spikes on param changes; without this they reach the tape.)
			wet = LeakDC.ar(wet).clip2(4);
			wet = wet.collect { |ch| Select.ar(CheckBadValues.ar(ch, 0, 0), [ch, DC.ar(0), DC.ar(0), ch]) };
			shifted = PitchShift.ar(wet, 0.2, 2.0, 0.01, 0.05);     // +1 octave
			// Shimmer feedback conditioning - matches dronage-tui (src/modules/reverb.rs), which keeps
			// this loop stable: scale 0.5, -12 dB peak limiter, band-limit HPF 100 / LPF 6 kHz, clamp.
			// The 6 kHz LPF is the key - each pass pushes energy up an octave; bleeding the highs stops
			// the rising shimmer from accumulating into a runaway screech. (Greyhole's own `feedback`
			// is the second loop the tui doesn't have, so we also keep that param sane, capped < 1.)
			// CheckBadValues zaps any NaN/inf to 0 so a blow-up self-heals instead of latching silence.
			fbk = shifted * (Lag.kr(shimmer, lag).clip(0, 1) * 0.5);
			fbk = Limiter.ar(fbk, 0.25);
			fbk = LPF.ar(HPF.ar(fbk, 100), 6000).clip2(1.0);
			fbk = fbk.collect { |ch| Select.ar(CheckBadValues.ar(ch, 0, 0), [ch, DC.ar(0), DC.ar(0), ch]) };
			LocalOut.ar(fbk);
			Out.ar(mixBus, Limiter.ar(wet, 0.95) * Lag.kr(mix, lag).clip(0, 1));  // protect master/tape
			ReplaceOut.ar(rvbBus, Silent.ar(1));                    // clear the per-voice send bus
		}).add;

		// delays) sinks into mixBus; this reads it, "records to tape", and writes the hardware out.
		SynthDef(\dronageNornsSC_tape, {
			arg out = 0, mixBus = 0, wobbleBuf, compressBuf, scopeBuf,
				drive = 0, sat = 0.25, satamt = 0.5, color = 0.3, wow = 0.15, comp = 0.3, db = 0,
				loss = 0, chew = 0, degrade = 0, hiss = 0, mastervol = 1, hissBuf = 0;
			var snd, pw, pr, wobbled, rate;
			snd = In.ar(mixBus, 2);
			snd = (snd * drive.dbamp).clip2(8);                             // input drive (dB), guarded:
			// clip2(8) keeps the stateful AnalogTape hysteresis out of its divergence region (a NaN there
			// would latch in its internal state). 2x headroom over max realistic drive, so transparent.
			// REAL ChowDSP tape saturation (hysteresis model), wet/dry by `sat`. The hysteresis softens
			// highs as it saturates (real tape); a high shelf @ 5 kHz on the wet branch restores air.
			// The shelf SCALES with satamt - the harder it saturates (darker), the more treble back:
			// satamt 0.3..0.8 (knob 0..1) -> shelf +2..+6 dB.
			snd = SelectX.ar(sat.clip(0, 1), [snd,
				BHiShelf.ar(DronageAnalogTape.ar(snd, 0.5, satamt.clip(0, 1), 0.55, 1, 0), 5000, 1,
					Lag.kr(satamt.clip(0, 1), 0.1).linlin(0.3, 0.8, 2, 6))]);
			// tape aging - opt-in (default 0): head-gap HF loss / chew dropouts / degrade noise
			snd = SelectX.ar(loss.clip(0, 1),    [snd, DronageAnalogLoss.ar(snd, 0.5, 0.5, 0.5, 1)]);
			snd = SelectX.ar(chew.clip(0, 1),    [snd, DronageAnalogChew.ar(snd, 0.5, 0.5, 0.5)]);
			snd = SelectX.ar(degrade.clip(0, 1), [snd, DronageAnalogDegrade.ar(snd, 0.5, 0.5, 0.5, 0.5)]);
			// mu-law compand "color" (tapedeck), wet/dry by `color`
			snd = SelectX.ar(color.clip(0, 1), [snd, Shaper.ar(compressBuf, snd.clip2(0.999))]);
			// wow & flutter (Stefaan Himpe via tapedeck), reworked: real tape wobbles the WHOLE signal -
			// no dry/wet mix (the old 200ms-late wet crossfade read as a slapback echo from Tape Age ~50%).
			// `wow` scales the speed modulation instead; the read head trails the writer by a fixed 10ms
			// (max wobble drift ~±1.5ms, so it can never overrun). Costs a constant, inaudible 10ms.
			rate = 1 + (Lag.kr(wow.clip(0, 1), 0.1) * (0.05 * SinOsc.kr(33/60, mul: 0.1) + 0.03 * SinOsc.kr(6 + LFNoise2.kr(2), mul: 0.02)));
			pw = Phasor.ar(0, BufRateScale.ir(wobbleBuf), 0, BufFrames.ir(wobbleBuf));
			pr = DelayL.ar(Phasor.ar(0, BufRateScale.ir(wobbleBuf) * rate, 0, BufFrames.ir(wobbleBuf)), 0.01, 0.01);
			BufWr.ar(snd, wobbleBuf, pw);
			snd = BufRd.ar(2, wobbleBuf, pr, interpolation: 4);
			// tape-hiss bed: seamless stereo loop, level = the HISS knob. After the aging stages and
			// BEFORE the glue compression (so the hiss pumps with the mix like real tape).
			snd = snd + (PlayBuf.ar(2, hissBuf, BufRateScale.kr(hissBuf), loop: 1) * Lag.kr(hiss.clip(0, 1), 0.1));
			// tape glue compression, wet/dry by `comp`. Low threshold so it engages on the (quiet,
			// steady) drone signal, ~5:1 above it, slow-ish release for audible pump, then makeup gain
			// to bring the glued body up. Net = clearly denser + louder, not just shaved peaks.
			snd = SelectX.ar(comp.clip(0, 1), [snd,
				Compander.ar(snd, snd, thresh: 0.08, slopeBelow: 1, slopeAbove: 0.2, clampTime: 0.008, relaxTime: 0.18) * 2.8]);
			// final: collapse bass to mono, tanh brickwall, output trim (tapedeck "final")
			snd = BHiPass.ar(snd, 200) + Pan2.ar(BLowPass.ar(snd[0] + snd[1], 200));
			snd = snd.tanh * db.dbamp;
			snd = snd * Lag.kr(mastervol.clip(0, 1), 0.05);   // master volume: the very last gain
			// master safety net: zap any NaN/inf and hard-clip so the hardware out can never get a
			// runaway value (protects ears/speakers regardless of what any stage upstream does).
			snd = snd.collect { |ch| Select.ar(CheckBadValues.ar(ch, 0, 0), [ch, DC.ar(0), DC.ar(0), ch]) };
			Out.ar(out, snd.clip2(1.0));
			// HOME visualizer: 40 log-spaced band powers of the master out, streamed to Lua (~40 Hz ->
			// 25 ms/column ~= the 1024-sample FFT window, so near-contiguous; 128 cols = 3.2 s waterfall).
			SendReply.kr(Impulse.kr(40), '/dr_spec',
				FFTSubbandPower.kr(FFT(LocalBuf(1024), (snd[0] + snd[1]) * 0.5),
					Array.geom(39, 50, (14000/50) ** (1/38)), 1, 1));
			// vectorscope: keep the last 256 master-out L/R frames in a circular buffer (sclang polls it)
			BufWr.ar([snd[0], snd[1]], scopeBuf, Phasor.ar(0, 1, 0, BufFrames.ir(scopeBuf)));
			ReplaceOut.ar(mixBus, Silent.ar(2));    // clear the mix bus for next block
		}).add;

		context.server.sync; // ensure the SynthDef is registered before instantiating

		voices = Array.fill(numVoices, { arg i;
			Synth(\dronageNornsSC_voice, [
				\out, mixBus.index, \pitch, 48, \engine, 0,
				\dlyBus, dlySendBus.index, \revBus, revSendBus.index, \rvbBus, rvbSendBus.index
			], target: voiceGroup);
		});

		// FX runs AFTER the voices: delays read the sends + write wet into the mix; the tape stage
		// (tail) reads the whole mix and records it to the hardware out.
		fxGroup = Group.new(voiceGroup, \addAfter);
		delaySynth = Synth(\dronageNornsSC_delay, [
			\out, mixBus.index, \dlyBus, dlySendBus.index, \rvbBus, rvbSendBus.index
		], target: fxGroup);
		revSynth = Synth(\dronageNornsSC_revdelay, [
			\out, mixBus.index, \revBus, revSendBus.index, \rvbBus, rvbSendBus.index, \dlyBus, dlySendBus.index
		], target: fxGroup);
		// reverb runs after the delays (reverbs dry+delays), before the tape (Synth.tail order)
		reverbSynth = Synth.tail(fxGroup, \dronageNornsSC_reverb, [\rvbBus, rvbSendBus.index, \mixBus, mixBus.index]);
		tapeSynth = Synth.tail(fxGroup, \dronageNornsSC_tape, [
			\out, context.out_b, \mixBus, mixBus.index,
			\wobbleBuf, wobbleBuf, \compressBuf, compressBuf, \scopeBuf, scopeBuf, \hissBuf, hissBuf
		]);

		// forward the tape SynthDef's spectrum SendReply (lands here in sclang) to matron's OSC-in (the
		// Lua UI listens via osc.event) - the data path for the HOME visualizers.
		matronAddr = NetAddr("127.0.0.1", 10111);
		specForwarder = OSCFunc({ |msg| matronAddr.sendMsg('/dr_spec', *(msg[3..])) }, '/dr_spec');
		// poll the scope buffer ~30 Hz, forward the 256 interleaved L/R frames to matron (vectorscope)
		scopeRoutine = Routine({
			loop { scopeBuf.getn(0, 512, { |d| matronAddr.sendMsg('/dr_scope', *d) }); 0.033.wait; }
		}).play(AppClock);

		this.addCommands;
	}

	// Lua sends 1-based voice indices; convert to 0-based and guard the range.
	setVoice { arg msg, key;
		var idx = msg[1].asInteger - 1;
		if(idx >= 0 and: { idx < numVoices }, { voices[idx].set(key, msg[2]); });
	}

	addCommands {
		// Per-voice continuous params: "if" = (int voice 1-4, float value)
		this.addCommand(\pitch,     "if", { arg msg; this.setVoice(msg, \pitch); });
		this.addCommand(\tune,      "if", { arg msg; this.setVoice(msg, \tune); });
		this.addCommand(\harm,      "if", { arg msg; this.setVoice(msg, \harm); });
		this.addCommand(\timbre,    "if", { arg msg; this.setVoice(msg, \timbre); });
		this.addCommand(\morph,     "if", { arg msg; this.setVoice(msg, \morph); });
		this.addCommand(\level,     "if", { arg msg; this.setVoice(msg, \level); });
		this.addCommand(\pan,       "if", { arg msg; this.setVoice(msg, \pan); });
		this.addCommand(\lpgColour, "if", { arg msg; this.setVoice(msg, \lpgColour); });
		this.addCommand(\lag,       "if", { arg msg; this.setVoice(msg, \lag); });
		this.addCommand(\gate,      "if", { arg msg; this.setVoice(msg, \gate); });
		this.addCommand(\attack,    "if", { arg msg; this.setVoice(msg, \attack); });
		this.addCommand(\decay,     "if", { arg msg; this.setVoice(msg, \decay); });

		// euclidean sequencer: per-step trigger (momentary) + mode + pluck shape
		this.addCommand(\trig, "i", { arg msg;
			var idx = msg[1].asInteger - 1;
			if(idx >= 0 and: { idx < numVoices }, { voices[idx].set(\t_trig, 1); });
		});
		this.addCommand(\seqmode, "if", { arg msg; this.setVoice(msg, \seqMode); });
		this.addCommand(\lpgdecay, "if", { arg msg; this.setVoice(msg, \lpgDecay); });

		// Per-voice filter params: "if" = (int voice 1-4, float value)
		this.addCommand(\cut,   "if", { arg msg; this.setVoice(msg, \cut); });
		this.addCommand(\res,   "if", { arg msg; this.setVoice(msg, \res); });
		this.addCommand(\hpcut, "if", { arg msg; this.setVoice(msg, \hpCut); });
		this.addCommand(\hpq,   "if", { arg msg; this.setVoice(msg, \hpQ); });
		this.addCommand(\drive, "if", { arg msg; this.setVoice(msg, \drive); });
		this.addCommand(\chorus, "if", { arg msg; this.setVoice(msg, \chorus); });
		this.addCommand(\dlysend, "if", { arg msg; this.setVoice(msg, \dlySend); });
		this.addCommand(\reverbsend, "if", { arg msg; this.setVoice(msg, \reverbSend); });
		this.addCommand(\outmode, "if", { arg msg; this.setVoice(msg, \outMode); });

		// Global (shared) forward-delay params -> the one delay synth. "f" = single float.
		this.addCommand(\delaytime, "f", { arg msg; delaySynth.set(\delaySamps, msg[1]); });
		this.addCommand(\delayfb,   "f", { arg msg; delaySynth.set(\feedback, msg[1]); });
		this.addCommand(\delaytone, "f", { arg msg; delaySynth.set(\tone, msg[1]); });
		this.addCommand(\delaymod,  "f", { arg msg; delaySynth.set(\mod, msg[1]); });
		this.addCommand(\delaygran, "f", { arg msg; delaySynth.set(\granular, msg[1]); revSynth.set(\granular, msg[1]); });
			// shared delay -> reverb send (both delays); reverse-delay wet -> forward-delay input
			this.addCommand(\delayrvb,  "f", { arg msg; delaySynth.set(\delayToReverb, msg[1]); revSynth.set(\delayToReverb, msg[1]); });
			this.addCommand(\revtofwd,  "f", { arg msg; revSynth.set(\revToFwd, msg[1]); });

		// Global (shared) reverse-delay params -> the reverse delay synth.
		this.addCommand(\revtime, "f", { arg msg; revSynth.set(\delaySamps, msg[1]); });
		this.addCommand(\revfb,   "f", { arg msg; revSynth.set(\feedback, msg[1]); });
		this.addCommand(\revtone, "f", { arg msg; revSynth.set(\tone, msg[1]); });
		this.addCommand(\revmod,  "f", { arg msg; revSynth.set(\mod, msg[1]); });

		// shimmer reverb (DronageGreyhole + octave PitchShift feedback), pre-tape
		this.addCommand(\reverbsize,    "f", { arg msg; reverbSynth.set(\size, msg[1]); });
		this.addCommand(\reverbtime,    "f", { arg msg; reverbSynth.set(\time, msg[1]); });
		this.addCommand(\reverbdamp,    "f", { arg msg; reverbSynth.set(\damp, msg[1]); });
		this.addCommand(\reverbdiff,    "f", { arg msg; reverbSynth.set(\diff, msg[1]); });
		this.addCommand(\reverbfb,      "f", { arg msg; reverbSynth.set(\feedback, msg[1]); });
		this.addCommand(\reverbmod,     "f", { arg msg; reverbSynth.set(\mod, msg[1]); });
		this.addCommand(\reverbshimmer, "f", { arg msg; reverbSynth.set(\shimmer, msg[1]); });
		this.addCommand(\reverbmix,     "f", { arg msg; reverbSynth.set(\mix, msg[1]); });

		// Master tape stage -> the tape synth.
		this.addCommand(\tapedrive, "f", { arg msg; tapeSynth.set(\drive, msg[1]); });
		this.addCommand(\tapesat,    "f", { arg msg; tapeSynth.set(\sat, msg[1]); });
		this.addCommand(\tapesatamt, "f", { arg msg; tapeSynth.set(\satamt, msg[1]); });
		this.addCommand(\tapecolor, "f", { arg msg; tapeSynth.set(\color, msg[1]); });
		this.addCommand(\tapewow,   "f", { arg msg; tapeSynth.set(\wow, msg[1]); });
		this.addCommand(\tapecomp,  "f", { arg msg; tapeSynth.set(\comp, msg[1]); });
		this.addCommand(\tapedb,    "f", { arg msg; tapeSynth.set(\db, msg[1]); });
		this.addCommand(\tapeloss,    "f", { arg msg; tapeSynth.set(\loss, msg[1]); });
		this.addCommand(\tapechew,    "f", { arg msg; tapeSynth.set(\chew, msg[1]); });
		this.addCommand(\tapedegrade, "f", { arg msg; tapeSynth.set(\degrade, msg[1]); });
		this.addCommand(\tapehiss,  "f", { arg msg; tapeSynth.set(\hiss, msg[1]); });
		this.addCommand(\mastervol, "f", { arg msg; tapeSynth.set(\mastervol, msg[1]); });

		// Model selector: "ii" = (int voice, int model 0-23). Not smoothed (clicks on change).
		this.addCommand(\engine, "ii", { arg msg;
			var idx = msg[1].asInteger - 1;
			if(idx >= 0 and: { idx < numVoices }, {
				voices[idx].set(\engine, msg[2].asInteger.clip(0, 27));
			});
		});

		// Voice mute/unmute (fade): "ii" = (int voice, int on). 1 = fade in, 0 = fade out.
		this.addCommand(\gate, "ii", { arg msg;
			var idx = msg[1].asInteger - 1;
			if(idx >= 0 and: { idx < numVoices }, {
				voices[idx].set(\gate, msg[2].asInteger);
			});
		});
	}

	free {
		fxGroup.free;
		voiceGroup.free; // frees all 4 voice synths at once
		dlySendBus.free;
		revSendBus.free;
		rvbSendBus.free;
		mixBus.free;
		wobbleBuf.free; compressBuf.free; expandBuf.free; hissBuf.free;
		specForwarder.free;
		scopeRoutine.stop; scopeBuf.free;
	}
}
