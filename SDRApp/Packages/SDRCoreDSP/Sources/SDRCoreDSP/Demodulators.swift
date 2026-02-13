import Foundation
import Accelerate

/// Protocol for all demodulators.
public protocol Demodulator {
    /// Demodulate complex IQ samples into real audio samples.
    func demodulate(real: [Float], imag: [Float]) -> [Float]
    func reset()
}

// MARK: - AM Demodulator

/// AM envelope demodulator: output = sqrt(I^2 + Q^2) with DC removal and AGC.
public final class AMDemodulator: Demodulator {
    private let dcBlocker = DCBlocker()
    private let agc = AGC(targetLevel: 0.3, attackRate: 0.005, decayRate: 0.00005)

    public var agcEnabled: Bool {
        get { agc.isEnabled }
        set { agc.isEnabled = newValue }
    }

    public init() {}

    public func demodulate(real: [Float], imag: [Float]) -> [Float] {
        let count = real.count
        var output = [Float](repeating: 0, count: count)

        // Magnitude: sqrt(I^2 + Q^2)
        real.withUnsafeBufferPointer { r in
            imag.withUnsafeBufferPointer { i in
                output.withUnsafeMutableBufferPointer { out in
                    var realSq = [Float](repeating: 0, count: count)
                    var imagSq = [Float](repeating: 0, count: count)
                    vDSP_vsq(r.baseAddress!, 1, &realSq, 1, vDSP_Length(count))
                    vDSP_vsq(i.baseAddress!, 1, &imagSq, 1, vDSP_Length(count))
                    vDSP_vadd(realSq, 1, imagSq, 1, out.baseAddress!, 1, vDSP_Length(count))
                    var n = Int32(count)
                    vvsqrtf(out.baseAddress!, out.baseAddress!, &n)
                }
            }
        }

        // DC removal
        dcBlocker.process(&output)

        // AGC
        agc.process(&output)

        return output
    }

    public func reset() {
        dcBlocker.reset()
        agc.reset()
    }
}

// MARK: - FM Demodulator (NFM / WFM)

/// FM quadrature demodulator with optional de-emphasis.
public final class FMDemodulator: Demodulator {
    private var prevI: Float = 0
    private var prevQ: Float = 0
    private let gain: Float

    // De-emphasis filter state
    private var deemphPrev: Float = 0
    private let deemphAlpha: Float

    public init(sampleRate: Float, deemphasisUs: Float = 75.0) {
        // FM demod gain: normalize output to ~1.0
        // For NFM with deviation ~5kHz, gain = sampleRate / (2π * deviation)
        self.gain = 1.0 / .pi

        // De-emphasis: single-pole IIR
        // tau = deemphasis_us * 1e-6
        // alpha = 1 - exp(-1 / (sampleRate * tau))
        let tau = deemphasisUs * 1e-6
        self.deemphAlpha = 1.0 - exp(-1.0 / (sampleRate * tau))
    }

    public func demodulate(real: [Float], imag: [Float]) -> [Float] {
        let count = real.count
        var output = [Float](repeating: 0, count: count)

        // Quadrature demodulation: atan2(Q[n]*I[n-1] - I[n]*Q[n-1], I[n]*I[n-1] + Q[n]*Q[n-1])
        // Approximation: (Q[n]*I[n-1] - I[n]*Q[n-1]) / (I[n]^2 + Q[n]^2) for small angles
        var pI = prevI
        var pQ = prevQ

        for i in 0..<count {
            let curI = real[i]
            let curQ = imag[i]

            // Cross product / dot product approximation
            let cross = curQ * pI - curI * pQ
            let dot = curI * pI + curQ * pQ

            output[i] = atan2f(cross, dot) * gain

            pI = curI
            pQ = curQ
        }

        prevI = pI
        prevQ = pQ

        // De-emphasis
        applyDeemphasis(&output)

        return output
    }

    private func applyDeemphasis(_ samples: inout [Float]) {
        var prev = deemphPrev
        for i in 0..<samples.count {
            prev = prev + deemphAlpha * (samples[i] - prev)
            samples[i] = prev
        }
        deemphPrev = prev
    }

    public func reset() {
        prevI = 0
        prevQ = 0
        deemphPrev = 0
    }
}

// MARK: - SSB Demodulator

/// SSB (USB/LSB) demodulator.
/// For USB: output = real part (after frequency shift if BFO applied).
/// For LSB: conjugate then real part.
public final class SSBDemodulator: Demodulator {
    public let isUSB: Bool
    private let agc = AGC(targetLevel: 0.3, attackRate: 0.002, decayRate: 0.0001)

    public var agcEnabled: Bool {
        get { agc.isEnabled }
        set { agc.isEnabled = newValue }
    }

    public init(isUSB: Bool) {
        self.isUSB = isUSB
    }

    public func demodulate(real: [Float], imag: [Float]) -> [Float] {
        // SSB: take the real part of the analytic signal.
        // For USB: real part directly.
        // For LSB: conjugate (negate Q) then real part = same as real part.
        // The difference is handled by the BFO/NCO offset direction in the channelizer.
        var output = real

        agc.process(&output)

        return output
    }

    public func reset() {
        agc.reset()
    }
}

// MARK: - CW Demodulator

/// CW demodulator: essentially SSB with a narrow filter and sidetone.
public final class CWDemodulator: Demodulator {
    private let agc = AGC(targetLevel: 0.4, attackRate: 0.01, decayRate: 0.0005)

    public init() {}

    public func demodulate(real: [Float], imag: [Float]) -> [Float] {
        var output = real
        agc.process(&output)
        return output
    }

    public func reset() {
        agc.reset()
    }
}
