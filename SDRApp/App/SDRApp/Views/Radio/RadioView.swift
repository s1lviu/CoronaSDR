import SwiftUI
import SDRModels
import SDRRender

struct RadioView: View {
    @Environment(SettingsStore.self) private var settings
    var viewModel: RadioViewModel
    @State private var showFrequencyKeypad = false
    @State private var showConnectionSheet = false
    @State private var helpTopic: ControlHelpTopic?

    private enum ControlHelpTopic: String, Identifiable {
        case step
        case gain
        case squelch
        case bfo
        case ppm
        case offsetTuning
        case biasTee

        var id: String { rawValue }

        var title: String {
            switch self {
            case .step: return "Step Size"
            case .gain: return "Gain"
            case .squelch: return "Squelch (SQL)"
            case .bfo: return "BFO"
            case .ppm: return "PPM Correction"
            case .offsetTuning: return "Offset Tuning"
            case .biasTee: return "Bias-Tee"
            }
        }

        var summary: String {
            switch self {
            case .step:
                return "Step size is how much the frequency changes when you tune with +/- or swipe."
            case .gain:
                return "Gain controls tuner amplification before demodulation. Too low loses weak signals, too high adds overload and noise."
            case .squelch:
                return "Squelch mutes audio when signal level is below a threshold. Useful for FM scanning to avoid constant noise."
            case .bfo:
                return "BFO shifts SSB/CW audio pitch for fine tuning. It helps center speech/tones without changing RF frequency."
            case .ppm:
                return "PPM compensates crystal frequency error in the SDR tuner. Use it to align stations exactly on frequency."
            case .offsetTuning:
                return "Offset tuning shifts the tuned carrier away from DC to reduce center spike and DC offset artifacts."
            case .biasTee:
                return "Bias-tee powers active antennas or mast LNA over the coax feed. Enable only if your RF chain supports DC power injection."
            }
        }

