DronageDrive : UGen {
	*ar { arg in = 0.0, drive = 0.0;
		^this.multiNew('audio', in, drive)
	}
}

// Bipolar amp-sim. drive -1..+1: <0 = Doom (RAT fuzz), >0 = Marshall (tube), 0 = bypass.
DronageBipolarDist : UGen {
	*ar { arg in = 0.0, drive = 0.0;
		^this.multiNew('audio', in, drive)
	}
}

// Bipolar stereo chorus. mono in -> [L, R]. amount -1..+1: <0 warm, >0 spacey, 0 = bypass.
DronageChorus : MultiOutUGen {
	*ar { arg inL = 0.0, inR = 0.0, amount = 0.0;
		^this.multiNew('audio', inL, inR, amount)
	}
	init { arg ... theInputs;
		inputs = theInputs;
		^this.initOutputs(2, rate)
	}
}

// Signature tempo-synced delay (ping-pong L@T/R@2T) with grain engine. mono in -> [L, R].
// delaySamps = division*bpm*sr (computed in Lua). granular -1..+1 (grain layer = increment 2).
// bufnum = a MONO server Buffer holding the delay line (its frame count IS the max delay x2
// tap): plain RAM, deliberately NOT the scsynth 8MB RT pool, which it starved in the field.
DronageGranularDelay : MultiOutUGen {
	*ar { arg bufnum, in = 0.0, delaySamps = 24000, feedback = 0.5, tone = 0.0, mod = 0.0, granular = 0.0;
		^this.multiNew('audio', bufnum, in, delaySamps, feedback, tone, mod, granular)
	}
	init { arg ... theInputs;
		inputs = theInputs;
		^this.initOutputs(2, rate)
	}
}

// Reverse delay (Costello/DL4). mono in -> [L, R]. delaySamps = division*bpm*sr.
// granular -1..+1 (same grain layer as the forward delay, mirrored in C++).
// bufnumL/bufnumR = MONO server Buffers for the two delay lines (frame count = 2x max
// delay, the reverse head needs double); plain RAM, not the RT pool (see above).
DronageReverseDelay : MultiOutUGen {
	*ar { arg bufnumL, bufnumR, in = 0.0, delaySamps = 24000, feedback = 0.5, tone = 0.0, mod = 0.0, granular = 0.0;
		^this.multiNew('audio', bufnumL, bufnumR, in, delaySamps, feedback, tone, mod, granular)
	}
	init { arg ... theInputs;
		inputs = theInputs;
		^this.initOutputs(2, rate)
	}
}
