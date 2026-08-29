import Foundation

/// Impulse noise blanker for post-demodulation audio.
///
/// Detects samples that exceed a threshold relative to a running RMS estimate
/// and replaces them with linear interpolation from surrounding samples.
/// Effective against ignition noise, electrical interference, and other impulse noise.
/// Does NOT gate entire blocks like squelch — only individual spikes are blanked.
public final class NoiseBlanker {
    /// Blanker threshold (0.0 = off, higher = less aggressive).
    /// Typical range: 0.0–1.0 where 0 disables blanking.
    /// Internally mapped so lower user values = more aggressive blanking.
    public var threshold: Float = 0.0

    /// Running RMS estimate of signal level.
    private var runningRMS: Float = 0.0
    private let rmsAlpha: Float = 0.002 // Moderate RMS tracking

    public init() {}

    /// Process audio block in-place, blanking impulse spikes.
    public func process(_ samples: inout [Float]) {
        guard threshold > 0, !samples.isEmpty else { return }

        // Map user threshold (0–1) to spike detection multiplier.
        // threshold=1.0 (least aggressive) → need 20× RMS to blank
        // threshold=0.01 (most aggressive) → need 3× RMS to blank
        let spikeMultiplier = 3.0 + (1.0 - threshold) * 17.0

        // Compute spike threshold from current block-start RMS.
        let spikeThreshold = runningRMS * spikeMultiplier

        var rms = runningRMS
        let alpha = rmsAlpha

        for i in 0..<samples.count {
            let absSample = abs(samples[i])

            // Always update RMS to track signal level.
            // Spikes are rare/short and barely affect a slow-tracking average.
            rms = rms + alpha * (absSample - rms)

            // Only blank if RMS has had time to stabilize (non-zero threshold).
            if spikeThreshold > 0, absSample > spikeThreshold {
                // Spike detected — interpolate from neighbors.
                let prev = i > 0 ? samples[i - 1] : 0
                let next = (i + 1 < samples.count) ? samples[i + 1] : 0
                samples[i] = (prev + next) * 0.5
            }
        }

        // Floor RMS to prevent it collapsing to zero during silence.
        runningRMS = max(1e-6, rms)
    }

    public func reset() {
        runningRMS = 0.0
    }
}
