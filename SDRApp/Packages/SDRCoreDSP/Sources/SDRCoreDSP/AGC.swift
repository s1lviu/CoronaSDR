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
            let absSample = abs(samples[i])
            let error = targetLevel - absSample * gain

            if error < 0 {
                // Level too high -> reduce gain quickly (attack)
                gain += error * attackRate
            } else {
                // Level too low -> increase gain slowly (decay)
                gain += error * decayRate
            }

            gain = max(minGain, min(maxGain, gain))
            samples[i] *= gain
        }
    }

    public func reset() {
        gain = 1.0
    }
}
