import Foundation
import Accelerate

/// Automatic Gain Control for audio output.
/// Fast attack, slow decay - tuned for voice/speech (AM, airband).
public final class AGC {
    private var gain: Float = 1.0
    public var targetLevel: Float = 0.5
    public var attackRate: Float = 0.01    // fast attack
    public var decayRate: Float = 0.0001   // slow decay
    public var maxGain: Float = 100.0
    public var minGain: Float = 0.01
    public var isEnabled: Bool = true

    public init(targetLevel: Float = 0.5, attackRate: Float = 0.01, decayRate: Float = 0.0001) {
        self.targetLevel = targetLevel
        self.attackRate = attackRate
        self.decayRate = decayRate
    }

    /// Process a block of audio samples in-place.
    public func process(_ samples: inout [Float]) {
        guard isEnabled else { return }

        for i in 0..<samples.count {
            updateGain(for: abs(samples[i]))
            samples[i] *= gain
        }
    }

    /// Process stereo audio with one linked gain value.
    ///
    /// Independent left/right AGC changes the stereo image because each channel
    /// adapts toward the same target level. A linked detector preserves the
    /// channel relationship while still controlling loudness.
    public func processStereo(left: inout [Float], right: inout [Float]) {
        guard isEnabled else { return }

        let count = min(left.count, right.count)
        guard count > 0 else { return }

        for i in 0..<count {
            updateGain(for: max(abs(left[i]), abs(right[i])))
            left[i] *= gain
            right[i] *= gain
        }
    }

    private func updateGain(for absSample: Float) {
        let error = targetLevel - absSample * gain

        if error < 0 {
            // Level too high -> reduce gain quickly (attack)
            gain += error * attackRate
        } else {
            // Level too low -> increase gain slowly (decay)
            gain += error * decayRate
        }

        gain = max(minGain, min(maxGain, gain))
    }

    public func reset() {
        gain = 1.0
    }
}
