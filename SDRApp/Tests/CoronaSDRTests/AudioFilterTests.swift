import XCTest
import SDRCoreDSP
import SDRModels
import RTLTCPClientKit
import AudioEngineKit

final class AudioToneFilterTests: XCTestCase {

    // MARK: - Bypass when disabled

    func testBothFiltersOffPassesAudioUnchanged() {
        let filter = AudioToneFilter(sampleRate: 48_000)
        let input: [Float] = [0.5, -0.3, 0.8, -0.1, 0.0, 0.6, -0.7, 0.2]
        var samples = input

        samples.withUnsafeMutableBufferPointer { ptr in
            filter.processInPlace(ptr, count: ptr.count)
        }

        // Both cutoffs are 0 (default) → early return, samples untouched.
        XCTAssertEqual(samples, input)
    }

    // MARK: - High-pass filter

    func testHighPassAttenuatesDC() {
        let filter = AudioToneFilter(sampleRate: 48_000)
        filter.setHighPassCutoff(300)

        // Feed a DC signal (constant value) — HP should suppress it toward 0.
        var samples = [Float](repeating: 1.0, count: 4800)
        samples.withUnsafeMutableBufferPointer { ptr in
            filter.processInPlace(ptr, count: ptr.count)
        }

        // After settling, output should be near zero for DC input.
        let tail = Array(samples.suffix(100))
        let avgTail = tail.reduce(0, +) / Float(tail.count)
        XCTAssertEqual(avgTail, 0.0, accuracy: 0.01, "HP filter should suppress DC to near zero")
    }

    func testHighPassPassesHighFrequency() {
        let sampleRate: Float = 48_000
        let filter = AudioToneFilter(sampleRate: sampleRate)
        filter.setHighPassCutoff(300)

        // Feed a 2 kHz sine wave — well above the cutoff, should pass.
        let count = 4800
        var samples = (0..<count).map { i in
            sinf(2.0 * .pi * 2000.0 * Float(i) / sampleRate)
        }

        samples.withUnsafeMutableBufferPointer { ptr in
            filter.processInPlace(ptr, count: ptr.count)
        }

        // Measure RMS of last 50% (after settling).
        let tail = Array(samples.suffix(count / 2))
        let rms = sqrtf(tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count))

