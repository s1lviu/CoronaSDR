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
    public var mode: DemodMode = .nfm {
        didSet {
            if mode != oldValue {
                rebuildDemodChain()
            }
        }
    }
    public var bandwidthHz: Int = 12_500 {
        didSet {
            if bandwidthHz != oldValue {
                rebuildFilters()
            }
        }
    }
    public var sampleRate: Int = 1_024_000
    public var bfoOffsetHz: Float = 0

    // DC blocking
    public var dcBlockEnabled: Bool = true

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
    private var resampler: Resampler
    private var driftCompensator: DriftCompensator
    private var deemphasisUs: Float = 75
    private let targetAudioFill: Double = 0.65

    // FFT output callback
    public var onFFTFrame: (([Float], Int) -> Void)? // (bins, fftSize)

    // Reused work buffers to avoid per-block allocations in the hot loop.
    private var realWork: [Float] = []
    private var imagWork: [Float] = []

    // Processing state
    private var dspThread: Thread?
    private var isRunning: Bool = false
    private let outputRate: Double = 48000

    // Block size for processing (in IQ sample pairs = 2 bytes each for 8-bit IQ)
    private let blockSize: Int = 16384 // bytes (8192 IQ samples)

    public init(iqBuffer: IQRingBuffer, audioBuffer: AudioRingBuffer, sampleRate: Int = 1_024_000) {
        self.iqBuffer = iqBuffer
        self.audioBuffer = audioBuffer
        self.sampleRate = sampleRate

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

        rebuildDemodChain()
    }

    // MARK: - Start / Stop

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        let thread = Thread { [weak self] in
            self?.dspLoop()
        }
        thread.name = "com.sdrapp.dsp"
        thread.qualityOfService = .userInitiated
        thread.start()
        dspThread = thread

        print("🎛️ DSP pipeline started: mode=\(mode.rawValue), sampleRate=\(sampleRate), bw=\(bandwidthHz)")
        SDRLogger.dsp.info("DSP pipeline started")
    }

    public func stop() {
        isRunning = false
        dspThread = nil
        SDRLogger.dsp.info("DSP pipeline stopped")
    }

    // MARK: - DSP Loop

    private func dspLoop() {
        let rawBlock = UnsafeMutableRawBufferPointer.allocate(byteCount: blockSize, alignment: 16)
        defer { rawBlock.deallocate() }

        var blockCount = 0
        var lastLogTime = CFAbsoluteTimeGetCurrent()

        while isRunning {
            let available = iqBuffer.availableForReading

            if available < blockSize {
                Thread.sleep(forTimeInterval: 0.001)
                continue
            }

            // Read IQ data
            let bytesRead = iqBuffer.read(into: rawBlock, maxCount: blockSize)
            guard bytesRead > 0 else { continue }

            // Convert 8-bit IQ to complex float
            let sampleCount = ComplexBuffer.fromUInt8IQ(
                UnsafeRawBufferPointer(rawBlock),
                into: complexBuf
            )
            guard sampleCount > 0 else { continue }

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
            if dcBlockEnabled {
                iqDcBlocker.process(real: &realWork, imag: &imagWork)
            }

            // NCO mix (if needed for offset tuning or BFO)
            if bfoOffsetHz != 0 {
                ncoMixer.setFrequency(bfoOffsetHz, sampleRate: Float(sampleRate))
                ncoMixer.mix(real: &realWork, imag: &imagWork, count: sampleCount)
            }

            // FFT (before channelization, on full bandwidth)
            computeFFT(real: realWork, imag: imagWork)

            // Channel filter + decimate
            let filteredI = channelFilterI.process(realWork)
            let filteredQ = channelFilterQ.process(imagWork)

            // Demodulate
            var audio = demodulator.demodulate(real: filteredI, imag: filteredQ)

            // Squelch
            if mode.supportsSquelch {
                squelch.process(&audio)
            }

            // Resample to 48kHz
            let currentFill = audioBuffer.fillLevel
            let adjustedRatio = driftCompensator.update(currentFill: currentFill)
            resampler.currentRatio = adjustedRatio

            let resampled = resampler.process(audio)

            // Write to audio ring buffer
            audioBuffer.write(resampled)

            // Periodic diagnostics (every ~2 sec)
            blockCount += 1
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastLogTime >= 2.0 {
                let bps = Double(blockCount * blockSize) / (now - lastLogTime)
                print("🎛️ DSP: \(blockCount) blocks, \(String(format: "%.1f", bps/1024))KB/s, " +
                      "IQ→\(sampleCount) filt→\(filteredI.count) demod→\(audio.count) resamp→\(resampled.count), " +
                      "audioFill=\(String(format: "%.1f%%", currentFill*100)), ratio=\(String(format: "%.6f", adjustedRatio))")
                blockCount = 0
                lastLogTime = now
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

    public func setFFTSize(_ size: Int) {
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

    private func computeFFT(real: [Float], imag: [Float]) {
        guard let onFFTFrame, real.count >= fftSize else { return }

        if fftSetup == nil {
            setFFTSize(fftSize)
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

    // MARK: - Rebuild

    private func rebuildDemodChain() {
        // First rebuild filters to get the correct intermediate rate
        rebuildFilters()

        // Now create demod with the actual intermediate sample rate
        let decimFactor = max(1, sampleRate / intermediateTarget)
        let intermediateRate = Float(sampleRate) / Float(decimFactor)

        switch mode {
        case .am:
            demodulator = AMDemodulator()
            bandwidthHz = 10_000
        case .nfm:
            demodulator = FMDemodulator(sampleRate: intermediateRate, deviation: 5000, deemphasisUs: deemphasisUs)
            bandwidthHz = 12_500
        case .wfm:
            demodulator = FMDemodulator(sampleRate: intermediateRate, deviation: 75000, deemphasisUs: deemphasisUs)
            bandwidthHz = 200_000
        case .usb:
            demodulator = SSBDemodulator(isUSB: true)
            bandwidthHz = 2_400
        case .lsb:
            demodulator = SSBDemodulator(isUSB: false)
            bandwidthHz = 2_400
        case .cw:
            demodulator = CWDemodulator()
            bandwidthHz = 500
        }

        // Rebuild filters again with updated bandwidth
        rebuildFilters()

        SDRLogger.dsp.info("Demod chain rebuilt: \(self.mode.rawValue), intermediateRate=\(intermediateRate)")
        print("🔊 Demod: \(self.mode.rawValue), intermediate=\(intermediateRate)Hz, decim=\(decimFactor)")
    }

    private var intermediateTarget: Int {
        switch mode {
        case .wfm: return 240_000
        default: return 48_000
        }
    }

    private func rebuildFilters() {
        let cutoff = Float(bandwidthHz) / Float(sampleRate)
        let numTaps: Int
        if bandwidthHz < 5000 {
            numTaps = 127 // Narrow filter needs more taps
        } else if bandwidthHz < 50_000 {
            numTaps = 63
        } else {
            numTaps = 65 // WFM needs decent filter too
        }

        let decimFactor = max(1, sampleRate / intermediateTarget)
        channelFilterI = FIRFilter(cutoffNormalized: cutoff * 2, numTaps: numTaps, decimationFactor: decimFactor)
        channelFilterQ = FIRFilter(cutoffNormalized: cutoff * 2, numTaps: numTaps, decimationFactor: decimFactor)

        let intermediateRate = Double(sampleRate) / Double(decimFactor)
        let newBaseRatio = outputRate / intermediateRate
        resampler = Resampler(inputRate: intermediateRate, outputRate: outputRate)
        driftCompensator = DriftCompensator(baseRatio: newBaseRatio, targetFill: targetAudioFill)

        SDRLogger.dsp.info("Filters rebuilt: bw=\(self.bandwidthHz)Hz, decim=\(decimFactor), intermediate=\(intermediateRate)Hz")
        print("🔧 Filters: bw=\(self.bandwidthHz)Hz, taps=\(numTaps), decim=\(decimFactor), rate=\(intermediateRate)Hz, ratio=\(String(format: "%.6f", newBaseRatio))")
    }

    /// Update squelch threshold.
    public func setSquelch(_ threshold: Float) {
        squelch.threshold = threshold
    }

    /// Check if squelch is currently open.
    public var isSquelchOpen: Bool { squelch.isOpen }

    /// Smoothed squelch noise metric for diagnostics/UI.
    public var squelchNoiseLevel: Float { squelch.noiseLevel }

    /// Reset all DSP state (call after retune).
    public func resetState() {
        iqDcBlocker.reset()
        ncoMixer.reset()
        channelFilterI.reset()
        channelFilterQ.reset()
        demodulator.reset()
        squelch.reset()
        resampler.reset()
        driftCompensator.reset()
    }
}
