DronageAnalogDegrade : UGen {
	*ar { |input, depth=0.5, amount=0.5, variance=0.5, envelope=0.5|
		^this.multiNew('audio', input, depth, amount, variance, envelope);
	}

	checkInputs {
		/* TODO */
		^this.checkValidInputs;
	}
}

// Stereo-linked degrade: shared random draws (filter offset + gain wander) so L/R wear
// identically; the hiss noise stays per-channel (decorrelated, like real stereo tape).
DronageAnalogDegradeSt : MultiOutUGen {
	*ar { |inL, inR, depth=0.5, amount=0.5, variance=0.5, envelope=0.5|
		^this.multiNew('audio', inL, inR, depth, amount, variance, envelope);
	}
	init { arg ... theInputs;
		inputs = theInputs;
		^this.initOutputs(2, rate)
	}
}

