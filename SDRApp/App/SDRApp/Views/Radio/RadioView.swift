import SwiftUI
import SDRModels
import SDRRender

struct RadioView: View {
    @Environment(SettingsStore.self) private var settings
    var viewModel: RadioViewModel
    @State private var showFrequencyKeypad = false
    @State private var showConnectionSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // DEBUG overlay
                Text("DBG: conn=\(String(describing: viewModel.connectionState)) isConn=\(viewModel.isConnected) isPlay=\(viewModel.isPlaying)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.yellow)
                    .background(Color.black.opacity(0.7))
                    .frame(maxWidth: .infinity)

                // Connection status bar
                connectionBar

                // Spectrum + Waterfall
                spectrumWaterfallSection

                // Frequency display
                frequencyDisplay

                // Mode selector
                modeSelector

                // Controls
                controlsSection

                Spacer(minLength: 0)
            }
            .navigationTitle("SDR Radio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    connectionButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    playButton
                }
            }
            .sheet(isPresented: $showFrequencyKeypad) {
                FrequencyKeypadView(
                    frequencyHz: viewModel.frequencyHz,
                    onSubmit: { hz in
                        viewModel.setFrequency(hz)
                        showFrequencyKeypad = false
                    }
                )
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $showConnectionSheet) {
                ConnectionSheet(viewModel: viewModel)
                    .presentationDetents([.medium])
            }
            .onAppear {
                autoConnect()
            }
        }
    }

    // MARK: - Connection Bar

    private var connectionBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .accessibilityLabel(viewModel.isConnected ? "Connected" : "Disconnected")

            Text(connectionStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if viewModel.isPlaying {
                if viewModel.isNetworkPoor {
                    Text("Network Poor")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.15))
                        .foregroundStyle(.red)
                        .clipShape(Capsule())
                }
                Text(String(format: "%.1f Mbps", viewModel.throughputMbps))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if viewModel.isDirectSamplingActive {
                Text("DS Q")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var connectionStatusText: String {
        switch viewModel.connectionState {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .validatingHeader: return "Validating..."
        case .connected(let header): return "Connected (\(header.tunerType.displayName))"
        case .reconnecting(let attempt): return "Reconnecting (\(attempt))..."
        case .failed(let msg): return "Error: \(msg)"
        }
    }

    // MARK: - Spectrum + Waterfall

    private var spectrumWaterfallSection: some View {
        VStack(spacing: 0) {
            // Spectrum
            SpectrumCanvasView(
                bins: viewModel.spectrumProcessor.normalizedBins(),
                peakBins: viewModel.spectrumProcessor.peakHoldEnabled
                    ? viewModel.spectrumProcessor.peakBins.map { max(0, min(1, ($0 - viewModel.spectrumProcessor.minDB) / (viewModel.spectrumProcessor.maxDB - viewModel.spectrumProcessor.minDB))) }
                    : [],
                showPeaks: viewModel.spectrumProcessor.peakHoldEnabled
            )
            .frame(height: 120)
            .background(Color.black)
            .accessibilityLabel("Spectrum display")

            // Waterfall
            if let renderer = viewModel.waterfallRenderer {
                WaterfallView(renderer: renderer)
                    .frame(height: 200)
                    .accessibilityLabel("Waterfall display")
            } else {
                Rectangle()
                    .fill(Color.black)
                    .frame(height: 200)
                    .overlay {
                        Text("Metal not available")
                            .foregroundStyle(.gray)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    // MARK: - Frequency Display

    private var frequencyDisplay: some View {
        VStack(spacing: 8) {
            Button {
                showFrequencyKeypad = true
            } label: {
                VStack(spacing: 2) {
                    Text(viewModel.formatFrequency(viewModel.frequencyHz))
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Frequency \(viewModel.formatFrequency(viewModel.frequencyHz))")

                    HStack {
                        Text("Step: \(formatStep(viewModel.stepHz))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 8)
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onEnded { value in
                        let steps = Int(-value.translation.width / 20)
                        if steps != 0 {
                            let newFreq = viewModel.frequencyHz + steps * viewModel.stepHz
                            viewModel.setFrequency(max(1_000, newFreq))
                        }
                    }
            )

            // Step up/down buttons
            HStack(spacing: 20) {
            Button { viewModel.stepFrequency(up: false) } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.title2)
            }
            .accessibilityLabel("Decrease frequency")

            // Step size picker
            Menu {
                ForEach([100, 1_000, 5_000, 9_000, 10_000, 12_500, 25_000, 50_000, 100_000], id: \.self) { step in
                    Button(formatStep(step)) {
                        viewModel.stepHz = step
                    }
                }
            } label: {
                Text(formatStep(viewModel.stepHz))
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
            .accessibilityLabel("Step size")

            Button { viewModel.stepFrequency(up: true) } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
            }
            .accessibilityLabel("Increase frequency")
        }
        } // VStack
    }

    // MARK: - Mode Selector

    private var modeSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DemodMode.allCases) { demodMode in
                    Button {
                        viewModel.setMode(demodMode)
                    } label: {
                        Text(demodMode.displayName)
                            .font(.subheadline.bold())
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(viewModel.mode == demodMode ? Color.accentColor : Color(.systemGray5))
                            .foregroundStyle(viewModel.mode == demodMode ? .white : .primary)
                            .clipShape(Capsule())
                    }
                    .accessibilityLabel("\(demodMode.displayName) mode")
                    .accessibilityAddTraits(viewModel.mode == demodMode ? .isSelected : [])
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(spacing: 12) {
            if viewModel.isDirectSamplingActive {
                HStack {
                    Text("Direct Sampling (Q) active for < 24 MHz")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                }
            }

            // Gain
            HStack {
                Text("Gain")
                    .font(.caption)
                    .frame(width: 50, alignment: .leading)

                Picker("", selection: Binding(
                    get: { viewModel.gainMode },
                    set: { viewModel.setGain(mode: $0, value: viewModel.gainValue) }
                )) {
                    ForEach(GainMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                if viewModel.gainMode == .manual {
                    Slider(value: Binding(
                        get: { viewModel.gainValue },
                        set: { viewModel.setGain(mode: .manual, value: $0) }
                    ), in: 0...50, step: 1)
                    .accessibilityLabel("Manual gain")

                    Text(String(format: "%.0f", viewModel.gainValue))
                        .font(.caption.monospacedDigit())
                        .frame(width: 30)
                }
            }

            // Squelch (for applicable modes)
            if viewModel.mode.supportsSquelch {
                HStack {
                    Text("SQL")
                        .font(.caption)
                        .frame(width: 50, alignment: .leading)

                    Slider(value: Binding(
                        get: { viewModel.squelchLevel },
                        set: { viewModel.setSquelch($0) }
                    ), in: 0...1)
                    .accessibilityLabel("Squelch level")

                    Circle()
                        .fill(viewModel.dspPipeline.isSquelchOpen ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                        .accessibilityLabel(viewModel.dspPipeline.isSquelchOpen ? "Squelch open" : "Squelch closed")
                }
            }

            // BFO offset (for SSB/CW)
            if viewModel.mode.usesBFO {
                HStack {
                    Text("BFO")
                        .font(.caption)
                        .frame(width: 50, alignment: .leading)

                    Slider(value: Binding(
                        get: { viewModel.bfoOffset },
                        set: { viewModel.setBFOOffset($0) }
                    ), in: -1000...1000, step: 10)
                    .accessibilityLabel("BFO fine tune")

                    Text(String(format: "%+.0f Hz", viewModel.bfoOffset))
                        .font(.caption.monospacedDigit())
                        .frame(width: 60)
                }
            }

            // PPM
            HStack {
                Text("PPM")
                    .font(.caption)
                    .frame(width: 50, alignment: .leading)

                Slider(value: Binding(
                    get: { viewModel.ppm },
                    set: { viewModel.setPPM($0) }
                ), in: -100...100, step: 1)
                .accessibilityLabel("PPM correction")

                Text(String(format: "%+.0f", viewModel.ppm))
                    .font(.caption.monospacedDigit())
                    .frame(width: 40)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Toolbar buttons

    private var connectionButton: some View {
        Button {
            showConnectionSheet = true
        } label: {
            Image(systemName: viewModel.isConnected ? "wifi" : "wifi.slash")
        }
        .accessibilityLabel(viewModel.isConnected ? "Connected" : "Not connected")
    }

    private var playButton: some View {
        Button {
            if viewModel.isPlaying {
                viewModel.stopListening()
            } else {
                viewModel.startListening()
            }
        } label: {
            Image(systemName: viewModel.isPlaying ? "stop.fill" : "play.fill")
        }
        .disabled(!viewModel.isConnected)
        .accessibilityLabel(viewModel.isPlaying ? "Stop" : "Play")
    }

    // MARK: - Helpers

    private func autoConnect() {
        // Only auto-connect if not already connected/connecting
        if case .disconnected = viewModel.connectionState,
           !settings.lastServerHost.isEmpty {
            print("📻 autoConnect to \(settings.lastServerHost):\(settings.lastServerPort)")
            viewModel.connect(host: settings.lastServerHost, port: UInt16(settings.lastServerPort))
        }
    }

    private func formatStep(_ hz: Int) -> String {
        if hz >= 1_000_000 { return String(format: "%.1f MHz", Double(hz) / 1_000_000) }
        if hz >= 1_000 { return String(format: "%.1f kHz", Double(hz) / 1_000) }
        return "\(hz) Hz"
    }
}
