import Foundation
import Accelerate

/// Noise-based squelch for AM and FM modes.
/// Measures high-frequency noise power to determine if signal is present.
public final class Squelch {
    /// Squelch threshold (0.0–1.0). Higher = more signal needed to open.
    public var threshold: Float = 0.0

    /// Whether squelch is currently open (signal present).
    public private(set) var isOpen: Bool = true

    /// Smoothed noise level for UI display.
    public private(set) var noiseLevel: Float = 0

    private var holdSamples: Int = 0
    private let holdTime: Int // samples to keep open after signal drops
    private let smoothingAlpha: Float = 0.05

    /// High-pass filter for noise measurement.
    private var prevSample: Float = 0

    public init(sampleRate: Int = 48000, holdTimeMs: Int = 300) {
        self.holdTime = sampleRate * holdTimeMs / 1000
    }

    /// Process audio block. Returns true if squelch is open (pass audio).
    /// Mutes the block in-place if squelch is closed.
    @discardableResult
    public func process(_ samples: inout [Float]) -> Bool {
        guard threshold > 0 else {
            isOpen = true
            return true
        }
        guard !samples.isEmpty else { return isOpen }

        // Measure noise: one-pass high-pass + RMS accumulator (no per-block allocations).
        var sumSquares: Float = 0
        for i in 0..<samples.count {
            let hp = samples[i] - prevSample
            prevSample = samples[i]
            sumSquares += hp * hp
        }
        let rms = sqrt(sumSquares / Float(samples.count))

        // Smooth noise level
        noiseLevel = noiseLevel * (1 - smoothingAlpha) + rms * smoothingAlpha

        let signalPresent = noiseLevel < threshold

        if signalPresent {
            isOpen = true
            holdSamples = holdTime
        } else if holdSamples > 0 {
            holdSamples -= samples.count
            isOpen = true
        } else {
            isOpen = false
        }

        if !isOpen {
            // Mute
            vDSP_vclr(&samples, 1, vDSP_Length(samples.count))
        }

        return isOpen
    }

    public func reset() {
        isOpen = true
        noiseLevel = 0
        holdSamples = 0
        prevSample = 0
    }
}
