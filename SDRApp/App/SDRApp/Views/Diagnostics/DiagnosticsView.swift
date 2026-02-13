import SwiftUI
import SDRSupport

struct DiagnosticsView: View {
    let viewModel: RadioViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    diagRow("Status", value: viewModel.isConnected ? "Connected" : "Disconnected")
                    diagRow("Throughput", value: String(format: "%.2f Mbps", viewModel.throughputMbps))
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
                    diagRow("Waterfall FPS", value: String(format: "%.1f", viewModel.currentFPS))
                }

                Section("Hints") {
                    Label("Wired Ethernet to server recommended for best performance", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Label("If audio drops, try 'Low' sample rate profile", systemImage: "lightbulb")
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
}
