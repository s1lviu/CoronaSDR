import Foundation
import Accelerate
import CLiquidDSP

/// Protocol for all demodulators.
public protocol Demodulator {
    /// Demodulate complex IQ samples into real audio samples.
    func demodulate(real: [Float], imag: [Float]) -> [Float]
    func reset()
}

/// Left/right stereo demodulator output before final audio resampling.
public struct StereoAudioBlock {
    public var left: [Float]
    public var right: [Float]

    public init(left: [Float], right: [Float]) {
        self.left = left
        self.right = right
    }
}

private final class DeemphasisFilter {
    private var previous: Float = 0
    private let alpha: Float

    init(sampleRate: Float, microseconds: Float) {
        if microseconds <= 0 {
            self.alpha = 1.0
        } else {
            let tau = microseconds * 1e-6
            self.alpha = 1.0 - exp(-1.0 / (sampleRate * tau))
        }
    }

    func process(_ samples: inout [Float]) {
        var state = previous
        for i in samples.indices {
            state = state + alpha * (samples[i] - state)
            samples[i] = state
        }
        previous = state
    }

    func reset() {
        previous = 0
    }
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
    private let deemphasis: DeemphasisFilter

    /// Create FM demodulator.
    /// - Parameters:
    ///   - sampleRate: The sample rate of the input IQ stream (e.g. 48000 or 240000).
    ///   - deviation: The frequency deviation in Hz (e.g. 5000 for NFM, 75000 for WFM).
    ///   - deemphasisUs: De-emphasis time constant in microseconds (default 75 for US/KR, 50 for EU).
    public init(sampleRate: Float, deviation: Float, deemphasisUs: Float = 75.0) {
        let kf = deviation / sampleRate
        self.q = freqdem_create(kf)
        self.deemphasis = DeemphasisFilter(sampleRate: sampleRate, microseconds: deemphasisUs)
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

        // De-emphasis as a separate pass (single-pole IIR low-pass).
        deemphasis.process(&outputScratch)

        return outputScratch
    }

    public func reset() {
        freqdem_reset(q)
        deemphasis.reset()
    }
}

// MARK: - WFM Stereo Demodulator

/// Broadcast FM stereo demodulator.
///
/// The input is channelized WFM IQ. The FM discriminator returns the composite
/// MPX signal. Stereo decode then extracts L+R, locks to the 19 kHz pilot,
/// regenerates the 38 kHz suppressed subcarrier, demodulates L-R, and matrices
/// left/right audio with independent de-emphasis.
public final class WFMStereoDemodulator {
    private let sampleRate: Float
    private var fmDemodulator: FMDemodulator
    private var sumFilter: FIRFilter
    private var differenceFilter: FIRFilter
    private var pilotFilter: FIRFilter
    private let leftDeemphasis: DeemphasisFilter
    private let rightDeemphasis: DeemphasisFilter
    private let pilotFilterGroupDelaySamples: Float

    private var pilotPhase: Float = 0
    private var pilotFrequency: Float
    private var pilotIntegrator: Float = 0
    private var pilotLevel: Float = 0

    private var mpxScratch: [Float] = []
    private var sumScratch: [Float] = []
    private var pilotScratch: [Float] = []
    private var differenceMixedScratch: [Float] = []
    private var differenceScratch: [Float] = []
    private var leftScratch: [Float] = []
    private var rightScratch: [Float] = []

    private let twoPi: Float = 2.0 * .pi
    private let nominalPilotRadiansPerSample: Float
    private let pllProportionalGain: Float = 0.00035
    private let pllIntegralGain: Float = 0.0000008
    private let maximumPilotCorrection: Float
    private let stereoPilotOpenThreshold: Float = 0.002
    private let stereoPilotCloseThreshold: Float = 0.001
    private var stereoLocked = false

    public init(sampleRate: Float, deviation: Float = 75_000, deemphasisUs: Float = 75.0) {
        self.sampleRate = sampleRate
        self.fmDemodulator = FMDemodulator(sampleRate: sampleRate, deviation: deviation, deemphasisUs: 0)
        self.leftDeemphasis = DeemphasisFilter(sampleRate: sampleRate, microseconds: deemphasisUs)
        self.rightDeemphasis = DeemphasisFilter(sampleRate: sampleRate, microseconds: deemphasisUs)

        let nyquist = sampleRate / 2.0
        let audioCutoff = min(15_000 / nyquist, 0.95)
        let pilotLow = max(18_500 / nyquist, 0.0001)
        let pilotHigh = min(19_500 / nyquist, 0.95)
        let audioTapCount = 129
        let pilotTapCount = 257
        self.sumFilter = FIRFilter(cutoffNormalized: audioCutoff, numTaps: audioTapCount)
        self.differenceFilter = FIRFilter(cutoffNormalized: audioCutoff, numTaps: audioTapCount)
        self.pilotFilter = FIRFilter(
            taps: FIRFilter.designBandPass(lowCutoff: pilotLow, highCutoff: pilotHigh, numTaps: pilotTapCount)
        )
        self.pilotFilterGroupDelaySamples = Float((pilotTapCount - 1) / 2)

        self.nominalPilotRadiansPerSample = twoPi * 19_000 / sampleRate
        self.pilotFrequency = nominalPilotRadiansPerSample
        self.maximumPilotCorrection = twoPi * 250 / sampleRate
    }

