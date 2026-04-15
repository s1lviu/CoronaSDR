import XCTest
import SDRCoreDSP
import Accelerate

private func responseDb(taps: [Float], sampleRate: Float, frequencyHz: Float) -> Float {
    let omega = 2.0 * Float.pi * frequencyHz / sampleRate
    var real: Float = 0
    var imag: Float = 0

    for i in taps.indices {
        let phase = -omega * Float(i)
        real += taps[i] * cosf(phase)
        imag += taps[i] * sinf(phase)
    }

    return 20.0 * log10f(hypotf(real, imag) + 1e-20)
}

// MARK: - Channel filter alias rejection tests

final class ChannelFilterAliasingTests: XCTestCase {

    /// Verify that NFM channel filters are sized from the actual alias boundary.
    /// At high decimation, fixed 63-tap filters did not reach stop-band before
    /// the decimated Nyquist frequency, so aliased channel energy reached the FM
    /// discriminator as distortion.
    func testFilterTapCountScalesWithDecimation() {
        let profiles: [(label: String, sampleRate: Int, expectedTaps: Int)] = [
            ("Ultra Low", 250_000, 63),
            ("HF+ High", 768_000, 135),
            ("Low", 1_024_000, 173),
            ("Medium", 2_048_000, 345),
            ("High", 2_400_000, 419),
        ]

        for profile in profiles {
            let design = ChannelFilterDesigner.make(
                inputSampleRate: profile.sampleRate,
                bandwidthHz: 12_500,
                intermediateTargetHz: 48_000
            )

            XCTAssertEqual(
                design.tapCount,
                profile.expectedTaps,
                "\(profile.label): unexpected tap count"
            )
            XCTAssertEqual(design.tapCount % 2, 1, "\(profile.label): FIR tap count must be odd")
        }
    }

    /// Verify the designed filter reaches stop-band before the first alias
    /// boundary for every built-in NFM profile.
    func testDesignedFilterRejectsAliasBoundary() {
        let profiles: [(label: String, sampleRate: Int)] = [
            ("Ultra Low", 250_000),
            ("HF+ High", 768_000),
            ("Low", 1_024_000),
            ("Medium", 2_048_000),
            ("High", 2_400_000),
        ]

        for profile in profiles {
            let design = ChannelFilterDesigner.make(
                inputSampleRate: profile.sampleRate,
                bandwidthHz: 12_500,
                intermediateTargetHz: 48_000
            )
            let taps = FIRFilter.designLowPass(
                cutoff: design.normalizedCutoff,
                numTaps: design.tapCount
            )
            let aliasBoundaryHz = Float(design.intermediateRate / 2.0)
            let attenuationDb = responseDb(
                taps: taps,
                sampleRate: Float(design.inputSampleRate),
                frequencyHz: aliasBoundaryHz
            )

            XCTAssertLessThanOrEqual(
                attenuationDb,
                -45.0,
                "\(profile.label): alias boundary attenuation is only \(attenuationDb)dB"
            )
        }
    }

    /// End-to-end alias rejection: feed a tone above the NFM passband and
    /// verify it is suppressed after filter+decimation at high sample rates.
    func testHighProfileFilterRejectsOutOfBandTone() {
        let sampleRate = 2_400_000
        let bandwidth = 12_500
        let design = ChannelFilterDesigner.make(
            inputSampleRate: sampleRate,
            bandwidthHz: bandwidth,
            intermediateTargetHz: 48_000
        )

        let filter = FIRFilter(
            cutoffNormalized: design.normalizedCutoff,
            numTaps: design.tapCount,
            decimationFactor: design.decimationFactor
        )

        // Generate 10 ms of a 50 kHz tone (well outside 12.5 kHz NFM passband)
        let blockSize = sampleRate / 100 // 24000 samples
        let toneFreq: Float = 50_000
        let input: [Float] = (0..<blockSize).map { i in
            sinf(2.0 * .pi * toneFreq * Float(i) / Float(sampleRate))
        }

        // Settle the filter with a few blocks first
        for _ in 0..<3 {
            _ = filter.process(input)
        }

        let output = filter.process(input)
        XCTAssertGreaterThan(output.count, 0, "Filter should produce output")

        let rms = sqrtf(output.reduce(0) { $0 + $1 * $1 } / Float(output.count))

        // 50 kHz tone should be attenuated by at least 30 dB (RMS < 0.022 relative to 0.707 input)
        XCTAssertLessThan(rms, 0.03, "50 kHz tone should be heavily attenuated by NFM channel filter at 2.4 MSPS")
    }

