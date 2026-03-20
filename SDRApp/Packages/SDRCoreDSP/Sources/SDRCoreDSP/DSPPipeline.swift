import Foundation
import Accelerate
import SDRModels
import SDRSupport
import AudioEngineKit
import RTLTCPClientKit

/// Central DSP pipeline: reads IQ from ring buffer, processes, outputs audio and FFT frames.
/// Runs on a dedicated DSP thread — never on the audio callback or network thread.
public final class DSPPipeline: @unchecked Sendable {
    // Configuration
    private let pipelineLock = NSRecursiveLock()
    private let lifecycleLock = NSLock()
    private var _mode: DemodMode = .nfm
    private var _bandwidthHz: Int = 12_500
    private var _sampleRate: Int = 1_024_000
    private var _bfoOffsetHz: Float = 0
    private var _dcBlockEnabled = true
    private var shouldRun = false
    private var loopStopSignal: DispatchSemaphore?

    public var mode: DemodMode {
        get { withPipelineLock { _mode } }
        set {
            withPipelineLock {
                guard _mode != newValue else { return }
                _mode = newValue
                rebuildDemodChainLocked(preservingBandwidth: false)
            }
        }
    }

    public var bandwidthHz: Int {
        get { withPipelineLock { _bandwidthHz } }
        set {
            withPipelineLock {
                guard _bandwidthHz != newValue else { return }
                _bandwidthHz = newValue
                rebuildFiltersLocked()
            }
        }
    }

    public var sampleRate: Int { withPipelineLock { _sampleRate } }

    public var bfoOffsetHz: Float {
        get { withPipelineLock { _bfoOffsetHz } }
        set { withPipelineLock { _bfoOffsetHz = newValue } }
    }

    // DC blocking
    public var dcBlockEnabled: Bool {
        get { withPipelineLock { _dcBlockEnabled } }
        set { withPipelineLock { _dcBlockEnabled = newValue } }
    }

    // Components
    private let iqBuffer: IQRingBuffer
    private let audioBuffer: AudioRingBuffer
    private let complexBuf = ComplexBuffer(capacity: 65536)

    private let iqDcBlocker = IQDCBlocker()
    private let ncoMixer = NCOMixer()
    private var channelFilterI: FIRFilter
    private var channelFilterQ: FIRFilter
    private var demodulator: Demodulator = AMDemodulator()
    private let squelch = Squelch()
    private let noiseBlanker = NoiseBlanker()
    private let audioAGC = AGC(targetLevel: 0.3, attackRate: 0.002, decayRate: 0.00005)
    private var resampler: Resampler
    private var driftCompensator: DriftCompensator
    private var deemphasisUs: Float = 75
    // When deemphasis changes while stopped, defer demod rebuild until start().
    private var pendingDemodChainRebuild = false
    private let targetAudioFill: Double = 0.65
    private let audioToneFilter = AudioToneFilter(sampleRate: 48_000)
    private(set) var audioHighPassCutoffHz: Int = 0
    private(set) var audioLowPassCutoffHz: Int = 0
    private var _noiseBlankerEnabled: Bool = false
    private var _audioAgcEnabled: Bool = false

    // FFT output callback
    public var onFFTFrame: (([Float], Int) -> Void)? // (bins, fftSize)
    /// Maximum FFT frame rate delivered to UI/waterfall.
    /// Keeping this near UI FPS avoids wasted CPU work.
    public var fftFrameRate: Int = 15

    // Reused work buffers to avoid per-block allocations in the hot loop.
    private var realWork: [Float] = []
    private var imagWork: [Float] = []
    private var filteredIWork: [Float] = []
    private var filteredQWork: [Float] = []
    private var resampledWork: [Float] = []

    // Processing state
    private var dspThread: Thread?
    private let outputRate: Double = 48000
    private let maxAudioCutoffHz: Int = 20_000
    private let minAudioCutoffGapHz: Int = 150

    // Block size for processing (bytes). Adapted by sample-rate for smoother waterfall cadence.
    private let minBlockSizeBytes: Int = 4_096
    private let maxBlockSizeBytes: Int = 16_384
    private var blockSizeBytes: Int
    private let iqStarvationGraceSeconds: CFTimeInterval = 0.08

