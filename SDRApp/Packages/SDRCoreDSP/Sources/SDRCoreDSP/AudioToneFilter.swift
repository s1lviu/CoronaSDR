import Foundation

/// Audio tone shaping with 4th-order Butterworth high-pass and low-pass filters.
///
/// Each filter stage uses two cascaded biquad sections (-24 dB/octave rolloff).
/// Designed for realtime DSP loop usage:
/// - In-place processing, no allocations in hot path
/// - Direct Form II Transposed biquads for numerical stability
/// - Thread-safe coefficient updates via lock
public final class AudioToneFilter {
    private let sampleRate: Float
    private let lock = NSLock()

    private var highPassCutoffHz: Float = 0
    private var lowPassCutoffHz: Float = 0

    /// Biquad section: coefficients + Direct Form II Transposed state.
    private struct Biquad {
        var b0: Float = 0, b1: Float = 0, b2: Float = 0
        var a1: Float = 0, a2: Float = 0
        var w1: Float = 0, w2: Float = 0
    }

    // 4th-order Butterworth = 2 cascaded biquad sections per filter
    private var hp0 = Biquad(), hp1 = Biquad()
    private var lp0 = Biquad(), lp1 = Biquad()

    // 4th-order Butterworth Q values: Q_k = 1 / (2·cos(π(2k-1) / (2N))), N=4
    private static let bwQ1: Float = 1.0 / (2.0 * cos(Float.pi / 8.0))       // ≈ 0.5412
    private static let bwQ2: Float = 1.0 / (2.0 * cos(3.0 * Float.pi / 8.0)) // ≈ 1.3066

    public init(sampleRate: Float) {
        self.sampleRate = sampleRate
    }

    public func setHighPassCutoff(_ hz: Int) {
        lock.lock()
        defer { lock.unlock() }
        highPassCutoffHz = max(0, Float(hz))
        if highPassCutoffHz > 0 {
            computeHighPassCoeffs()
        }
    }

    public func setLowPassCutoff(_ hz: Int) {
        lock.lock()
        defer { lock.unlock() }
        lowPassCutoffHz = max(0, Float(hz))
        if lowPassCutoffHz > 0 {
            computeLowPassCoeffs()
        }
    }

    public func currentHighPassCutoffHz() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(highPassCutoffHz.rounded())
    }

    public func currentLowPassCutoffHz() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return Int(lowPassCutoffHz.rounded())
    }

    public func processInPlace(_ samples: UnsafeMutableBufferPointer<Float>, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return }
        guard let base = samples.baseAddress else { return }

        let hpEnabled = highPassCutoffHz > 0
        let lpEnabled = lowPassCutoffHz > 0
        if !hpEnabled, !lpEnabled { return }

        // Copy to stack (value types, no ARC overhead)
        var h0 = hp0, h1 = hp1
        var l0 = lp0, l1 = lp1

        for i in 0..<count {
            var x = base[i]

            if hpEnabled {
                // HP biquad section 0
                var y = h0.b0 * x + h0.w1
                h0.w1 = h0.b1 * x - h0.a1 * y + h0.w2
                h0.w2 = h0.b2 * x - h0.a2 * y
                x = y
                // HP biquad section 1
                y = h1.b0 * x + h1.w1
                h1.w1 = h1.b1 * x - h1.a1 * y + h1.w2
                h1.w2 = h1.b2 * x - h1.a2 * y
                x = y
            }

            if lpEnabled {
                // LP biquad section 0
                var y = l0.b0 * x + l0.w1
                l0.w1 = l0.b1 * x - l0.a1 * y + l0.w2
                l0.w2 = l0.b2 * x - l0.a2 * y
                x = y
                // LP biquad section 1
                y = l1.b0 * x + l1.w1
                l1.w1 = l1.b1 * x - l1.a1 * y + l1.w2
                l1.w2 = l1.b2 * x - l1.a2 * y
                x = y
            }

            base[i] = x
        }

        // Write back filter state
        hp0 = h0; hp1 = h1
        lp0 = l0; lp1 = l1
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        hp0.w1 = 0; hp0.w2 = 0
        hp1.w1 = 0; hp1.w2 = 0
        lp0.w1 = 0; lp0.w2 = 0
        lp1.w1 = 0; lp1.w2 = 0
    }

    // MARK: - Butterworth Biquad Coefficient Design (Audio EQ Cookbook)

    private func computeHighPassCoeffs() {
        let w0 = 2.0 * Float.pi * highPassCutoffHz / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)

        // Section 0 (Q1 ≈ 0.5412)
        let alpha0 = sinW0 / (2.0 * AudioToneFilter.bwQ1)
        let inv0 = 1.0 / (1.0 + alpha0)
        hp0.b0 = ((1.0 + cosW0) / 2.0) * inv0
        hp0.b1 = (-(1.0 + cosW0)) * inv0
        hp0.b2 = hp0.b0
        hp0.a1 = (-2.0 * cosW0) * inv0
        hp0.a2 = (1.0 - alpha0) * inv0

        // Section 1 (Q2 ≈ 1.3066)
        let alpha1 = sinW0 / (2.0 * AudioToneFilter.bwQ2)
        let inv1 = 1.0 / (1.0 + alpha1)
        hp1.b0 = ((1.0 + cosW0) / 2.0) * inv1
        hp1.b1 = (-(1.0 + cosW0)) * inv1
        hp1.b2 = hp1.b0
        hp1.a1 = (-2.0 * cosW0) * inv1
        hp1.a2 = (1.0 - alpha1) * inv1
    }

    private func computeLowPassCoeffs() {
        let w0 = 2.0 * Float.pi * lowPassCutoffHz / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)

        // Section 0 (Q1 ≈ 0.5412)
        let alpha0 = sinW0 / (2.0 * AudioToneFilter.bwQ1)
        let inv0 = 1.0 / (1.0 + alpha0)
        lp0.b0 = ((1.0 - cosW0) / 2.0) * inv0
        lp0.b1 = (1.0 - cosW0) * inv0
        lp0.b2 = lp0.b0
        lp0.a1 = (-2.0 * cosW0) * inv0
        lp0.a2 = (1.0 - alpha0) * inv0

        // Section 1 (Q2 ≈ 1.3066)
        let alpha1 = sinW0 / (2.0 * AudioToneFilter.bwQ2)
        let inv1 = 1.0 / (1.0 + alpha1)
        lp1.b0 = ((1.0 - cosW0) / 2.0) * inv1
        lp1.b1 = (1.0 - cosW0) * inv1
        lp1.b2 = lp1.b0
        lp1.a1 = (-2.0 * cosW0) * inv1
        lp1.a2 = (1.0 - alpha1) * inv1
    }
}