    /// Verify that an in-band tone passes through the channel filter with minimal loss.
    func testHighProfileFilterPassesInBandTone() {
        let sampleRate = 2_400_000
        let bandwidth = 12_500
        let design = ChannelFilterDesigner.make(
            inputSampleRate: sampleRate,
            bandwidthHz: bandwidth,
            intermediateTargetHz: 48_000
        )

        let filter = FIRFilter(
            cutoffNormalized: design.normalizedCutoff,
            numTaps: design.tapCount,
            decimationFactor: design.decimationFactor
        )

        // Generate a 1 kHz tone (well within 12.5 kHz NFM passband)
        let blockSize = sampleRate / 100
        let toneFreq: Float = 1000
        let input: [Float] = (0..<blockSize).map { i in
            sinf(2.0 * .pi * toneFreq * Float(i) / Float(sampleRate))
        }

        // Settle
        for _ in 0..<3 {
            _ = filter.process(input)
        }

        let output = filter.process(input)
        let rms = sqrtf(output.reduce(0) { $0 + $1 * $1 } / Float(output.count))

        // Input RMS of a sine is about 0.707. In-band should pass with less than 3 dB loss.
        XCTAssertGreaterThan(rms, 0.45, "1 kHz tone should pass through NFM filter with minimal loss")
    }

    /// Regression test: with the old 63 fixed taps, a 50 kHz tone at 2.4 MSPS
    /// would alias into the output band. Verify the old config fails.
    func testOld63TapFilterFailsAtHighDecimation() {
        let sampleRate = 2_400_000
        let bandwidth = 12_500
        let decimFactor = max(1, sampleRate / 48_000)

        let cutoff = Float(bandwidth) / Float(sampleRate)
        let normalizedCutoff = min(0.99, max(0.0005, cutoff * 2))

        // Old fixed 63 taps
        let filterOld = FIRFilter(
            cutoffNormalized: normalizedCutoff,
            numTaps: 63,
            decimationFactor: decimFactor
        )

        let blockSize = sampleRate / 100
        let toneFreq: Float = 50_000
        let input: [Float] = (0..<blockSize).map { i in
            sinf(2.0 * .pi * toneFreq * Float(i) / Float(sampleRate))
        }

        for _ in 0..<3 { _ = filterOld.process(input) }
        let output = filterOld.process(input)
        let rms = sqrtf(output.reduce(0) { $0 + $1 * $1 } / Float(output.count))

        // With only 63 taps the out-of-band tone leaks through, so RMS stays high.
        XCTAssertGreaterThan(rms, 0.03, "63-tap filter should fail to reject 50 kHz at 2.4 MSPS (regression baseline)")
    }
}

// MARK: - FM demodulator block processing tests

final class FMDemodulatorTests: XCTestCase {

    /// Generate a complex FM signal: carrier at DC, modulated by a tone.
    /// Verify the demodulator recovers the modulating tone.
    func testFMDemodRecoversSineTone() {
        let sampleRate: Float = 48_000
        let deviation: Float = 5_000
        let modulatingFreq: Float = 1_000
        let count = 4800 // 100 ms

        // Generate FM-modulated IQ from the integral of deviation * sin(2*pi*fm*t).
        var real = [Float](repeating: 0, count: count)
        var imag = [Float](repeating: 0, count: count)

        for i in 0..<count {
            let t = Float(i) / sampleRate
            let phi = -(deviation / modulatingFreq) * cosf(2.0 * Float.pi * modulatingFreq * t)
            real[i] = cosf(phi)
            imag[i] = sinf(phi)
        }

        let demod = FMDemodulator(sampleRate: sampleRate, deviation: deviation, deemphasisUs: 0)
        let output = demod.demodulate(real: real, imag: imag)

        XCTAssertEqual(output.count, count)

        // Discard first 20% for filter settling, analyze the rest
        let settledStart = count / 5
        let settled = Array(output[settledStart...])

        // Output should be a sinusoid at modulatingFreq. Check it's not silent.
        let rms = sqrtf(settled.reduce(0) { $0 + $1 * $1 } / Float(settled.count))
        XCTAssertGreaterThan(rms, 0.1, "Demodulated output should contain the 1 kHz modulating tone")

        // Check zero crossings to verify frequency is approximately 1 kHz
        var crossings = 0
        for i in 1..<settled.count {
            if (settled[i - 1] >= 0 && settled[i] < 0) || (settled[i - 1] < 0 && settled[i] >= 0) {
                crossings += 1
            }
        }
        let durationSec = Double(settled.count) / Double(sampleRate)
        let estimatedFreq = Double(crossings) / (2.0 * durationSec) // 2 crossings per cycle
        XCTAssertEqual(estimatedFreq, 1000, accuracy: 100, "Recovered tone should be near 1 kHz")
    }