    public init(iqBuffer: IQRingBuffer, audioBuffer: AudioRingBuffer, sampleRate: Int = 1_024_000) {
        self.iqBuffer = iqBuffer
        self.audioBuffer = audioBuffer
        self._sampleRate = sampleRate
        self.blockSizeBytes = DSPPipeline.computeBlockSizeBytes(
            for: sampleRate,
            minBlockSizeBytes: minBlockSizeBytes,
            maxBlockSizeBytes: maxBlockSizeBytes
        )

        let cutoff = Float(12_500) / Float(sampleRate)
        let decimFactor = max(1, sampleRate / 48000)
        self.channelFilterI = FIRFilter(cutoffNormalized: cutoff * 2, numTaps: 63, decimationFactor: decimFactor)
        self.channelFilterQ = FIRFilter(cutoffNormalized: cutoff * 2, numTaps: 63, decimationFactor: decimFactor)

        let intermediateRate = Double(sampleRate) / Double(decimFactor)
        self.resampler = Resampler(inputRate: intermediateRate, outputRate: outputRate)
        self.driftCompensator = DriftCompensator(
            baseRatio: outputRate / intermediateRate,
            targetFill: targetAudioFill
        )

        rebuildDemodChain(preservingBandwidth: false)
    }

    // MARK: - Start / Stop

    public func start() {
        lifecycleLock.lock()
        if shouldRun {
            lifecycleLock.unlock()
            return
        }
        shouldRun = true
        withPipelineLock {
            if pendingDemodChainRebuild {
                rebuildDemodChainLocked(preservingBandwidth: true)
                resetStateLocked()
            }
        }
        let stopSignal = DispatchSemaphore(value: 0)
        loopStopSignal = stopSignal

        let thread = Thread { [weak self] in
            self?.dspLoop(stopSignal: stopSignal)
        }
        thread.name = "yo6say.coronasdr.dsp"
        thread.qualityOfService = .userInitiated
        thread.start()
        dspThread = thread
        lifecycleLock.unlock()

        SDRDebug.print("🎛️ DSP pipeline started: mode=\(mode.rawValue), sampleRate=\(sampleRate), bw=\(bandwidthHz)")
        SDRLogger.dsp.info("DSP pipeline started")
    }

    public func stop() {
        var stopSignal: DispatchSemaphore?
        var shouldWait = false

        lifecycleLock.lock()
        if shouldRun {
            shouldRun = false
            stopSignal = loopStopSignal
            shouldWait = dspThread != nil && Thread.current !== dspThread
        }
        lifecycleLock.unlock()

        if shouldWait {
            _ = stopSignal?.wait(timeout: .now() + .seconds(2))
        }

        lifecycleLock.lock()
        dspThread = nil
        loopStopSignal = nil
        lifecycleLock.unlock()
        SDRLogger.dsp.info("DSP pipeline stopped")
    }

    // MARK: - DSP Loop