        // Sine RMS ≈ 0.707. With 4th-order Butterworth at 300 Hz, 2 kHz should pass
        // with negligible attenuation.
        XCTAssertGreaterThan(rms, 0.6, "2 kHz signal should pass through 300 Hz HP with minimal loss")
    }

    // MARK: - Low-pass filter

    func testLowPassPassesDC() {
        let filter = AudioToneFilter(sampleRate: 48_000)
        filter.setLowPassCutoff(3000)

        // DC signal should pass through LP unchanged.
        var samples = [Float](repeating: 0.5, count: 4800)
        samples.withUnsafeMutableBufferPointer { ptr in
            filter.processInPlace(ptr, count: ptr.count)
        }

        let tail = Array(samples.suffix(100))
        let avgTail = tail.reduce(0, +) / Float(tail.count)
        XCTAssertEqual(avgTail, 0.5, accuracy: 0.01, "LP filter should pass DC")
    }

    func testLowPassAttenuatesHighFrequency() {
        let sampleRate: Float = 48_000
        let filter = AudioToneFilter(sampleRate: sampleRate)
        filter.setLowPassCutoff(3000)

        // Feed a 15 kHz sine wave — well above the cutoff, should be heavily attenuated.
        let count = 4800
        var samples = (0..<count).map { i in
            sinf(2.0 * .pi * 15000.0 * Float(i) / sampleRate)
        }

        samples.withUnsafeMutableBufferPointer { ptr in
            filter.processInPlace(ptr, count: ptr.count)
        }

        let tail = Array(samples.suffix(count / 2))
        let rms = sqrtf(tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count))

        // 15 kHz is ~2.3 octaves above 3 kHz cutoff.
        // 4th-order Butterworth: -24 dB/oct → ~-55 dB attenuation.
        // RMS of input sine ≈ 0.707, so output RMS should be < 0.01
        XCTAssertLessThan(rms, 0.02, "15 kHz should be heavily attenuated by 3 kHz LP")
    }

    // MARK: - Rolloff steepness (verifies 4th-order, not 1st-order)

    func testHighPassRolloffIsSteep() {
        let sampleRate: Float = 48_000
        let filter = AudioToneFilter(sampleRate: sampleRate)
        filter.setHighPassCutoff(1000)

        // Feed 250 Hz sine — 2 octaves below 1 kHz cutoff.
        let count = 9600 // 200ms for settling
        var samples = (0..<count).map { i in
            sinf(2.0 * .pi * 250.0 * Float(i) / sampleRate)
        }

        samples.withUnsafeMutableBufferPointer { ptr in
            filter.processInPlace(ptr, count: ptr.count)
        }

        let tail = Array(samples.suffix(count / 2))
        let rms = sqrtf(tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count))

        // 2 octaves below cutoff with 4th-order: -48 dB → RMS < 0.003
        // With old 1st-order: -12 dB → RMS ≈ 0.18
        // This test FAILS with the old 1st-order filter, proving the upgrade works.
        XCTAssertLessThan(rms, 0.01, "250 Hz should be attenuated >40 dB by 1 kHz 4th-order HP")
    }

    func testLowPassRolloffIsSteep() {
        let sampleRate: Float = 48_000
        let filter = AudioToneFilter(sampleRate: sampleRate)
        filter.setLowPassCutoff(1000)

        // Feed 4 kHz sine — 2 octaves above 1 kHz cutoff.
        let count = 9600
        var samples = (0..<count).map { i in
            sinf(2.0 * .pi * 4000.0 * Float(i) / sampleRate)
        }

        samples.withUnsafeMutableBufferPointer { ptr in
            filter.processInPlace(ptr, count: ptr.count)
        }

        let tail = Array(samples.suffix(count / 2))
        let rms = sqrtf(tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count))

        XCTAssertLessThan(rms, 0.01, "4 kHz should be attenuated >40 dB by 1 kHz 4th-order LP")
    }

    // MARK: - Combined bandpass

    func testBandpassPassesVoiceRange() {
        let sampleRate: Float = 48_000
        let filter = AudioToneFilter(sampleRate: sampleRate)
        filter.setHighPassCutoff(300)
        filter.setLowPassCutoff(3400)

        // Feed 1 kHz sine — center of voice band.
        let count = 4800
        var samples = (0..<count).map { i in
            sinf(2.0 * .pi * 1000.0 * Float(i) / sampleRate)
        }

        samples.withUnsafeMutableBufferPointer { ptr in
            filter.processInPlace(ptr, count: ptr.count)
        }

        let tail = Array(samples.suffix(count / 2))
        let rms = sqrtf(tail.reduce(0) { $0 + $1 * $1 } / Float(tail.count))

        XCTAssertGreaterThan(rms, 0.6, "1 kHz should pass through 300–3400 Hz bandpass")
    }

    // MARK: - Reset

    func testResetClearsFilterState() {
        let filter = AudioToneFilter(sampleRate: 48_000)
        filter.setHighPassCutoff(300)

        // Feed some signal to build up state.
        var warmup = [Float](repeating: 1.0, count: 480)
        warmup.withUnsafeMutableBufferPointer { ptr in
            filter.processInPlace(ptr, count: ptr.count)
        }

        filter.reset()

        // After reset, processing a zero block should produce zeros.
        var silence = [Float](repeating: 0.0, count: 480)
        silence.withUnsafeMutableBufferPointer { ptr in
            filter.processInPlace(ptr, count: ptr.count)
        }

        let maxAbs = silence.map { abs($0) }.max() ?? 0
        XCTAssertEqual(maxAbs, 0.0, accuracy: 1e-6, "After reset, zero input should produce zero output")
    }

    // MARK: - Cutoff readback

    func testCutoffReadback() {
        let filter = AudioToneFilter(sampleRate: 48_000)
        XCTAssertEqual(filter.currentHighPassCutoffHz(), 0)
        XCTAssertEqual(filter.currentLowPassCutoffHz(), 0)

        filter.setHighPassCutoff(500)
        filter.setLowPassCutoff(4000)
        XCTAssertEqual(filter.currentHighPassCutoffHz(), 500)
        XCTAssertEqual(filter.currentLowPassCutoffHz(), 4000)
    }
}