    /// Verify de-emphasis attenuates high frequencies relative to low.
    func testDeemphasisAttenuatesHighFrequencies() {
        let sampleRate: Float = 48_000
        let deviation: Float = 5_000
        let count = 9600 // 200 ms

        // Demod with de-emphasis enabled (75 us)
        let demodDE = FMDemodulator(sampleRate: sampleRate, deviation: deviation, deemphasisUs: 75)
        // Demod without de-emphasis
        let demodFlat = FMDemodulator(sampleRate: sampleRate, deviation: deviation, deemphasisUs: 0)

        // Generate FM signal modulated by a 4 kHz tone
        let modulatingFreq: Float = 4_000
        var real = [Float](repeating: 0, count: count)
        var imag = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Float(i) / sampleRate
            let phi = -(deviation / modulatingFreq) * cosf(2.0 * Float.pi * modulatingFreq * t)
            real[i] = cosf(phi)
            imag[i] = sinf(phi)
        }

        let outputDE = demodDE.demodulate(real: real, imag: imag)
        let outputFlat = demodFlat.demodulate(real: real, imag: imag)

        // Compare RMS of settled portion
        let tail = count / 2
        let rmsDE = sqrtf(Array(outputDE.suffix(tail)).reduce(0) { $0 + $1 * $1 } / Float(tail))
        let rmsFlat = sqrtf(Array(outputFlat.suffix(tail)).reduce(0) { $0 + $1 * $1 } / Float(tail))

        // 4 kHz is well above the 2122 Hz de-emphasis corner, so expect significant attenuation.
        XCTAssertLessThan(
            rmsDE, rmsFlat * 0.8,
            "De-emphasis should attenuate 4 kHz tone by at least 2 dB vs flat"
        )
    }

    /// Block demod produces the same count as input.
    func testDemodOutputCountMatchesInput() {
        let demod = FMDemodulator(sampleRate: 48_000, deviation: 5_000)
        let count = 1024
        let real = [Float](repeating: 0.5, count: count)
        let imag = [Float](repeating: 0.5, count: count)

        let output = demod.demodulate(real: real, imag: imag)
        XCTAssertEqual(output.count, count, "Output count must equal input count")
    }

    /// Empty input returns empty output.
    func testDemodEmptyInput() {
        let demod = FMDemodulator(sampleRate: 48_000, deviation: 5_000)
        let output = demod.demodulate(real: [], imag: [])
        XCTAssertTrue(output.isEmpty)
    }
}

// MARK: - Resampler block processing tests

final class ResamplerBlockTests: XCTestCase {

    /// Verify resampler produces correct sample count for a known ratio.
    func testResamplerOutputCount() {
        let resampler = Resampler(inputRate: 50_000, outputRate: 48_000)
        let inputCount = 5000 // 100 ms at 50 kHz
        let input = [Float](repeating: 0.5, count: inputCount)
        let output = resampler.process(input)

        // Expected: 5000 * (48000/50000) = 4800, plus or minus filter delay.
        XCTAssertEqual(Double(output.count), 4800, accuracy: 20,
                       "Resampler should produce about 4800 samples from 5000 at 50k to 48k")
    }

