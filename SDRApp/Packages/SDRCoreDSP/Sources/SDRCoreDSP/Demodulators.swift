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
    private var realSqScratch: [Float] = []
    private var imagSqScratch: [Float] = []
    private var outputScratch: [Float] = []

    public var agcEnabled: Bool {
        get { agc.isEnabled }
        set { agc.isEnabled = newValue }
    }

    public init() {}

    public func demodulate(real: [Float], imag: [Float]) -> [Float] {
        let count = min(real.count, imag.count)
        guard count > 0 else { return [] }
        if realSqScratch.count != count { realSqScratch = [Float](repeating: 0, count: count) }
        if imagSqScratch.count != count { imagSqScratch = [Float](repeating: 0, count: count) }
        if outputScratch.count != count { outputScratch = [Float](repeating: 0, count: count) }

        // Magnitude: sqrt(I^2 + Q^2)
        real.withUnsafeBufferPointer { r in
            imag.withUnsafeBufferPointer { i in
                outputScratch.withUnsafeMutableBufferPointer { out in
                    vDSP_vsq(r.baseAddress!, 1, &realSqScratch, 1, vDSP_Length(count))
                    vDSP_vsq(i.baseAddress!, 1, &imagSqScratch, 1, vDSP_Length(count))
                    vDSP_vadd(realSqScratch, 1, imagSqScratch, 1, out.baseAddress!, 1, vDSP_Length(count))
                    var n = Int32(count)
                    vvsqrtf(out.baseAddress!, out.baseAddress!, &n)
                }
            }
        }

        // DC removal
        dcBlocker.process(&outputScratch)

        // AGC
        agc.process(&outputScratch)

        return outputScratch
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
    private var outputScratch: [Float] = []
    private var complexScratch: [liquid_float_complex] = []

    // De-emphasis state
    private var deemphPrev: Float = 0
    private let deemphAlpha: Float

    /// Create FM demodulator.
    /// - Parameters:
    ///   - sampleRate: The sample rate of the input IQ stream (e.g. 48000 or 240000).
    ///   - deviation: The frequency deviation in Hz (e.g. 5000 for NFM, 75000 for WFM).
    ///   - deemphasisUs: De-emphasis time constant in microseconds (default 75 for US/KR, 50 for EU).
    public init(sampleRate: Float, deviation: Float, deemphasisUs: Float = 75.0) {
        let kf = deviation / sampleRate
        self.q = freqdem_create(kf)

        if deemphasisUs <= 0 {
            self.deemphAlpha = 1.0
        } else {
            let tau = deemphasisUs * 1e-6
            self.deemphAlpha = 1.0 - exp(-1.0 / (sampleRate * tau))
        }
    }

    deinit {
        freqdem_destroy(q)
    }

    public func demodulate(real: [Float], imag: [Float]) -> [Float] {
        let count = min(real.count, imag.count)
        guard count > 0 else { return [] }
        if outputScratch.count != count { outputScratch = [Float](repeating: 0, count: count) }
        if complexScratch.count != count { complexScratch = [liquid_float_complex](repeating: liquid_float_complex(real: 0, imag: 0), count: count) }

        // Build interleaved complex array from separate I/Q
        real.withUnsafeBufferPointer { rBuf in
            imag.withUnsafeBufferPointer { iBuf in
                complexScratch.withUnsafeMutableBufferPointer { cBuf in
                    for i in 0..<count {
                        cBuf[i] = liquid_float_complex(real: rBuf[i], imag: iBuf[i])
                    }
                }
            }
        }

        // Block demodulate with one C call for the entire block.
        complexScratch.withUnsafeMutableBufferPointer { cBuf in
            outputScratch.withUnsafeMutableBufferPointer { outBuf in
                _ = freqdem_demodulate_block(q, cBuf.baseAddress!, UInt32(count), outBuf.baseAddress!)
            }
        }

        // De-emphasis as a separate pass (single-pole IIR low-pass)
        var prev = deemphPrev
        let alpha = deemphAlpha
        for i in 0..<count {
            prev = prev + alpha * (outputScratch[i] - prev)
            outputScratch[i] = prev
        }
        deemphPrev = prev

        return outputScratch
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
    private var outputScratch: [Float] = []
    
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
        let count = min(real.count, imag.count)
        guard count > 0 else { return [] }
        if outputScratch.count != count { outputScratch = [Float](repeating: 0, count: count) }
        
        for i in 0..<count {
            let sample = liquid_float_complex(real: real[i], imag: imag[i])
            var outSample: Float = 0
            
            // For ampmodem demodulate, it takes complex input (IQ) and gives real audio output
            ampmodem_demodulate(q, sample, &outSample)
            
            outputScratch[i] = outSample
        }

        agc.process(&outputScratch)
        return outputScratch
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