// MARK: - Noise Blanker Tests

final class NoiseBlankerTests: XCTestCase {

    func testDisabledWhenThresholdIsZero() {
        let blanker = NoiseBlanker()
        blanker.threshold = 0

        let input: [Float] = [0.1, 0.2, 5.0, 0.1, 0.15]
        var samples = input
        blanker.process(&samples)

        // Threshold 0 → no processing → output identical.
        XCTAssertEqual(samples, input)
    }

    func testBlanksSpikeAboveThreshold() {
        let blanker = NoiseBlanker()
        blanker.threshold = 0.5

        // Build up a stable RMS first with a mild signal.
        var warmup = [Float](repeating: 0.1, count: 2000)
        blanker.process(&warmup)

        // Now inject a spike.
        var block: [Float] = [0.1, 0.1, 0.1, 5.0, 0.1, 0.1]
        blanker.process(&block)

        // The spike at index 3 should be replaced by interpolation of neighbors.
        // Neighbors are both 0.1, so interpolated value = 0.1.
        XCTAssertEqual(block[3], 0.1, accuracy: 0.05, "Spike should be blanked to neighbor average")

        // Non-spike samples should be unchanged.
        XCTAssertEqual(block[0], 0.1, accuracy: 0.001)
        XCTAssertEqual(block[4], 0.1, accuracy: 0.001)
    }

    func testDoesNotBlankNormalSignal() {
        let blanker = NoiseBlanker()
        blanker.threshold = 0.5

        // Let RMS stabilize on signal level first.
        var warmup = [Float](repeating: 0.3, count: 2000)
        blanker.process(&warmup)

        // Slightly varying signal — no spikes, just normal deviation.
        var block: [Float] = [0.3, 0.31, 0.29, 0.32, 0.28]
        let original = block
        blanker.process(&block)

        // No spikes → samples should pass through unchanged.
        for i in 0..<block.count {
            XCTAssertEqual(block[i], original[i], accuracy: 0.001,
                           "Sample \(i) should not be modified when no spikes present")
        }
    }

    func testFirstBlockNeverBlanks() {
        let blanker = NoiseBlanker()
        blanker.threshold = 0.5

        // With no prior signal, RMS=0 so spikeThreshold=0 → no blanking.
        // This prevents false positives at startup.
        var block: [Float] = [0.5, 1.0, 0.3]
        let original = block
        blanker.process(&block)

        for i in 0..<block.count {
            XCTAssertEqual(block[i], original[i], accuracy: 0.001,
                           "First block should never blank (RMS not yet established)")
        }
    }

    func testResetRestoresInitialState() {
        let blanker = NoiseBlanker()
        blanker.threshold = 0.5

        var warmup = [Float](repeating: 0.5, count: 5000)
        blanker.process(&warmup)

        blanker.reset()

        // After reset, RMS is 0 → no blanking on first block.
        var block: [Float] = [0.5, 0.5, 0.5]
        blanker.process(&block)
        XCTAssertEqual(block[0], 0.5, accuracy: 0.001)
    }
}

// MARK: - AGC Tests

final class AudioAGCTests: XCTestCase {

    func testAGCNormalizesLoudSignal() {
        let agc = AGC(targetLevel: 0.3, attackRate: 0.002, decayRate: 0.00005)

        // Feed a loud signal.
        var samples = [Float](repeating: 0.9, count: 4800)
        agc.process(&samples)

        // After settling, output level should approach target (0.3).
        let tail = Array(samples.suffix(100))
        let avg = tail.reduce(0, +) / Float(tail.count)
        XCTAssertEqual(avg, 0.3, accuracy: 0.1, "AGC should bring 0.9 signal down toward 0.3")
    }

