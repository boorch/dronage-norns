// DronageGreyhole - dronage-norns' own build of Greyhole (Julian Parker, sc3-plugins DEINDUGens).
//
// Faust-generated diffuse-delay/reverb. Renamed to the Dronage* namespace (class + registered
// UGen) so it coexists with any stock Greyhole and ships self-contained with the script. Vendored
// C++ at dronage-ugens/vendor/Greyhole/; see THIRD_PARTY_LICENSES.md. GPL-2.0+.
// Arg surface identical to the original Greyhole.

DronageGreyhole {
	*ar { | in, delayTime(2.0), damp(0.0), size(1.0), diff(0.707), feedback(0.9), modDepth(0.1), modFreq(2.0)|
		in = in.asArray;
		^DronageGreyholeRaw.ar(in.first, in.last,
			damp, delayTime, diff, feedback, modDepth, modFreq, size)
	}
}

DronageGreyholeRaw : MultiOutUGen
{
	*ar { | in1, in2, damping(0.0), delaytime(2.0), diffusion(0.5), feedback(0.9), moddepth(0.1), modfreq(2.0), size(1.0) |
		^this.multiNew('audio', in1, in2, damping, delaytime, diffusion, feedback, moddepth, modfreq, size)
	}

	checkInputs {
		if (rate == 'audio', {
			2.do({|i|
				if (inputs.at(i).rate != 'audio', {
					^(" input at index " + i + "(" + inputs.at(i) +
						") is not audio rate");
				});
			});
		});
		^this.checkValidInputs
	}

	init { | ... theInputs |
		inputs = theInputs;
		^this.initOutputs(2, rate)
	}

	name { ^"DronageGreyholeRaw" }
}
