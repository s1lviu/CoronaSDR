import SwiftUI
import SDRDecoding

struct DecoderPanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var viewModel: RadioViewModel
    @State private var expanded = true
    @State private var selectedMessage: FT8Message?
    @State private var frozen: DecodeSnapshot?
    @State private var showHelp = false
    private var state: DecoderViewModel { viewModel.decodeState }
    private var display: DecodeSnapshot { frozen ?? state.snapshot }
    private var exportText: String {
        if state.mode == .cw { return display.transcript }
        return display.messages.map { "\($0.receivedAt.formatted()) (estimated) | \($0.frequencyHz) Hz USB + \(Int($0.audioHz)) Hz | \($0.text)" }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Decode", systemImage: "text.magnifyingglass").font(.headline)
                Spacer()
                Button { showHelp = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("About CW and FT8 decoding")
            }
            Picker("Decoder", selection: Binding(get: { state.mode }, set: {
                frozen = nil; viewModel.setDecoderMode($0)
            })) {
                ForEach(DecodeMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("decoder.mode")
            Text(state.snapshot.status).font(.subheadline).foregroundStyle(.secondary)
                .accessibilityLabel("Decoder status: \(state.snapshot.status)")
                .accessibilityIdentifier("decoder.status")
            if state.mode != .off {
                Text("\(viewModel.frequencyHz.formatted()) Hz · \(viewModel.mode.rawValue) · Receive only")
                    .font(.caption).monospacedDigit()
                Toggle("Mute listening audio", isOn: Binding(get: { state.monitorMuted }, set: viewModel.setMonitorMuted))
                if state.mode == .cw { cwControls }
                else {
                    ProgressView(value: state.snapshot.progress)
                        .accessibilityLabel("FT8 audio window collected")
                    Text("Collecting overlapping 18-second windows. Reception times are estimates; SNR and transmitter timing are unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let summary = state.snapshot.lastWindowSummary {
                        Text(summary).font(.caption)
                    }
                }
                if let interruption = state.snapshot.lastInterruption {
                    Text(interruption).font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Decoded results", isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        let actions = dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                            : AnyLayout(HStackLayout())
                        actions {
                            Button(frozen == nil ? "Freeze display" : "Show live results") {
                                frozen = frozen == nil ? state.snapshot : nil
                            }
                            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                            ShareLink(item: exportText) { Image(systemName: "square.and.arrow.up") }
                                .disabled(exportText.isEmpty).accessibilityLabel("Share decoded text")
                            Button("Clear", role: .destructive) { frozen = nil; viewModel.clearDecodeHistory() }
                        }.font(.subheadline)
                        if frozen != nil { Text("Display frozen. Reception continues.").font(.caption) }
                        ScrollView {
                          LazyVStack(alignment: .leading, spacing: 12) {
                           if state.mode == .cw {
                            Text(display.transcript.isEmpty ? "Decoded Morse text appears here. □ marks an uncertain character." : display.transcript)
                                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            if display.messages.isEmpty { Text("No messages yet. Keep the receiver tuned while audio is collected.").foregroundStyle(.secondary) }
                            ForEach(display.messages.reversed()) { message in
                                Button { selectedMessage = message } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(message.text).font(.system(.body, design: .monospaced))
                                        Text("\(message.receivedAt.formatted(date: .omitted, time: .standard)) estimated · \(Int(message.audioHz)) Hz audio")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                            }
                           }
                          }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 360)
                        .onScrollPhaseChange { _, phase in
                            if phase == .interacting && frozen == nil { frozen = state.snapshot }
                        }
                    }.padding(.top, 8)
                }
                Text("Decoding pauses in the background. Starting a scan stops decoding.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            while !Task.isCancelled {
                viewModel.refreshDecoder()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        .sheet(item: $selectedMessage) { message in
            NavigationStack {
                Form {
                    Section("Message") { Text(message.text).textSelection(.enabled) }
                    Section("Reception") {
                        LabeledContent("Dial frequency", value: "\(message.frequencyHz) Hz USB")
                        LabeledContent("Audio offset", value: "\(Int(message.audioHz)) Hz")
                        LabeledContent("Estimated RF frequency", value: "\(message.frequencyHz + Int(message.audioHz)) Hz")
                        LabeledContent("Local receive estimate", value: message.receivedAt.formatted())
                        Text("The receiver stream has no capture timestamp. Network delay and oscillator error are not measured.")
                    }
                    Section("Decoder") {
                        Text(message.supported ? "Parity and CRC checks passed." : "Valid payload; this message format is not supported.")
                        Text("Hashed callsigns may be unresolved or ambiguous. Decoding does not authenticate a sender.")
                        Text(message.payload).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }.navigationTitle("FT8 reception")
                    .toolbar { Button("Done") { selectedMessage = nil } }
            }
        }
        .sheet(isPresented: $showHelp) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("CW decodes one carrier centered on the tuned frequency. Listening pitch changes the tone without moving the selected carrier. Set a speed hint close to the sender; automatic tracking needs both dots and dashes. Hand sending and interference can produce errors.")
                        Text("FT8 selects USB with a 3.5 kHz receive filter and searches 200–3000 Hz audio. Standard messages, nonstandard callsigns, free text and telemetry are supported. Other FT8 variants can be unsupported. Weak or overlapping signals can be missed; an empty result does not mean the band is clear. No transmission or spotting is performed.")
                        Text("Your receiver, antenna and server must cover the tuned band. Mute affects listening only and resets when decoding is switched off. For silent reception, keep the app in the foreground; leaving it stops the silent session.")
                        Text("History is limited to 200 FT8 messages or 10,000 CW characters. Share text before clearing or closing the app if you want to keep it.")
                    }.padding()
                }.navigationTitle("Decoding help").toolbar { Button("Done") { showHelp = false } }
            }
        }
    }

    private var cwControls: some View {
        VStack(alignment: .leading) {
            Toggle("Track sending speed", isOn: Binding(get: { state.automaticSpeed }, set: {
                state.automaticSpeed = $0; viewModel.syncDecoder()
            }))
            Stepper("Speed hint: \(Int(state.speedWPM)) WPM", value: Binding(get: { state.speedWPM }, set: {
                state.speedWPM = $0; viewModel.syncDecoder()
            }), in: 5...60)
            if let wpm = state.snapshot.estimatedWPM { Text("Estimated speed: \(Int(wpm.rounded())) WPM").font(.caption) }
            Stepper("Listening pitch: \(Int(viewModel.bfoOffset == 0 ? 600 : abs(viewModel.bfoOffset))) Hz", value: Binding(
                get: { Double(viewModel.bfoOffset == 0 ? 600 : abs(viewModel.bfoOffset)) },
                set: { viewModel.setBFOOffset(Float($0)) }), in: 300...1200, step: 50)
        }
    }
}