    func testAGCBoostsQuietSignal() {
        let agc = AGC(targetLevel: 0.3, attackRate: 0.002, decayRate: 0.00005)

        // Feed a quiet signal for a while to let gain ramp up.
        var samples = [Float](repeating: 0.01, count: 48000)
        agc.process(&samples)

        let tail = Array(samples.suffix(100))
        let avg = tail.reduce(0, +) / Float(tail.count)
        // Gain should have increased, output should be above input level.
        XCTAssertGreaterThan(avg, 0.01, "AGC should boost quiet signal above input level")
    }

    func testAGCDisabledPassesThrough() {
        let agc = AGC(targetLevel: 0.3, attackRate: 0.002, decayRate: 0.00005)
        agc.isEnabled = false

        let input: [Float] = [0.5, -0.3, 0.8]
        var samples = input
        agc.process(&samples)

        XCTAssertEqual(samples, input, "Disabled AGC should not modify samples")
    }

    func testAGCResetRestoresUnityGain() {
        let agc = AGC(targetLevel: 0.3, attackRate: 0.002, decayRate: 0.00005)

        // Drive gain down with loud signal.
        var loud = [Float](repeating: 0.9, count: 4800)
        agc.process(&loud)

        agc.reset()

        // After reset, first sample should be multiplied by unity gain (1.0).
        var single: [Float] = [0.5]
        agc.process(&single)
        XCTAssertEqual(single[0], 0.5, accuracy: 0.05, "After reset, gain should be near 1.0")
    }
}

// MARK: - Settings Persistence Tests

final class NoiseReductionSettingsTests: XCTestCase {

    func testSettingsStorePersistsNoiseBlankerAndAGC() {
        let suiteName = "NoiseReductionSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = SettingsStore(defaults: defaults)
        // Verify defaults.
        XCTAssertEqual(initial.noiseBlankerThreshold, 0)
        XCTAssertFalse(initial.audioAgcEnabled)

        // Set values.
        initial.noiseBlankerThreshold = 0.65
        initial.audioAgcEnabled = true

        // Reload and verify persistence.
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.noiseBlankerThreshold, 0.65, accuracy: 0.001)
        XCTAssertTrue(reloaded.audioAgcEnabled)
    }

    func testNoiseBlankerThresholdDefaultIsZero() {
        let suiteName = "NoiseBlankerDefault.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.noiseBlankerThreshold, 0, "Default noise blanker threshold should be 0 (off)")
    }

    func testAudioAgcDefaultIsDisabled() {
        let suiteName = "AudioAgcDefault.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.audioAgcEnabled, "Default audio AGC should be disabled")
    }

    func testSettingsStoreTogglesAGCOnAndOff() {
        let suiteName = "AGCToggle.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        store.audioAgcEnabled = true
        XCTAssertTrue(SettingsStore(defaults: defaults).audioAgcEnabled)

        store.audioAgcEnabled = false
        XCTAssertFalse(SettingsStore(defaults: defaults).audioAgcEnabled)
    }

    func testNoiseBlankerThresholdRoundTripsMultipleValues() {
        let suiteName = "NBRoundTrip.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)

        for value: Float in [0.0, 0.05, 0.25, 0.5, 0.75, 1.0] {
            store.noiseBlankerThreshold = value
            let reloaded = SettingsStore(defaults: defaults)
            XCTAssertEqual(reloaded.noiseBlankerThreshold, value, accuracy: 0.001,
                           "Threshold \(value) should round-trip through UserDefaults")
        }
    }
}

// MARK: - DSPPipeline Integration Tests

final class DSPPipelineIntegrationTests: XCTestCase {

    private func makePipeline() -> DSPPipeline {
        let iqBuffer = IQRingBuffer(capacity: 65536)
        let audioBuffer = AudioRingBuffer(capacity: 48000)
        return DSPPipeline(iqBuffer: iqBuffer, audioBuffer: audioBuffer, sampleRate: 1_024_000)
    }

    // MARK: - Noise Blanker flag gating

