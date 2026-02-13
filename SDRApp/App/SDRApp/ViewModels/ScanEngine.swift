import Foundation
import Observation
import SDRModels
import SDRSupport

/// Scan engine: drives list scan and range scan operations.
@Observable
@MainActor
final class ScanEngine {
    enum ScanState {
        case idle
        case scanning
        case holding(frequencyHz: Int)
        case paused
    }

    var state: ScanState = .idle
    var currentFrequencyHz: Int = 0
    var progress: Double = 0

    // Callbacks
    var onTune: ((Int, DemodMode) -> Void)?
    var onSquelchCheck: (() -> Bool)?

    private var scanTask: Task<Void, Never>?
    private var skipRequested = false

    // MARK: - List Scan

    func startListScan(
        frequencies: [(hz: Int, mode: DemodMode)],
        dwellMs: Int = 2000,
        holdSec: Int = 5
    ) {
        guard !frequencies.isEmpty else {
            state = .idle
            return
        }
        stop()
        state = .scanning

        scanTask = Task { [weak self] in
            guard let self else { return }
            let total = frequencies.count
            var index = 0

            while !Task.isCancelled {
                let entry = frequencies[index % total]
                self.currentFrequencyHz = entry.hz
                self.progress = Double(index % total) / Double(total)
                self.skipRequested = false

                // Tune
                await MainActor.run {
                    self.onTune?(entry.hz, entry.mode)
                }

                // Wait for settle
                try? await Task.sleep(for: .milliseconds(250))

                // Dwell: check squelch
                let dwellStart = CFAbsoluteTimeGetCurrent()
                var squelchOpened = false

                while CFAbsoluteTimeGetCurrent() - dwellStart < Double(dwellMs) / 1000.0 {
                    if Task.isCancelled { return }
                    if self.skipRequested {
                        self.skipRequested = false
                        break
                    }
                    if self.onSquelchCheck?() == true {
                        squelchOpened = true
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }

                if squelchOpened {
                    // Hold on this frequency
                    await MainActor.run { self.state = .holding(frequencyHz: entry.hz) }
                    SDRLogger.scan.info("Scan hold on \(entry.hz) Hz")

                    let holdStart = CFAbsoluteTimeGetCurrent()
                    while CFAbsoluteTimeGetCurrent() - holdStart < Double(holdSec) {
                        if Task.isCancelled { return }
                        if self.skipRequested {
                            self.skipRequested = false
                            break
                        }
                        // Keep holding while squelch is open
                        if self.onSquelchCheck?() == false {
                            try? await Task.sleep(for: .milliseconds(500))
                            if self.onSquelchCheck?() == false {
                                break // Squelch closed for 500ms, resume scanning
                            }
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }

                    await MainActor.run { self.state = .scanning }
                }

                index += 1
            }
        }
    }

    // MARK: - Range Scan

    func startRangeScan(
        startHz: Int,
        endHz: Int,
        stepHz: Int,
        mode: DemodMode,
        dwellMs: Int = 1000
    ) {
        stop()
        state = .scanning

        scanTask = Task { [weak self] in
            guard let self else { return }
            var freq = startHz

            while freq <= endHz && !Task.isCancelled {
                self.currentFrequencyHz = freq
                let denominator = max(1, endHz - startHz)
                self.progress = Double(freq - startHz) / Double(denominator)
                self.skipRequested = false

                await MainActor.run {
                    self.onTune?(freq, mode)
                }

                // Settle
                try? await Task.sleep(for: .milliseconds(250))

                // Dwell
                let dwellStart = CFAbsoluteTimeGetCurrent()
                while CFAbsoluteTimeGetCurrent() - dwellStart < Double(dwellMs) / 1000.0 {
                    if Task.isCancelled { return }
                    if self.skipRequested {
                        self.skipRequested = false
                        break
                    }
                    if self.onSquelchCheck?() == true {
                        // Signal found, hold
                        await MainActor.run { self.state = .holding(frequencyHz: freq) }
                        try? await Task.sleep(for: .seconds(3))
                        await MainActor.run { self.state = .scanning }
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }

                freq += stepHz
            }

            await MainActor.run { self.state = .idle }
        }
    }

    // MARK: - Control

    func pause() {
        state = .paused
        scanTask?.cancel()
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        state = .idle
        progress = 0
        skipRequested = false
    }

    func skip() {
        // Skip current dwell/hold and advance to next frequency.
        skipRequested = true
    }
}