        var recommended: String {
            switch self {
            case .step:
                return "Typical: WFM 100 kHz, NFM 12.5 kHz, AM 9/10 kHz, SSB/CW 10-100 Hz for fine tuning."
            case .gain:
                return "Start with Auto. For weak signals use Manual around 35-49 dB and back off if noise/overload increases."
            case .squelch:
                return "For weak-signal work keep SQL near open. For local FM channels raise it until noise just closes."
            case .bfo:
                return "For FT8 keep near 0 Hz. For CW/SSB adjust until tone/voice sounds natural and stable."
            case .ppm:
                return "Calibrate on a known station; typical values are often within +/-40 PPM depending on dongle temperature."
            case .offsetTuning:
                return "Keep enabled for most users. Disable only if your server/hardware combination behaves better without it."
            case .biasTee:
                return "Keep disabled unless you intentionally power an active antenna/LNA that requires bias voltage."
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    sectionCard { connectionBar }
                    sectionCard { spectrumWaterfallSection }
                    sectionCard {
                        VStack(spacing: 14) {
                            frequencyDisplay
                            Divider()
                            modeSelector
                        }
                    }
                    sectionCard { controlsSection }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("CoronaSDR")
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
            .sheet(item: $helpTopic) { topic in
                controlHelpSheet(for: topic)
                    .presentationDetents([.medium, .large])
            }
            .onChange(of: viewModel.frequencyHz) { _, newFrequency in
                settings.lastFrequencyHz = newFrequency
            }
            .onChange(of: viewModel.mode) { _, newMode in
                settings.lastMode = newMode.rawValue
            }
            .onChange(of: viewModel.stepHz) { _, newStepHz in
                settings.lastStepHz = newStepHz
            }
            .onChange(of: viewModel.bandwidthHz) { _, newBandwidthHz in
                settings.lastBandwidthHz = newBandwidthHz
            }
            .onChange(of: viewModel.squelchLevel) { _, newSquelchLevel in
                settings.lastSquelchLevel = newSquelchLevel
            }
            .onChange(of: viewModel.bfoOffset) { _, newBFOOffset in
                settings.lastBFOOffset = newBFOOffset
            }
            .onChange(of: viewModel.gainMode) { _, newGainMode in
                settings.lastGainMode = newGainMode.rawValue
            }
            .onChange(of: viewModel.gainValue) { _, newGainValue in
                settings.lastGainValue = newGainValue
            }
            .onChange(of: viewModel.ppm) { _, newPPM in
                settings.lastPPM = newPPM
            }
            .onChange(of: viewModel.directSamplingPreference) { _, newValue in
                settings.directSamplingPreference = newValue.rawValue
            }
            .onChange(of: viewModel.isOffsetTuningEnabled) { _, newValue in
                settings.isOffsetTuningEnabled = newValue
            }
            .onChange(of: viewModel.isBiasTeeEnabled) { _, newValue in
                settings.isBiasTeeEnabled = newValue
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
                } else if viewModel.isAudioStarving {
                    Text("Audio Buffer Low")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                Text(String(format: "%.1f Mbps", viewModel.throughputMbps))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if viewModel.isDirectSamplingActive {
                Text("DS \(directSamplingModeLabel)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
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
        VStack(spacing: 8) {
            spectrumFrequencyScale

            ZStack {
                VStack(spacing: 0) {
                    // Waterfall + Metal Spectrum
                    if let renderer = viewModel.waterfallRenderer {
                        WaterfallView(renderer: renderer, isActive: viewModel.isPlaying && viewModel.isRadioTabVisible)
                            .frame(height: 320)
                            .accessibilityLabel("Spectrum and Waterfall display")
                    } else {
                        Rectangle()
                            .fill(Color.black)
                            .frame(height: 320)
                            .overlay {
                                Text("Metal not available")
                                    .foregroundStyle(.gray)
                            }
                    }
                }

                waterfallCenterMarker
                waterfallTuneMarker
                waterfallTuningOverlay
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack {
                Text("Span \(formatSpan(spectrumSpanHz))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Center \(formatAxisFrequency(viewModel.frequencyHz))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var spectrumFrequencyScale: some View {
        waterfallTickMarks
    }

    private let waterfallTickCount = 5

    private var waterfallTickMarks: some View {
        HStack(spacing: 0) {
            ForEach(0..<waterfallTickCount, id: \.self) { i in
                let fraction = Double(i) / Double(waterfallTickCount - 1)
                let hz = spectrumStartHz + Int(fraction * Double(spectrumSpanHz))
                let alignment: Alignment = i == 0 ? .leading : (i == waterfallTickCount - 1 ? .trailing : .center)
                VStack(spacing: 1) {
                    Text(formatAxisFrequency(hz))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrowtriangle.down.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: alignment)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Spectrum scale from \(formatAxisFrequency(spectrumStartHz)) to \(formatAxisFrequency(spectrumEndHz)), center \(formatAxisFrequency(viewModel.frequencyHz))")
    }

    private var waterfallCenterMarker: some View {
        GeometryReader { geometry in
            Path { path in
                let x = geometry.size.width / 2
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: geometry.size.height))
            }
            .stroke(
                Color.white.opacity(0.35),
                style: StrokeStyle(lineWidth: 1, dash: [5, 5])
            )
        }
        .allowsHitTesting(false)
    }

    @State private var waterfallDragStartFrequency: Int?
    @State private var waterfallTuneMarkerX: CGFloat?

    private var waterfallTuneMarker: some View {
        GeometryReader { geometry in
            if let markerX = waterfallTuneMarkerX {
                Path { path in
                    let x = min(max(0, markerX), geometry.size.width)
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                }
                .stroke(Color.accentColor, lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }

    private var waterfallTuningOverlay: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let width = geometry.size.width
                            guard width > 0 else { return }
                            if waterfallDragStartFrequency == nil {
                                waterfallDragStartFrequency = viewModel.frequencyHz
                            }
                            guard let startFreq = waterfallDragStartFrequency else { return }
                            let deltaFraction = value.translation.width / width
                            let deltaHz = Int(Double(spectrumSpanHz) * deltaFraction)
                            let newFreq = startFreq - deltaHz
                            viewModel.setFrequency(max(1_000, newFreq))
                            waterfallTuneMarkerX = value.location.x
                        }
                        .onEnded { _ in
                            waterfallDragStartFrequency = nil
                            waterfallTuneMarkerX = nil
                        }
                )
                .onTapGesture { location in
                    let width = geometry.size.width
                    guard width > 0 else { return }
                    let fraction = location.x / width
                    let tappedHz = spectrumStartHz + Int(fraction * Double(spectrumSpanHz))
                    viewModel.setFrequency(max(1_000, tappedHz))
                    waterfallTuneMarkerX = location.x
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        waterfallTuneMarkerX = nil
                    }
                }
        }
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
                        helpButton(.step)
                    }
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
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
        }
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
        }
        .padding(.vertical, 2)
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Direct Sampling")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(viewModel.isDirectSamplingActive ? "Active \(directSamplingModeLabel)" : "Inactive")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(viewModel.isDirectSamplingActive ? .orange : .secondary)
                }

                Picker("", selection: Binding(
                    get: { viewModel.directSamplingPreference },
                    set: { viewModel.setDirectSamplingPreference($0) }
                )) {
                    ForEach(DirectSamplingPreference.allCases, id: \.self) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    controlLabel("Offset", topic: .offsetTuning)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { viewModel.isOffsetTuningEnabled },
                        set: { viewModel.setOffsetTuningEnabled($0) }
                    ))
                    .labelsHidden()
                    .accessibilityLabel("Offset Tuning")
                    .disabled(!viewModel.supportsOffsetTuning)
                }

                HStack {
                    controlLabel("Bias", topic: .biasTee)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { viewModel.isBiasTeeEnabled },
                        set: { viewModel.setBiasTeeEnabled($0) }
                    ))
                    .labelsHidden()
                    .accessibilityLabel("Bias-Tee")
                    .disabled(!viewModel.supportsBiasTee)
                }