    private func dspLoop(stopSignal: DispatchSemaphore) {
        defer { stopSignal.signal() }

        let rawBlock = UnsafeMutableRawBufferPointer.allocate(byteCount: maxBlockSizeBytes, alignment: 16)
        defer { rawBlock.deallocate() }

        var blockCount = 0
        var lastLogTime = CFAbsoluteTimeGetCurrent()
        var waitingForRefill = false
        var starvationSince: CFAbsoluteTime?

        while shouldContinueRunning() {
            let blockSize = withPipelineLock { blockSizeBytes }
            let iqRefillLowWaterBytes = blockSize * 2
            let iqRefillResumeBytes = blockSize * 8
            let available = iqBuffer.availableForReading

            if waitingForRefill {
                if available < iqRefillResumeBytes {
                    Thread.sleep(forTimeInterval: 0.002)
                    continue
                }
                waitingForRefill = false
                starvationSince = nil
            }

            if available < blockSize {
                if starvationSince == nil {
                    starvationSince = CFAbsoluteTimeGetCurrent()
                } else if available <= iqRefillLowWaterBytes,
                          let starvationSince,
                          CFAbsoluteTimeGetCurrent() - starvationSince >= iqStarvationGraceSeconds {
                    waitingForRefill = true
                }
                Thread.sleep(forTimeInterval: 0.0015)
                continue
            }
            starvationSince = nil

            // Read IQ data
            let bytesRead = iqBuffer.read(into: rawBlock, maxCount: blockSize)
            guard bytesRead > 0 else { continue }

            // Convert 8-bit IQ to complex float
            let sampleCount = ComplexBuffer.fromUInt8IQ(
                UnsafeRawBufferPointer(start: rawBlock.baseAddress, count: bytesRead),
                into: complexBuf
            )
            guard sampleCount > 0 else { continue }
            let processingStart = CFAbsoluteTimeGetCurrent()

            let iterationMetrics = withPipelineLock { () -> (filteredCount: Int, audioCount: Int, resampledCount: Int, fillLevel: Double, ratio: Double, modeRawValue: String, currentSampleRate: Int)? in
                if realWork.count != sampleCount {
                    realWork = [Float](repeating: 0, count: sampleCount)
                    imagWork = [Float](repeating: 0, count: sampleCount)
                }

                realWork.withUnsafeMutableBufferPointer { dst in
                    complexBuf.real.withUnsafeBufferPointer { src in
                        dst.baseAddress!.update(from: src.baseAddress!, count: sampleCount)
                    }
                }
                imagWork.withUnsafeMutableBufferPointer { dst in
                    complexBuf.imag.withUnsafeBufferPointer { src in
                        dst.baseAddress!.update(from: src.baseAddress!, count: sampleCount)
                    }
                }

                // DC blocker
                if _dcBlockEnabled {
                    iqDcBlocker.process(real: &realWork, imag: &imagWork)
                }

                // NCO mix (if needed for offset tuning or BFO)
                if _bfoOffsetHz != 0 {
                    ncoMixer.setFrequency(_bfoOffsetHz, sampleRate: Float(_sampleRate))
                    ncoMixer.mix(real: &realWork, imag: &imagWork, count: sampleCount)
                }

                // FFT (before channelization, on full bandwidth), rate-limited for display.
                let fftNow = CFAbsoluteTimeGetCurrent()
                if shouldEmitFFTFrame(now: fftNow) {
                    computeFFTLocked(real: realWork, imag: imagWork)
                }

                // Channel filter + decimate (allocation-aware)
                let filteredICount = channelFilterI.process(realWork, into: &filteredIWork)
                let filteredQCount = channelFilterQ.process(imagWork, into: &filteredQWork)
                if filteredICount != filteredQCount {
                    SDRDebug.print("⚠️ IQ channel length mismatch: I=\(filteredICount) Q=\(filteredQCount)")
                }

                let filteredCount = min(filteredICount, filteredQCount)
                guard filteredCount > 0 else { return nil }

                if filteredIWork.count > filteredCount {
                    filteredIWork.removeSubrange(filteredCount..<filteredIWork.count)
                }
                if filteredQWork.count > filteredCount {
                    filteredQWork.removeSubrange(filteredCount..<filteredQWork.count)
                }

                // Demodulate
                var audio = demodulator.demodulate(real: filteredIWork, imag: filteredQWork)

                // Noise blanker (impulse spike removal, before squelch)
                if _noiseBlankerEnabled {
                    noiseBlanker.process(&audio)
                }

                // Audio AGC (level normalization for FM voice)
                if _audioAgcEnabled {
                    audioAGC.process(&audio)
                }

                // Squelch
                if _mode.supportsSquelch {
                    squelch.process(&audio)
                }

                // Resample to 48kHz
                let currentFill = audioBuffer.fillLevel
                let adjustedRatio = driftCompensator.update(currentFill: currentFill)
                resampler.currentRatio = adjustedRatio
                let resampledCount = resampler.process(audio, into: &resampledWork)

                // Write to audio ring buffer
                if resampledCount > 0 {
                    resampledWork.withUnsafeMutableBufferPointer { samples in
                        audioToneFilter.processInPlace(samples, count: resampledCount)
                        _ = audioBuffer.write(UnsafeBufferPointer(start: samples.baseAddress!, count: resampledCount))
                    }
                }

                return (
                    filteredCount: filteredCount,
                    audioCount: audio.count,
                    resampledCount: resampledCount,
                    fillLevel: currentFill,
                    ratio: adjustedRatio,
                    modeRawValue: _mode.rawValue,
                    currentSampleRate: _sampleRate
                )
            }

            guard let iterationMetrics else { continue }

            // Periodic diagnostics (every ~2 sec)
            blockCount += 1
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastLogTime >= 2.0 {
                let bps = Double(blockCount * blockSize) / (now - lastLogTime)
                SDRDebug.print("🎛️ DSP: \(blockCount) blocks, \(String(format: "%.1f", bps/1024))KB/s, " +
                               "IQ→\(sampleCount) filt→\(iterationMetrics.filteredCount) demod→\(iterationMetrics.audioCount) resamp→\(iterationMetrics.resampledCount), " +
                               "audioFill=\(String(format: "%.1f%%", iterationMetrics.fillLevel*100)), ratio=\(String(format: "%.6f", iterationMetrics.ratio))")
                blockCount = 0
                lastLogTime = now
            }

            if lastDSPPerfReportTime == 0 || now - lastDSPPerfReportTime >= dspPerfReportInterval {
                let elapsedMs = (now - processingStart) * 1000
                PerformanceTrace.reportDuration(
                    name: .dspBlockProcessing,
                    durationMs: elapsedMs,
                    metadata: [
                        "mode": iterationMetrics.modeRawValue,
                        "sample_rate": String(iterationMetrics.currentSampleRate)
                    ]
                )
                lastDSPPerfReportTime = now
            }
        }
    }