    /// Verify a sine wave survives resampling without excessive distortion.
    func testResamplerPreservesSineWave() {
        let inputRate: Double = 50_000
        let outputRate: Double = 48_000
        let resampler = Resampler(inputRate: inputRate, outputRate: outputRate)

        let toneFreq: Float = 1_000
        let inputCount = 10_000 // 200 ms
        let input: [Float] = (0..<inputCount).map { i in
            sinf(2.0 * .pi * toneFreq * Float(i) / Float(inputRate))
        }

        let output = resampler.process(input)

        // Discard first 10% for filter settling
        let settled = Array(output.dropFirst(output.count / 10))

        // Measure RMS. A sine wave has RMS around 0.707.
        let rms = sqrtf(settled.reduce(0) { $0 + $1 * $1 } / Float(settled.count))
        XCTAssertGreaterThan(rms, 0.5, "Sine wave should survive resampling with > -3 dB")
        XCTAssertLessThan(rms, 0.85, "Resampled sine RMS should be reasonable (< +1.5 dB)")
    }

    /// Verify dynamic ratio adjustment works.
    func testResamplerDynamicRatioAdjustment() {
        let resampler = Resampler(inputRate: 48_762, outputRate: 48_000)
        let input = [Float](repeating: 0.5, count: 2000)

        let output1 = resampler.process(input)

        // Adjust ratio slightly (simulating drift compensation)
        resampler.currentRatio = 48_000.0 / 48_762.0 * 1.0001
        let output2 = resampler.process(input)

        // Both should produce valid output, count may differ by 1-2
        XCTAssertGreaterThan(output1.count, 0)
        XCTAssertGreaterThan(output2.count, 0)
        XCTAssertEqual(Double(output1.count), Double(output2.count), accuracy: 5,
                       "Small ratio change should not drastically change output count")
    }

    /// Empty input returns empty output.
    func testResamplerEmptyInput() {
        let resampler = Resampler(inputRate: 50_000, outputRate: 48_000)
        let output = resampler.process([])
        XCTAssertTrue(output.isEmpty)
    }
}

// MARK: - Soft limiter tests

final class SoftLimiterTests: XCTestCase {

    /// Verify vDSP_vclip limits samples to +/-0.95 (matches DSPPipeline implementation).
    func testClipLimitsSamplesToRange() {
        var samples: [Float] = [-1.5, -1.0, -0.95, -0.5, 0.0, 0.5, 0.95, 1.0, 1.5]
        var lo: Float = -0.95
        var hi: Float =  0.95

        vDSP_vclip(samples, 1, &lo, &hi, &samples, 1, vDSP_Length(samples.count))

        XCTAssertEqual(samples[0], -0.95, accuracy: 0.0001, "Below-range sample should be clipped to -0.95")
        XCTAssertEqual(samples[1], -0.95, accuracy: 0.0001, "-1.0 should be clipped to -0.95")
        XCTAssertEqual(samples[2], -0.95, accuracy: 0.0001, "-0.95 should remain -0.95")
        XCTAssertEqual(samples[3], -0.5, accuracy: 0.0001, "In-range sample should be unchanged")
        XCTAssertEqual(samples[4],  0.0, accuracy: 0.0001, "Zero should be unchanged")
        XCTAssertEqual(samples[5],  0.5, accuracy: 0.0001, "In-range sample should be unchanged")
        XCTAssertEqual(samples[6],  0.95, accuracy: 0.0001, "0.95 should remain 0.95")
        XCTAssertEqual(samples[7],  0.95, accuracy: 0.0001, "1.0 should be clipped to 0.95")
        XCTAssertEqual(samples[8],  0.95, accuracy: 0.0001, "Above-range sample should be clipped to 0.95")
    }

    /// Verify a strong FM signal peak does not exceed +/-0.95 after limiting.
    func testLimiterClampsFMPeaks() {
        // Simulate strong FM demod output that exceeds +/-1.0.
        let count = 1000
        var samples: [Float] = (0..<count).map { i in
            1.2 * sinf(2.0 * .pi * 1000 * Float(i) / 48000)
        }

        var lo: Float = -0.95
        var hi: Float =  0.95
        vDSP_vclip(samples, 1, &lo, &hi, &samples, 1, vDSP_Length(count))

        let maxVal = samples.max()!
        let minVal = samples.min()!

        XCTAssertLessThanOrEqual(maxVal, 0.95, "Max after limiting should be <= 0.95")
        XCTAssertGreaterThanOrEqual(minVal, -0.95, "Min after limiting should be >= -0.95")
    }