                if viewModel.directSamplingPreference == .auto && !viewModel.supportsDirectSamplingAuto {
                    Text("Auto direct sampling is not available for this tuner. Current behavior falls back to Off.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !viewModel.supportsBiasTee {
                    Text("Bias-tee control is unavailable for this tuner.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Gain
            HStack {
                controlLabel("Gain", topic: .gain)

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
                    controlLabel("SQL", topic: .squelch)

                    Slider(value: Binding(
                        get: { viewModel.squelchLevel },
                        set: { viewModel.setSquelch($0) }
                    ), in: 0...1)
                    .accessibilityLabel("Squelch level")

                    Circle()
                        .fill(viewModel.dspPipeline.isSquelchOpen ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                        .accessibilityLabel(viewModel.dspPipeline.isSquelchOpen ? "Squelch open" : "Squelch closed")

                    Text(viewModel.squelchThresholdDBFS.map { String(format: "%.1f dBFS", $0) } ?? "OPEN")
                        .font(.caption.monospacedDigit())
                        .frame(width: 84, alignment: .trailing)
                }

                HStack {
                    Text(String(format: "Noise %.1f dBFS", viewModel.squelchNoiseDBFS))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            // BFO offset (for SSB/CW)
            if viewModel.mode.usesBFO {
                HStack {
                    controlLabel("BFO", topic: .bfo)

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
                controlLabel("PPM", topic: .ppm)

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
    }

    @ViewBuilder
    private func sectionCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            }
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

    private func formatStep(_ hz: Int) -> String {
        if hz >= 1_000_000 { return String(format: "%.1f MHz", Double(hz) / 1_000_000) }
        if hz >= 1_000 { return String(format: "%.1f kHz", Double(hz) / 1_000) }
        return "\(hz) Hz"
    }

    private var directSamplingModeLabel: String {
        switch viewModel.directSamplingMode {
        case .off:
            return "Off"
        case .iBranch:
            return "I"
        case .qBranch:
            return "Q"
        }
    }

    private var spectrumSpanHz: Int {
        max(1, viewModel.dspPipeline.sampleRate)
    }

    private var spectrumStartHz: Int {
        max(0, viewModel.frequencyHz - (spectrumSpanHz / 2))
    }

    private var spectrumEndHz: Int {
        spectrumStartHz + spectrumSpanHz
    }

    private func formatSpan(_ hz: Int) -> String {
        if hz >= 1_000_000 { return String(format: "%.3f MHz", Double(hz) / 1_000_000) }
        if hz >= 1_000 { return String(format: "%.1f kHz", Double(hz) / 1_000) }
        return "\(hz) Hz"
    }

    private func formatAxisFrequency(_ hz: Int) -> String {
        if hz >= 1_000_000_000 {
            return String(format: "%.4f GHz", Double(hz) / 1_000_000_000)
        }
        if hz >= 1_000_000 {
            return String(format: "%.3f MHz", Double(hz) / 1_000_000)
        }
        if hz >= 1_000 {
            return String(format: "%.1f kHz", Double(hz) / 1_000)
        }
        return "\(hz) Hz"
    }

    private func controlLabel(_ text: String, topic: ControlHelpTopic) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.caption)
            helpButton(topic)
        }
        .frame(width: 72, alignment: .leading)
    }

    private func helpButton(_ topic: ControlHelpTopic) -> some View {
        Button {
            helpTopic = topic
        } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Help for \(topic.title)")
    }

    @ViewBuilder
    private func controlHelpSheet(for topic: ControlHelpTopic) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(topic.summary)
                        .font(.body)
                        .foregroundStyle(.primary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recommended")
                            .font(.headline)
                        Text(topic.recommended)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if topic == .ppm {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Tip")
                                .font(.headline)
                            Text("Let the dongle warm up for a few minutes before final PPM calibration. Frequency drift is normal at startup.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(topic.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