    // MARK: - FFT

    private var fftSetup: vDSP_DFT_Setup?
    private var fftSize: Int = 2048
    private var fftWindow: [Float] = []
    private var fftInReal: [Float] = []
    private var fftInImag: [Float] = []
    private var fftOutReal: [Float] = []
    private var fftOutImag: [Float] = []
    private var fftPower: [Float] = []
    private var fftImagSq: [Float] = []
    private var fftShifted: [Float] = []
    private var lastFFTFrameTime: CFAbsoluteTime = 0
    private var lastDSPPerfReportTime: CFAbsoluteTime = 0
    private let dspPerfReportInterval: CFTimeInterval = 5.0

    public func setFFTSize(_ size: Int) {
        withPipelineLock {
            setFFTSizeLocked(size)
        }
    }

    /// Update FFT frame rate budget used by spectrum/waterfall pipeline.
    public func setFFTFrameRate(_ fps: Int) {
        withPipelineLock {
            fftFrameRate = max(1, min(60, fps))
        }
    }

    private func setFFTSizeLocked(_ size: Int) {
        guard size > 0 else { return }
        fftSize = size
        if let old = fftSetup { vDSP_DFT_DestroySetup(old) }
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD)
        fftWindow = [Float](repeating: 0, count: size)
        fftInReal = [Float](repeating: 0, count: size)
        fftInImag = [Float](repeating: 0, count: size)
        fftOutReal = [Float](repeating: 0, count: size)
        fftOutImag = [Float](repeating: 0, count: size)
        fftPower = [Float](repeating: 0, count: size)
        fftImagSq = [Float](repeating: 0, count: size)
        fftShifted = [Float](repeating: 0, count: size)
        vDSP_hann_window(&fftWindow, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    }