    func testNoiseBlankerDisabledByDefault() {
        let pipeline = makePipeline()
        XCTAssertFalse(pipeline.noiseBlankerEnabled, "Noise blanker should be disabled by default")
    }

    func testSetNoiseBlankerThresholdEnablesBlanker() {
        let pipeline = makePipeline()
        pipeline.setNoiseBlankerThreshold(0.5)
        XCTAssertTrue(pipeline.noiseBlankerEnabled, "Setting threshold > 0 should enable noise blanker")
    }

    func testSetNoiseBlankerThresholdToZeroDisablesBlanker() {
        let pipeline = makePipeline()
        pipeline.setNoiseBlankerThreshold(0.5)
        XCTAssertTrue(pipeline.noiseBlankerEnabled)

        pipeline.setNoiseBlankerThreshold(0)
        XCTAssertFalse(pipeline.noiseBlankerEnabled, "Setting threshold = 0 should disable noise blanker")
    }

    func testNoiseBlankerEnabledDirectSetter() {
        let pipeline = makePipeline()
        pipeline.noiseBlankerEnabled = true
        XCTAssertTrue(pipeline.noiseBlankerEnabled)

        pipeline.noiseBlankerEnabled = false
        XCTAssertFalse(pipeline.noiseBlankerEnabled)
    }

    // MARK: - Audio AGC flag gating

    func testAudioAgcDisabledByDefault() {
        let pipeline = makePipeline()
        XCTAssertFalse(pipeline.audioAgcEnabled, "Audio AGC should be disabled by default")
    }

    func testAudioAgcEnableDisable() {
        let pipeline = makePipeline()
        pipeline.audioAgcEnabled = true
        XCTAssertTrue(pipeline.audioAgcEnabled)

        pipeline.audioAgcEnabled = false
        XCTAssertFalse(pipeline.audioAgcEnabled)
    }

    // MARK: - Reset

    func testResetStateDoesNotCrash() {
        let pipeline = makePipeline()
        pipeline.setNoiseBlankerThreshold(0.5)
        pipeline.audioAgcEnabled = true
        // Should not crash — exercises full resetStateLocked path.
        pipeline.resetState()
    }

    func testResetPreservesFlags() {
        let pipeline = makePipeline()
        pipeline.setNoiseBlankerThreshold(0.5)
        pipeline.audioAgcEnabled = true
        pipeline.resetState()

        // Reset clears internal filter state but should not change the enabled flags.
        XCTAssertTrue(pipeline.noiseBlankerEnabled, "Reset should preserve noise blanker enabled state")
        XCTAssertTrue(pipeline.audioAgcEnabled, "Reset should preserve AGC enabled state")
    }

    // MARK: - Threshold boundary values

    func testNoiseBlankerThresholdBoundaryValues() {
        let pipeline = makePipeline()

        // Very small threshold → enabled
        pipeline.setNoiseBlankerThreshold(0.001)
        XCTAssertTrue(pipeline.noiseBlankerEnabled, "Even tiny threshold > 0 should enable blanker")

        // Maximum threshold → enabled
        pipeline.setNoiseBlankerThreshold(1.0)
        XCTAssertTrue(pipeline.noiseBlankerEnabled, "Maximum threshold should keep blanker enabled")

        // Back to zero → disabled
        pipeline.setNoiseBlankerThreshold(0.0)
        XCTAssertFalse(pipeline.noiseBlankerEnabled)
    }
}

// MARK: - RadioViewModel Forwarding Tests
// NOTE: RadioViewModel creates Metal pipelines, audio engines, and network
// connections in init(). We test forwarding via DSPPipeline directly (above)
// since the forwarding methods are trivial two-line pass-throughs.

// MARK: - AGC Edge Case Tests

final class AGCEdgeCaseTests: XCTestCase {

