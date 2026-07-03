DronageAnalogChew : UGen {
	*ar { |input, depth=0.5, freq=0.5, variance=0.5|
		^this.multiNew('audio', input, depth, freq, variance);
	}

	checkInputs {
		/* TODO */
		^this.checkValidInputs;
	}
}

// Stereo-linked chew: ONE crinkle scheduler drives both channels (mono expansion gave each
// channel its own random schedule = alternating one-sided dropouts, a fake ping-pong).
DronageAnalogChewSt : MultiOutUGen {
	*ar { |inL, inR, depth=0.5, freq=0.5, variance=0.5|
		^this.multiNew('audio', inL, inR, depth, freq, variance);
	}
	init { arg ... theInputs;
		inputs = theInputs;
		^this.initOutputs(2, rate)
	}
}

