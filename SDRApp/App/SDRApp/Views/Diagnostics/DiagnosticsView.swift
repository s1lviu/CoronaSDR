import SwiftUI
import SDRSupport

struct DiagnosticsView: View {
    let viewModel: RadioViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    diagRow("Status", value: connectionStatusText)
                    diagRow("Playback", value: viewModel.isPlaying ? "Active" : "Stopped")
                    diagRow("Throughput", value: String(format: "%.2f Mbps", viewModel.throughputMbps))
                    diagRow("Network Quality", value: networkQualityText)
                    diagRow("Network Hint", value: viewModel.networkQualityHint)
                    diagRow("Direct Sampling", value: directSamplingText)
                }

                Section("Buffers") {
                    diagRow("IQ Buffer Fill", value: String(format: "%.1f%%", viewModel.iqBufferFill * 100))
                    diagRow("Audio Buffer Fill", value: String(format: "%.1f%%", viewModel.audioBufferFill * 100))
                    diagRow("IQ Overruns", value: "\(viewModel.iqBuffer.overrunCount)")
                    diagRow("IQ Underruns", value: "\(viewModel.iqBuffer.underrunCount)")
                    diagRow("Audio Overruns", value: "\(viewModel.audioBuffer.overrunCount)")
                    diagRow("Audio Underruns", value: "\(viewModel.audioBuffer.underrunCount)")
                }

                Section("DSP") {
                    diagRow("Sample Rate", value: "\(viewModel.dspPipeline.sampleRate) Hz")
                    diagRow("Mode", value: viewModel.mode.displayName)
                    diagRow("Bandwidth", value: "\(viewModel.bandwidthHz) Hz")
                }

                Section("Display") {
                    diagRow("Waterfall FPS", value: waterfallFPSText)
                }

                Section("Hints") {
                    Label("Wired Ethernet to server recommended for best performance", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Label("If audio drops, use the Low processing profile", systemImage: "lightbulb")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Diagnostics")
        }
    }

    private func diagRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit())
                .accessibilityLabel("\(label): \(value)")
        }
    }

    private var connectionStatusText: String {
        switch viewModel.connectionState {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting..."
        case .validatingHeader:
            return "Validating..."
        case .connected(let header):
            return "Connected (\(header.tunerType.displayName))"
        case .reconnecting(let attempt):
            return "Reconnecting (\(attempt))..."
        case .failed(let message):
            return "Error: \(message)"
        }
    }

    private var networkQualityText: String {
        guard viewModel.isPlaying else { return "Idle" }
        return viewModel.isNetworkPoor ? "Poor" : "Good"
    }

    private var directSamplingText: String {
        switch viewModel.directSamplingMode {
        case .off:
            return "Off"
        case .iBranch:
            return "I-branch"
        case .qBranch:
            return "Q-branch"
        }
    }

    private var waterfallFPSText: String {
        guard viewModel.isPlaying else { return "Idle" }
        guard viewModel.isRadioTabVisible else { return "Paused (Radio tab hidden)" }
        return String(format: "%.1f", viewModel.currentFPS)
    }
}