    func testAGCDoesNotExceedMaxGain() {
        let agc = AGC(targetLevel: 0.3, attackRate: 0.002, decayRate: 0.00005)
        agc.maxGain = 50.0

        // Feed silence to ramp gain up.
        var silence = [Float](repeating: 0.0001, count: 96000)
        agc.process(&silence)

        // Now feed a single sample — output should not exceed maxGain × input.
        var single: [Float] = [0.01]
        agc.process(&single)
        XCTAssertLessThanOrEqual(abs(single[0]), 0.01 * 50.0 + 0.01,
                                 "AGC output should respect maxGain limit")
    }

    func testAGCDoesNotGoBelowMinGain() {
        let agc = AGC(targetLevel: 0.3, attackRate: 0.002, decayRate: 0.00005)
        agc.minGain = 0.01

        // Feed extremely loud signal to drive gain down.
        var loud = [Float](repeating: 100.0, count: 48000)
        agc.process(&loud)

        // Gain should not drop below minGain.
        var single: [Float] = [1.0]
        agc.process(&single)
        XCTAssertGreaterThanOrEqual(abs(single[0]), 0.01,
                                    "AGC output should respect minGain limit")
    }

    func testAGCHandlesEmptyArray() {
        let agc = AGC(targetLevel: 0.3, attackRate: 0.002, decayRate: 0.00005)
        var empty: [Float] = []
        agc.process(&empty) // Should not crash
        XCTAssertTrue(empty.isEmpty)
    }

    func testFMAudioAGCParameters() {
        // Verify the FM-tuned AGC parameters are correctly set.
        let agc = AGC(targetLevel: 0.3, attackRate: 0.002, decayRate: 0.00005)
        XCTAssertEqual(agc.targetLevel, 0.3)
        XCTAssertEqual(agc.attackRate, 0.002)
        XCTAssertEqual(agc.decayRate, 0.00005)
    }
}

// MARK: - NoiseBlanker Edge Case Tests

final class NoiseBlankerEdgeCaseTests: XCTestCase {

    func testNoiseBlankerHandlesEmptyArray() {
        let blanker = NoiseBlanker()
        blanker.threshold = 0.5
        var empty: [Float] = []
        blanker.process(&empty) // Should not crash
        XCTAssertTrue(empty.isEmpty)
    }

    func testNoiseBlankerHandlesSingleSample() {
        let blanker = NoiseBlanker()
        blanker.threshold = 0.5

        // Warm up RMS.
        var warmup = [Float](repeating: 0.1, count: 2000)
        blanker.process(&warmup)

        // Single sample, no crash.
        var single: [Float] = [0.1]
        blanker.process(&single)
        XCTAssertEqual(single[0], 0.1, accuracy: 0.01)
    }

    func testNoiseBlankerSpikeAtBoundaries() {
        let blanker = NoiseBlanker()
        blanker.threshold = 0.5

        // Warm up RMS with low signal.
        var warmup = [Float](repeating: 0.1, count: 2000)
        blanker.process(&warmup)

        // Spike at first sample — only next neighbor available.
        var block: [Float] = [5.0, 0.1, 0.1]
        blanker.process(&block)
        // First sample spike: prev=0, next=0.1, interpolated=(0+0.1)/2=0.05
        XCTAssertLessThan(abs(block[0]), 0.2, "Spike at index 0 should be blanked")

        // Reset and warm up again.
        blanker.reset()
        var warmup2 = [Float](repeating: 0.1, count: 2000)
        blanker.process(&warmup2)

        // Spike at last sample — only prev neighbor available.
        var block2: [Float] = [0.1, 0.1, 5.0]
        blanker.process(&block2)
        // Last sample spike: prev=0.1, next=0, interpolated=(0.1+0)/2=0.05
        XCTAssertLessThan(abs(block2[2]), 0.2, "Spike at last index should be blanked")
    }

