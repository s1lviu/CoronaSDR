import Foundation
import Accelerate
import CLiquidDSP

/// Protocol for all demodulators.
public protocol Demodulator {
    /// Demodulate complex IQ samples into real audio samples.
    func demodulate(real: [Float], imag: [Float]) -> [Float]
    func reset()
}

// MARK: - AM Demodulator (Envelope)

/// AM envelope demodulator: output = sqrt(I^2 + Q^2) with DC removal and AGC.
/// Kept as simple envelope detection for robustness against tuning errors.
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

// MARK: - FM Demodulator (liquid-dsp)

/// FM demodulator using liquid-dsp's freqdem object.
/// Provides superior PLL-based demodulation.
/// Includes post-demodulation de-emphasis filter.
public final class FMDemodulator: Demodulator {
    private var q: freqdem
    private let gain: Float
    
    // De-emphasis state
    private var deemphPrev: Float = 0
    private let deemphAlpha: Float

    /// Create FM demodulator.
    /// - Parameters:
    ///   - sampleRate: The sample rate of the input IQ stream (e.g. 48000 or 240000).
    ///   - deviation: The frequency deviation in Hz (e.g. 5000 for NFM, 75000 for WFM).
    ///   - deemphasisUs: De-emphasis time constant in microseconds (default 75 for US/KR, 50 for EU).
    public init(sampleRate: Float, deviation: Float, deemphasisUs: Float = 75.0) {
        // kf = deviation / sample_rate
        let kf = deviation / sampleRate
        self.q = freqdem_create(kf)
        self.gain = 1.0 
        
        // De-emphasis: alpha = 1 - exp(-1 / (sampleRate * tau))
        // tau = deemphasis_us * 1e-6
        let tau = deemphasisUs * 1e-6
        self.deemphAlpha = 1.0 - exp(-1.0 / (sampleRate * tau))
    }
    
    deinit {
        freqdem_destroy(q)
    }

    public func demodulate(real: [Float], imag: [Float]) -> [Float] {
        let count = real.count
        var output = [Float](repeating: 0, count: count)
        
        // Local state capture for loop
        var prev = deemphPrev
        let alpha = deemphAlpha
        
        for i in 0..<count {
            // Construct complex sample
            var sample = liquid_float_complex(real: real[i], imag: imag[i])
            var outSample: Float = 0
            
            // Demodulate
            freqdem_demodulate(q, sample, &outSample)
            
            // De-emphasis (IIR single pole)
            // y[n] = y[n-1] + alpha * (x[n] - y[n-1])
            prev = prev + alpha * (outSample - prev)
            output[i] = prev
        }
        
        deemphPrev = prev

        return output
    }

    public func reset() {
        freqdem_reset(q)
        deemphPrev = 0
    }
}

// MARK: - SSB Demodulator (liquid-dsp)

/// SSB (USB/LSB) demodulator using liquid-dsp's ampmodem.
/// Correctly rejects the unwanted sideband using complex filtering.
public final class SSBDemodulator: Demodulator {
    private var q: ampmodem
    private let agc = AGC(targetLevel: 0.3, attackRate: 0.002, decayRate: 0.0001)
    
    public var agcEnabled: Bool {
        get { agc.isEnabled }
        set { agc.isEnabled = newValue }
    }

    public init(isUSB: Bool) {
        // ampmodem_create(modulation_index, type, suppressed_carrier)
        // For SSB, modulation_index is typically 1.0 (or ignored).
        // suppressed_carrier = 1 (true) for SSB.
        let type = isUSB ? LIQUID_AMPMODEM_USB : LIQUID_AMPMODEM_LSB
        self.q = ampmodem_create(0.5, type, 1)
    }
    
    deinit {
        ampmodem_destroy(q)
    }

    public func demodulate(real: [Float], imag: [Float]) -> [Float] {
        let count = real.count
        var output = [Float](repeating: 0, count: count)
        
        for i in 0..<count {
            var sample = liquid_float_complex(real: real[i], imag: imag[i])
            var outSample: Float = 0
            
            // For ampmodem demodulate, it takes complex input (IQ) and gives real audio output
            ampmodem_demodulate(q, sample, &outSample)
            
            output[i] = outSample
        }

        agc.process(&output)
        return output
    }

    public func reset() {
        ampmodem_reset(q)
        agc.reset()
    }
}

// MARK: - CW Demodulator

/// CW demodulator: uses USB demodulation + narrow filter (handled in pipeline) + BFO.
/// We reuse SSBDemodulator(USB) as the base, since CW is essentially SSB with a tone.
public final class CWDemodulator: Demodulator {
    private let ssbDemod = SSBDemodulator(isUSB: true)

    public init() {}

    public func demodulate(real: [Float], imag: [Float]) -> [Float] {
        return ssbDemod.demodulate(real: real, imag: imag)
    }

    public func reset() {
        ssbDemod.reset()
    }
}
