// DronageMacrosynth - dronage-norns' own build of Mutable Instruments Plaits.
//
// Vendored from the original MI eurorack C++ DSP (Émilie Gillet) via Volker Böhm's
// mi-UGens SC wrapper (https://vboehm.net, github.com/v7b1/mi-UGens), both GPL-3.0.
// Renamed to the Dronage* namespace so it coexists with the stock MiPlaits the
// other norns scripts use, and so we can modify the DSP (LPG-colour→resonance,
// custom engines) without touching the shared install. See THIRD_PARTY_LICENSES.md.
//
// Arg surface is identical to MiPlaits - drop-in. Stereo (OUT, AUX).
DronageMacrosynth : MultiOutUGen {

	*ar {
		arg pitch=60.0, engine=0, harm=0.1, timbre=0.5, morph=0.5, trigger=0.0, level=0, fm_mod=0.0, timb_mod=0.0,
		morph_mod=0.0, decay=0.5, lpg_colour=0.5, drone=0.0, mul=1.0;
		^this.multiNew('audio', pitch, engine, harm, timbre, morph, trigger, level, fm_mod, timb_mod, morph_mod,
			decay, lpg_colour, drone).madd(mul);
	}

	init { arg ... theInputs;
		inputs = theInputs;
		^this.initOutputs(2, rate);
	}
}