    func testNoiseBlankerThresholdMappingRange() {
        // At threshold=1.0 (least aggressive): spikeMultiplier = 3.0 + (1-1)*17 = 3.0
        // At threshold=0.01 (most aggressive): spikeMultiplier = 3.0 + (1-0.01)*17 = 19.83
        // Verify these extremes behave differently.
        let aggressiveBlanker = NoiseBlanker()
        aggressiveBlanker.threshold = 1.0 // least aggressive (needs 3× RMS)

        let gentleBlanker = NoiseBlanker()
        gentleBlanker.threshold = 0.01 // most aggressive (needs ~20× RMS)

        // Warm up both with same signal.
        var warmup1 = [Float](repeating: 0.1, count: 2000)
        var warmup2 = [Float](repeating: 0.1, count: 2000)
        aggressiveBlanker.process(&warmup1)
        gentleBlanker.process(&warmup2)

        // Moderate spike (4× typical level) — aggressive should blank, gentle should not.
        var block1: [Float] = [0.1, 0.1, 0.4, 0.1, 0.1]
        var block2: [Float] = [0.1, 0.1, 0.4, 0.1, 0.1]
        aggressiveBlanker.process(&block1)
        gentleBlanker.process(&block2)

        // With threshold=1.0, spikeMultiplier=3.0, spikeThreshold≈0.1*3=0.3
        // 0.4 > 0.3 → blanked
        XCTAssertNotEqual(block1[2], 0.4, accuracy: 0.05,
                          "Aggressive blanker should modify the moderate spike")

        // With threshold=0.01, spikeMultiplier≈19.83, spikeThreshold≈0.1*19.83=1.98
        // 0.4 < 1.98 → not blanked
        XCTAssertEqual(block2[2], 0.4, accuracy: 0.05,
                       "Gentle blanker should leave moderate spike unchanged")
    }

    func testNoiseBlankerRMSTracking() {
        let blanker = NoiseBlanker()
        blanker.threshold = 0.5

        // Feed increasing-level blocks to verify RMS adapts.
        var low = [Float](repeating: 0.01, count: 1000)
        blanker.process(&low)

        // After low signal, a moderately loud sample might spike.
        // Then feed a high-level block.
        var high = [Float](repeating: 0.5, count: 5000)
        blanker.process(&high)

        // Now same moderate level should not be blanked (RMS adapted up).
        var moderate: [Float] = [0.5, 0.5, 0.5]
        let original = moderate
        blanker.process(&moderate)
        for i in 0..<moderate.count {
            XCTAssertEqual(moderate[i], original[i], accuracy: 0.05,
                           "Signal at RMS level should not be blanked after RMS adapts")
        }
    }
}

// MARK: - DSPPipeline Sample Rate Switch Tests

final class DSPPipelineSampleRateTests: XCTestCase {

    private func makePipeline() -> DSPPipeline {
        let iqBuffer = IQRingBuffer(capacity: 65536)
        let audioBuffer = AudioRingBuffer(capacity: 48000)
        return DSPPipeline(iqBuffer: iqBuffer, audioBuffer: audioBuffer, sampleRate: 1_024_000)
    }

    func testSetSampleRateUpdatesSampleRate() {
        let pipeline = makePipeline()
        XCTAssertEqual(pipeline.sampleRate, 1_024_000)

        pipeline.setSampleRate(2_400_000)
        XCTAssertEqual(pipeline.sampleRate, 2_400_000)
    }

    func testSetSampleRateClampsMinimum() {
        let pipeline = makePipeline()
        pipeline.setSampleRate(100_000)
        XCTAssertEqual(pipeline.sampleRate, 250_000,
                       "Sample rate should be clamped to minimum 250kHz")
    }

    func testSetSameSampleRateIsNoOp() {
        let pipeline = makePipeline()
        pipeline.setSampleRate(1_024_000)
        // Should not crash or cause issues — guard prevents rebuild
        XCTAssertEqual(pipeline.sampleRate, 1_024_000)
    }

    func testRapidSampleRateSwitchDoesNotCrash() {
        let pipeline = makePipeline()
        // Simulate rapid profile switching
        let rates = [250_000, 1_024_000, 2_400_000, 768_000, 192_000,
                     2_400_000, 250_000, 1_024_000, 2_048_000, 250_000]
        for rate in rates {
            pipeline.setSampleRate(rate)
        }
        // Should not crash; final rate should stick.
        XCTAssertEqual(pipeline.sampleRate, 250_000)
    }