    /// Verify signal within range is unmodified by the limiter.
    func testLimiterDoesNotAlterQuietSignal() {
        let count = 512
        let original: [Float] = (0..<count).map { i in
            0.3 * sinf(2.0 * .pi * 1000 * Float(i) / 48000)
        }
        var samples = original

        var lo: Float = -0.95
        var hi: Float =  0.95
        vDSP_vclip(samples, 1, &lo, &hi, &samples, 1, vDSP_Length(count))

        for i in 0..<count {
            XCTAssertEqual(samples[i], original[i], accuracy: 1e-6,
                           "Sample \(i) should be unmodified when within +/-0.95")
        }
    }
}

// MARK: - End-to-end NFM pipeline integration test

final class NFMPipelineIntegrationTests: XCTestCase {

    /// Simulate the full NFM path at 2.4 MSPS: channel filter, demod, resample.
    /// Feed a clean FM signal and verify the output is a recognizable tone
    /// (not aliased garbage).
    func testFullNFMPathAt2_4MSPS() {
        let sampleRate = 2_400_000
        let bandwidth = 12_500
        let deviation: Float = 5_000
        let modulatingFreq: Float = 1_000
        let design = ChannelFilterDesigner.make(
            inputSampleRate: sampleRate,
            bandwidthHz: bandwidth,
            intermediateTargetHz: 48_000
        )
        let intermediateRate = Float(design.intermediateRate)

        let filterI = FIRFilter(
            cutoffNormalized: design.normalizedCutoff,
            numTaps: design.tapCount,
            decimationFactor: design.decimationFactor
        )
        let filterQ = FIRFilter(
            cutoffNormalized: design.normalizedCutoff,
            numTaps: design.tapCount,
            decimationFactor: design.decimationFactor
        )

        let demod = FMDemodulator(sampleRate: intermediateRate, deviation: deviation, deemphasisUs: 0)
        let resampler = Resampler(inputRate: Double(intermediateRate), outputRate: 48_000)

        // Generate 50 ms of FM-modulated IQ at 2.4 MSPS
        let blockSize = sampleRate / 20 // 120,000 samples
        var real = [Float](repeating: 0, count: blockSize)
        var imag = [Float](repeating: 0, count: blockSize)

        for i in 0..<blockSize {
            let t = Float(i) / Float(sampleRate)
            let phi = -(deviation / modulatingFreq) * cosf(2.0 * Float.pi * modulatingFreq * t)
            real[i] = cosf(phi)
            imag[i] = sinf(phi)
        }

        // Process: filter, demod, resample.
        // Run multiple blocks to let filters settle
        var audioOutput = [Float]()
        let chunkSize = 24_000 // 10 ms at 2.4 MSPS
        for chunkStart in stride(from: 0, to: blockSize, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, blockSize)
            let realChunk = Array(real[chunkStart..<chunkEnd])
            let imagChunk = Array(imag[chunkStart..<chunkEnd])

            let filteredI = filterI.process(realChunk)
            let filteredQ = filterQ.process(imagChunk)

            guard !filteredI.isEmpty else { continue }

            let audio = demod.demodulate(real: filteredI, imag: filteredQ)
            let resampled = resampler.process(audio)
            audioOutput.append(contentsOf: resampled)
        }

        XCTAssertGreaterThan(audioOutput.count, 1000, "Should produce substantial audio output")

        // Analyze the last 50% of output (after settling)
        let settled = Array(audioOutput.suffix(audioOutput.count / 2))

        // Check that there IS a signal (not silence from over-filtering)
        let rms = sqrtf(settled.reduce(0) { $0 + $1 * $1 } / Float(settled.count))
        XCTAssertGreaterThan(rms, 0.05, "Output should contain audible signal, not silence")

        // Check zero crossings to verify we recovered about 1 kHz.
        var crossings = 0
        for i in 1..<settled.count {
            if (settled[i - 1] >= 0 && settled[i] < 0) || (settled[i - 1] < 0 && settled[i] >= 0) {
                crossings += 1
            }
        }
        let durationSec = Double(settled.count) / 48_000.0
        let estimatedFreq = Double(crossings) / (2.0 * durationSec)
        XCTAssertEqual(estimatedFreq, 1000, accuracy: 150,
                       "Full NFM pipeline at 2.4 MSPS should recover 1 kHz modulating tone")

        // Verify the synthetic path does not introduce runaway gain.
        let maxAbs = settled.map { abs($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(maxAbs, 1.0,
                                 "Output should stay within full-scale audio range")
    }
}