    public func demodulate(real: [Float], imag: [Float], stereoEnabled: Bool = true) -> StereoAudioBlock {
        mpxScratch = fmDemodulator.demodulate(real: real, imag: imag)
        guard !mpxScratch.isEmpty else {
            return StereoAudioBlock(left: [], right: [])
        }

        let sumCount = sumFilter.process(mpxScratch, into: &sumScratch)
        guard sumCount > 0 else {
            return StereoAudioBlock(left: [], right: [])
        }

        if !stereoEnabled {
            stereoLocked = false
            pilotLevel = 0
            return monoBlock(fromSumCount: sumCount)
        }

        _ = pilotFilter.process(mpxScratch, into: &pilotScratch)
        let count = min(mpxScratch.count, sumScratch.count, pilotScratch.count)
        guard count > 0 else {
            return StereoAudioBlock(left: [], right: [])
        }

        if differenceMixedScratch.count != count {
            differenceMixedScratch = [Float](repeating: 0, count: count)
        }

        var phase = pilotPhase
        var frequency = pilotFrequency
        var integrator = pilotIntegrator
        var level = pilotLevel

        for i in 0..<count {
            let pilot = pilotScratch[i]
            let quadrature = sinf(phase)
            let error = max(-0.25, min(0.25, -pilot * quadrature))
            integrator = max(-maximumPilotCorrection, min(maximumPilotCorrection, integrator + pllIntegralGain * error))
            frequency = nominalPilotRadiansPerSample + integrator + pllProportionalGain * error
            frequency = max(
                nominalPilotRadiansPerSample - maximumPilotCorrection,
                min(nominalPilotRadiansPerSample + maximumPilotCorrection, frequency)
            )

            let carrierPhase = phase + frequency * pilotFilterGroupDelaySamples
            let carrier38 = 2.0 * cosf(2.0 * carrierPhase)
            differenceMixedScratch[i] = mpxScratch[i] * carrier38

            level = level + 0.001 * (abs(pilot) - level)
            phase += frequency
            if phase >= twoPi {
                phase -= twoPi
            } else if phase < 0 {
                phase += twoPi
            }
        }

        pilotPhase = phase
        pilotFrequency = frequency
        pilotIntegrator = integrator
        pilotLevel = level

        if stereoLocked {
            stereoLocked = level > stereoPilotCloseThreshold
        } else {
            stereoLocked = level > stereoPilotOpenThreshold
        }

        _ = differenceFilter.process(differenceMixedScratch, into: &differenceScratch)
        let matrixCount = min(sumScratch.count, differenceScratch.count)
        guard matrixCount > 0 else {
            return StereoAudioBlock(left: [], right: [])
        }

        if leftScratch.count != matrixCount {
            leftScratch = [Float](repeating: 0, count: matrixCount)
        }
        if rightScratch.count != matrixCount {
            rightScratch = [Float](repeating: 0, count: matrixCount)
        }

        for i in 0..<matrixCount {
            let sum = sumScratch[i]
            let difference = stereoLocked ? differenceScratch[i] : 0
            leftScratch[i] = 0.5 * (sum + difference)
            rightScratch[i] = 0.5 * (sum - difference)
        }

        leftDeemphasis.process(&leftScratch)
        rightDeemphasis.process(&rightScratch)

        return StereoAudioBlock(left: leftScratch, right: rightScratch)
    }

    private func monoBlock(fromSumCount count: Int) -> StereoAudioBlock {
        if leftScratch.count != count {
            leftScratch = [Float](repeating: 0, count: count)
        }
        if rightScratch.count != count {
            rightScratch = [Float](repeating: 0, count: count)
        }

        for i in 0..<count {
            let mono = 0.5 * sumScratch[i]
            leftScratch[i] = mono
            rightScratch[i] = mono
        }

        leftDeemphasis.process(&leftScratch)
        rightDeemphasis.process(&rightScratch)

        return StereoAudioBlock(left: leftScratch, right: rightScratch)
    }

    public func reset() {
        fmDemodulator.reset()
        sumFilter.reset()
        differenceFilter.reset()
        pilotFilter.reset()
        leftDeemphasis.reset()
        rightDeemphasis.reset()
        pilotPhase = 0
        pilotFrequency = nominalPilotRadiansPerSample
        pilotIntegrator = 0
        pilotLevel = 0
        stereoLocked = false
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