    func testSampleRateSwitchPreservesNoiseReductionFlags() {
        let pipeline = makePipeline()
        pipeline.setNoiseBlankerThreshold(0.5)
        pipeline.audioAgcEnabled = true

        pipeline.setSampleRate(2_400_000)

        XCTAssertTrue(pipeline.noiseBlankerEnabled,
                      "Noise blanker should remain enabled after sample rate change")
        XCTAssertTrue(pipeline.audioAgcEnabled,
                      "Audio AGC should remain enabled after sample rate change")
    }

    func testSampleRateSwitchResetsState() {
        let pipeline = makePipeline()
        // setSampleRate calls resetStateLocked internally — verify it doesn't crash
        // by switching between very different rates.
        pipeline.setSampleRate(192_000)
        pipeline.resetState()
        pipeline.setSampleRate(2_400_000)
        pipeline.resetState()
        XCTAssertEqual(pipeline.sampleRate, 2_400_000)
    }
}

// MARK: - Settle Window Tests

final class SettleWindowTests: XCTestCase {

    func testSettleWindowUsesMaxRate() {
        // Verify that after setSampleRate, the connection properly handles
        // the transition by testing the IQ buffer behavior.
        let iqBuffer = IQRingBuffer(capacity: 65536)
        let conn = RTLTCPConnection(iqBuffer: iqBuffer)

        // Not connected, so setSampleRate just sets internal state.
        // We verify the settle window doesn't crash and the buffer is flushed.
        let testData = Data(repeating: 128, count: 4096)
        iqBuffer.write(testData)
        XCTAssertGreaterThan(iqBuffer.availableForReading, 0)

        // Calling setSampleRate should flush the IQ buffer via beginSettleWindow.
        conn.setSampleRate(2_400_000)
        XCTAssertEqual(iqBuffer.availableForReading, 0,
                       "IQ buffer should be flushed after sample rate change")
    }

    func testRapidSampleRateChangesOnConnection() {
        let iqBuffer = IQRingBuffer(capacity: 65536)
        let conn = RTLTCPConnection(iqBuffer: iqBuffer)

        // Rapid rate changes should not crash or leave inconsistent state.
        let rates = [250_000, 2_400_000, 1_024_000, 192_000, 768_000, 2_048_000]
        for rate in rates {
            conn.setSampleRate(rate)
        }
        // Should complete without crash.
    }
}

// MARK: - Profile Debounce Tests

final class ProfileDebounceTests: XCTestCase {

    func testDSPPipelineHandlesAllProfileRates() {
        // Verify that every standard profile rate creates a valid pipeline config.
        // Note: DSPPipeline init does NOT clamp — only setSampleRate clamps to 250kHz.
        // Rates below 250kHz are valid at init time (e.g., HF+ Low 192kHz).
        let profileRates = [192_000, 250_000, 768_000, 1_024_000, 2_048_000, 2_400_000]
        for rate in profileRates {
            let iqBuffer = IQRingBuffer(capacity: 65536)
            let audioBuffer = AudioRingBuffer(capacity: 48000)
            let pipeline = DSPPipeline(iqBuffer: iqBuffer, audioBuffer: audioBuffer, sampleRate: rate)
            XCTAssertEqual(pipeline.sampleRate, rate,
                           "Pipeline should accept rate \(rate) at init")
        }
    }

    func testDSPPipelineSwitchBetweenAllProfiles() {
        let iqBuffer = IQRingBuffer(capacity: 65536)
        let audioBuffer = AudioRingBuffer(capacity: 48000)
        let pipeline = DSPPipeline(iqBuffer: iqBuffer, audioBuffer: audioBuffer, sampleRate: 1_024_000)

        // Simulate switching through every profile pair.
        let rates = [192_000, 250_000, 768_000, 1_024_000, 2_048_000, 2_400_000]
        for from in rates {
            for to in rates where from != to {
                pipeline.setSampleRate(from)
                pipeline.setSampleRate(to)
                XCTAssertEqual(pipeline.sampleRate, max(250_000, to),
                               "Pipeline should handle \(from) → \(to) transition")
            }
        }
    }
}