    private func computeFFTLocked(real: [Float], imag: [Float]) {
        guard let onFFTFrame, real.count >= fftSize else { return }

        if fftSetup == nil {
            setFFTSizeLocked(fftSize)
        }

        guard let setup = fftSetup else { return }
        guard fftInReal.count == fftSize, fftWindow.count == fftSize else { return }

        real.withUnsafeBufferPointer { src in
            fftInReal.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: src.baseAddress!, count: fftSize)
            }
        }
        imag.withUnsafeBufferPointer { src in
            fftInImag.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: src.baseAddress!, count: fftSize)
            }
        }

        // Apply Hann window
        vDSP_vmul(fftInReal, 1, fftWindow, 1, &fftInReal, 1, vDSP_Length(fftSize))
        vDSP_vmul(fftInImag, 1, fftWindow, 1, &fftInImag, 1, vDSP_Length(fftSize))

        // FFT
        vDSP_DFT_Execute(setup, fftInReal, fftInImag, &fftOutReal, &fftOutImag)

        // Power spectrum in dBFS
        vDSP_vsq(fftOutReal, 1, &fftPower, 1, vDSP_Length(fftSize))
        vDSP_vsq(fftOutImag, 1, &fftImagSq, 1, vDSP_Length(fftSize))
        vDSP_vadd(fftPower, 1, fftImagSq, 1, &fftPower, 1, vDSP_Length(fftSize))

        // Normalize
        var scale = 1.0 / Float(fftSize * fftSize)
        vDSP_vsmul(fftPower, 1, &scale, &fftPower, 1, vDSP_Length(fftSize))

        // Floor tiny values to avoid log(0)
        var floor: Float = 1e-20
        vDSP_vthr(fftPower, 1, &floor, &fftPower, 1, vDSP_Length(fftSize))
        // To dBFS: 10 * log10(power / 1.0)
        var ref: Float = 1.0
        vDSP_vdbcon(fftPower, 1, &ref, &fftPower, 1, vDSP_Length(fftSize), 1) // 1 = power (10*log10)

        // FFT shift: swap halves so DC is in center
        let half = fftSize / 2
        fftShifted[0..<half] = fftPower[half..<fftSize]
        fftShifted[half..<fftSize] = fftPower[0..<half]

        onFFTFrame(fftShifted, fftSize)
    }

    private func shouldEmitFFTFrame(now: CFAbsoluteTime) -> Bool {
        guard onFFTFrame != nil else { return false }
        let minInterval = 1.0 / Double(max(1, min(60, fftFrameRate)))
        if now - lastFFTFrameTime >= minInterval {
            lastFFTFrameTime = now
            return true
        }
        return false
    }

    // MARK: - Rebuild

    private func rebuildDemodChain(preservingBandwidth: Bool) {
        withPipelineLock {
            rebuildDemodChainLocked(preservingBandwidth: preservingBandwidth)
        }
    }

    private func rebuildDemodChainLocked(preservingBandwidth: Bool) {
        let requestedBandwidth = _bandwidthHz

        // Intermediate rate depends on sample rate + mode decimation target.
        let decimFactor = max(1, _sampleRate / intermediateTarget)
        let intermediateRate = Float(_sampleRate) / Float(decimFactor)

        switch _mode {
        case .am:
            demodulator = AMDemodulator()
            if !preservingBandwidth { _bandwidthHz = 10_000 }
        case .nfm:
            demodulator = FMDemodulator(sampleRate: intermediateRate, deviation: 5000, deemphasisUs: deemphasisUs)
            if !preservingBandwidth { _bandwidthHz = 12_500 }
        case .wfm:
            demodulator = FMDemodulator(sampleRate: intermediateRate, deviation: 75_000, deemphasisUs: deemphasisUs)
            if !preservingBandwidth { _bandwidthHz = 200_000 }
        case .usb:
            demodulator = SSBDemodulator(isUSB: true)
            if !preservingBandwidth { _bandwidthHz = 2_400 }
        case .lsb:
            demodulator = SSBDemodulator(isUSB: false)
            if !preservingBandwidth { _bandwidthHz = 2_400 }
        case .cw:
            demodulator = CWDemodulator()
            if !preservingBandwidth { _bandwidthHz = 500 }
        }

        if preservingBandwidth {
            _bandwidthHz = requestedBandwidth
        }

        // Rebuild filters with final mode/bandwidth.
        rebuildFiltersLocked()
        pendingDemodChainRebuild = false

        SDRLogger.dsp.info("Demod chain rebuilt: \(self._mode.rawValue), intermediateRate=\(intermediateRate)")
        SDRDebug.print("🔊 Demod: \(self._mode.rawValue), intermediate=\(intermediateRate)Hz, decim=\(decimFactor)")
    }

    private var intermediateTarget: Int {
        switch _mode {
        case .wfm: return 240_000
        default: return 48_000
        }
    }

    private func rebuildFiltersLocked() {
        let sampleRate = max(250_000, _sampleRate)
        let bandwidth = max(200, _bandwidthHz)
        let cutoff = Float(bandwidth) / Float(sampleRate)
        let normalizedCutoff = min(0.99, max(0.0005, cutoff * 2))
        let numTaps: Int
        if bandwidth < 5000 {
            numTaps = 127 // Narrow filter needs more taps
        } else if bandwidth < 50_000 {
            numTaps = 63
        } else {
            numTaps = 65 // WFM needs decent filter too
        }

        let decimFactor = max(1, sampleRate / intermediateTarget)
        channelFilterI = FIRFilter(cutoffNormalized: normalizedCutoff, numTaps: numTaps, decimationFactor: decimFactor)
        channelFilterQ = FIRFilter(cutoffNormalized: normalizedCutoff, numTaps: numTaps, decimationFactor: decimFactor)

        let intermediateRate = Double(sampleRate) / Double(decimFactor)
        let newBaseRatio = outputRate / intermediateRate
        resampler = Resampler(inputRate: intermediateRate, outputRate: outputRate)
        driftCompensator = DriftCompensator(baseRatio: newBaseRatio, targetFill: targetAudioFill)

        SDRLogger.dsp.info("Filters rebuilt: bw=\(self._bandwidthHz)Hz, decim=\(decimFactor), intermediate=\(intermediateRate)Hz")
        SDRDebug.print("🔧 Filters: bw=\(self._bandwidthHz)Hz, taps=\(numTaps), decim=\(decimFactor), rate=\(intermediateRate)Hz, ratio=\(String(format: "%.6f", newBaseRatio))")
    }

    /// Update IQ sample rate and rebuild the DSP chain.
    public func setSampleRate(_ hz: Int) {
        let clamped = max(250_000, hz)
        withPipelineLock {
            guard _sampleRate != clamped else { return }
            _sampleRate = clamped
            blockSizeBytes = DSPPipeline.computeBlockSizeBytes(
                for: clamped,
                minBlockSizeBytes: minBlockSizeBytes,
                maxBlockSizeBytes: maxBlockSizeBytes
            )
            rebuildDemodChainLocked(preservingBandwidth: true)
            resetStateLocked()
        }
    }

    /// Update FM de-emphasis time constant and rebuild FM demodulators.
    public func setDeemphasisUs(_ microseconds: Int) {
        let clamped = Float(max(25, min(200, microseconds)))
        let shouldRebuildImmediately = shouldContinueRunning()
        withPipelineLock {
            guard deemphasisUs != clamped else { return }
            deemphasisUs = clamped
            if _mode == .nfm || _mode == .wfm {
                if shouldRebuildImmediately {
                    rebuildDemodChainLocked(preservingBandwidth: true)
                    resetStateLocked()
                } else {
                    pendingDemodChainRebuild = true
                }
            }
        }
    }

    /// Configure high-pass and low-pass cutoffs for demodulated audio.
    /// Use 0 to disable each stage.
    public func setAudioToneFilters(highPassHz: Int, lowPassHz: Int) {
        withPipelineLock {
            setAudioToneFiltersLocked(highPassHz: highPassHz, lowPassHz: lowPassHz)
        }
    }

    public func setAudioHighPassCutoff(_ hz: Int) {
        withPipelineLock {
            setAudioToneFiltersLocked(highPassHz: hz, lowPassHz: audioLowPassCutoffHz)
        }
    }

    public func setAudioLowPassCutoff(_ hz: Int) {
        withPipelineLock {
            setAudioToneFiltersLocked(highPassHz: audioHighPassCutoffHz, lowPassHz: hz)
        }
    }

    private func setAudioToneFiltersLocked(highPassHz: Int, lowPassHz: Int) {
        let normalized = normalizedAudioCutoffs(
            highPassHz: highPassHz,
            lowPassHz: lowPassHz
        )
        guard normalized.highPass != audioHighPassCutoffHz || normalized.lowPass != audioLowPassCutoffHz else { return }

        audioHighPassCutoffHz = normalized.highPass
        audioLowPassCutoffHz = normalized.lowPass
        audioToneFilter.setHighPassCutoff(normalized.highPass)
        audioToneFilter.setLowPassCutoff(normalized.lowPass)
    }

    /// Update squelch threshold.
    public func setSquelch(_ threshold: Float) {
        withPipelineLock {
            squelch.threshold = threshold
        }
    }

    /// Check if squelch is currently open.
    public var isSquelchOpen: Bool { withPipelineLock { squelch.isOpen } }

    /// Smoothed squelch noise metric for diagnostics/UI.
    public var squelchNoiseLevel: Float { withPipelineLock { squelch.noiseLevel } }

    /// Enable/disable noise blanker (impulse noise removal).
    public var noiseBlankerEnabled: Bool {
        get { withPipelineLock { _noiseBlankerEnabled } }
        set { withPipelineLock { _noiseBlankerEnabled = newValue } }
    }

    /// Set noise blanker threshold (0 = off, higher = less aggressive).
    public func setNoiseBlankerThreshold(_ threshold: Float) {
        withPipelineLock {
            noiseBlanker.threshold = threshold
            _noiseBlankerEnabled = threshold > 0
        }
    }

    /// Enable/disable audio AGC (post-demod level normalization).
    public var audioAgcEnabled: Bool {
        get { withPipelineLock { _audioAgcEnabled } }
        set {
            withPipelineLock {
                _audioAgcEnabled = newValue
                audioAGC.isEnabled = newValue
                if !newValue { audioAGC.reset() }
            }
        }
    }

    /// Reset all DSP state (call after retune).
    public func resetState() {
        withPipelineLock {
            resetStateLocked()
        }
    }

    private func resetStateLocked() {
        iqDcBlocker.reset()
        ncoMixer.reset()
        channelFilterI.reset()
        channelFilterQ.reset()
        demodulator.reset()
        noiseBlanker.reset()
        if _audioAgcEnabled { audioAGC.reset() }
        squelch.reset()
        resampler.reset()
        driftCompensator.reset()
        audioToneFilter.reset()
        lastFFTFrameTime = 0
    }

    private func normalizedAudioCutoffs(highPassHz: Int, lowPassHz: Int) -> (highPass: Int, lowPass: Int) {
        let requestedHP = max(0, highPassHz)
        let requestedLP = max(0, lowPassHz)

        let clampedLP = requestedLP > 0 ? min(maxAudioCutoffHz, requestedLP) : 0
        let maxHP = clampedLP > 0 ? max(0, clampedLP - minAudioCutoffGapHz) : maxAudioCutoffHz
        let clampedHP = min(requestedHP, maxHP)

        return (clampedHP, clampedLP)
    }

    private func shouldContinueRunning() -> Bool {
        lifecycleLock.lock()
        let running = shouldRun
        lifecycleLock.unlock()
        return running
    }

    @inline(__always)
    private func withPipelineLock<T>(_ body: () -> T) -> T {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        return body()
    }

    deinit {
        stop()
        if let setup = fftSetup {
            vDSP_DFT_DestroySetup(setup)
        }
    }

    private static func computeBlockSizeBytes(
        for sampleRate: Int,
        minBlockSizeBytes: Int,
        maxBlockSizeBytes: Int
    ) -> Int {
        let targetBlockMs: Double
        switch sampleRate {
        case ..<500_000:
            targetBlockMs = 8.0
        case ..<1_500_000:
            targetBlockMs = 10.0
        default:
            targetBlockMs = 12.0
        }

        let desiredBytes = Int(Double(sampleRate) * 2.0 * targetBlockMs / 1000.0)
        let minBucket = max(1, minBlockSizeBytes / 1024)
        let maxBucket = max(minBucket, maxBlockSizeBytes / 1024)
        let bucket = max(minBucket, min(maxBucket, desiredBytes / 1024))
        return bucket * 1024
    }
}
