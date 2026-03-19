import SwiftUI
import SwiftData
import SDRModels
import UIKit

struct ScanView: View {
    let viewModel: RadioViewModel

    private enum FocusField: Hashable {
        case start
        case end
        case step
    }

    @State private var scanMode: ScanMode = .list
    @State private var rangeMode: DemodMode = .nfm

    @Query(sort: \Station.name) private var stations: [Station]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @State private var selectedStationIDs: Set<UUID> = []
    @State private var selectedScanTag: Tag?

    @State private var dwellTimeMs: Double = 1500
    @State private var holdTimeSec: Double = 5

    @State private var startFreqStr = "118.000"
    @State private var endFreqStr = "137.000"
    @State private var stepFreqStr = "25"

    @State private var validationError: String?
    @FocusState private var focusedField: FocusField?

    enum ScanMode: String, CaseIterable {
        case list = "List Scan"
        case range = "Range Scan"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    row("Connection", value: viewModel.isConnected ? "Connected" : "Disconnected")
                    row("Playback", value: viewModel.isPlaying ? "Active" : "Stopped")
                    row("Scan State", value: scanStateText)
                    row("Current", value: currentFrequencyText)
                }

                Section {
                    Picker("Scan Type", selection: $scanMode) {
                        ForEach(ScanMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                switch scanMode {
                case .list:
                    listScanSection
                case .range:
                    rangeScanSection
                }

                timingSection
                scanControlSection
            }
            .scrollDismissesKeyboard(.immediately)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if focusedField != nil {
                    HStack(spacing: 12) {
                        Button("Previous") {
                            focusPreviousField()
                        }
                        .disabled(focusedField == .start)

                        Button("Next") {
                            focusNextField()
                        }
                        .disabled(focusedField == .step)

                        Spacer()

                        Button("Done") {
                            dismissKeyboard()
                        }
                        .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)
                }
            }
            .navigationTitle("Scan")
            .alert("Cannot Start Scan", isPresented: Binding(
                get: { validationError != nil },
                set: { if !$0 { validationError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationError ?? "Unknown error")
            }
        }
    }

    private var visibleStations: [Station] {
        guard let tag = selectedScanTag else { return stations }
        return stations.filter { $0.tags.contains(where: { $0.id == tag.id }) }
    }

    private var listScanSection: some View {
        Group {
            if !tags.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            scanTagChip(nil, label: "All")
                            ForEach(tags) { tag in
                                scanTagChip(tag, label: tag.name)
                            }
                        }
                    }
                }
            }

            Section("Select Stations") {
                if visibleStations.isEmpty {
                    Text(selectedScanTag != nil
                         ? "No stations with this tag."
                         : "No stations saved. Add stations in the Stations tab first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("Select All") {
                            selectedStationIDs = Set(visibleStations.map(\.id))
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                        Button("Clear") {
                            selectedStationIDs.removeAll()
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    }
                    .font(.caption)

                    ForEach(visibleStations) { station in
                        HStack {
                            Image(systemName: selectedStationIDs.contains(station.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text(station.name).font(.headline)
                                Text("\(formatFrequency(station.frequencyHz)) • \(station.mode.displayName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedStationIDs.contains(station.id) {
                                selectedStationIDs.remove(station.id)
                            } else {
                                selectedStationIDs.insert(station.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private var rangeScanSection: some View {
        Group {
            Section("Frequency Range") {
                HStack {
                    Text("Start")
                    TextField("MHz", text: $startFreqStr)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .start)
                    Text("MHz")
                }

                HStack {
                    Text("End")
                    TextField("MHz", text: $endFreqStr)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .end)
                    Text("MHz")
                }

                HStack {
                    Text("Step")
                    TextField("kHz", text: $stepFreqStr)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .step)
                    Text("kHz")
                }

                Picker("Mode", selection: $rangeMode) {
                    ForEach(DemodMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
        }
    }

    private var timingSection: some View {
        Section("Timing") {
            HStack {
                Text("Dwell")
                Slider(value: $dwellTimeMs, in: 500...10_000, step: 100)
                Text(String(format: "%.1fs", dwellTimeMs / 1000))
                    .monospacedDigit()
                    .frame(width: 48)
            }

            HStack {
                Text("Hold")
                Slider(value: $holdTimeSec, in: 1...30, step: 1)
                Text(String(format: "%.0fs", holdTimeSec))
                    .monospacedDigit()
                    .frame(width: 48)
            }
        }
    }

    private var scanControlSection: some View {
        Section("Scan Control") {
            if isScanning {
                ProgressView(value: max(0, min(1, viewModel.scanEngine.progress)))
                Text("\(scanStateText) • \(currentFrequencyText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        viewModel.skipScanStep()
                    } label: {
                        Label("Skip", systemImage: "forward.end.fill")
                    }

                    Spacer()

                    Button("Stop", role: .destructive) {
                        viewModel.stopScan()
                    }
                }
            } else {
                Button {
                    startScan()
                } label: {
                    Label("Start Scan", systemImage: "play.fill")
                }

                if !viewModel.isConnected {
                    Text("Connect to server first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isScanning: Bool {
        switch viewModel.scanEngine.state {
        case .idle:
            return false
        case .scanning, .holding, .paused:
            return true
        }
    }

    private var currentFrequencyText: String {
        let hz = viewModel.scanEngine.currentFrequencyHz
        return hz > 0 ? formatFrequency(hz) : "—"
    }

    private var scanStateText: String {
        switch viewModel.scanEngine.state {
        case .idle:
            return "Idle"
        case .scanning:
            return "Scanning"
        case .holding(let frequencyHz):
            return "Holding \(formatFrequency(frequencyHz))"
        case .paused:
            return "Paused"
        }
    }

    private func startScan() {
        validationError = nil
        dismissKeyboard()

        guard case .connected = viewModel.connectionState else {
            validationError = "Connect to server first."
            return
        }

        switch scanMode {
        case .list:
            let entries = visibleStations
                .filter { selectedStationIDs.contains($0.id) }
                .map { (hz: $0.frequencyHz, mode: $0.mode) }
            guard !entries.isEmpty else {
                validationError = "Select at least one station."
                return
            }
            let started = viewModel.startListScan(
                frequencies: entries,
                dwellMs: Int(dwellTimeMs.rounded()),
                holdSec: Int(holdTimeSec.rounded())
            )
            if !started {
                validationError = "Could not start scan. Verify connection and audio session."
            }

        case .range:
            guard let range = parseRangeInputs(emitError: true) else { return }
            let started = viewModel.startRangeScan(
                startHz: range.startHz,
                endHz: range.endHz,
                stepHz: range.stepHz,
                mode: rangeMode,
                dwellMs: Int(dwellTimeMs.rounded()),
                holdSec: Int(holdTimeSec.rounded())
            )
            if !started {
                validationError = "Could not start scan. Verify connection and audio session."
            }
        }
    }

    private func parseRangeInputs(emitError: Bool) -> (startHz: Int, endHz: Int, stepHz: Int)? {
        guard let startMHz = Double(startFreqStr),
              let endMHz = Double(endFreqStr),
              let stepKHz = Double(stepFreqStr) else {
            if emitError { validationError = "Enter valid numeric values for Start, End, and Step." }
            return nil
        }

        let startHz = Int((startMHz * 1_000_000).rounded())
        let endHz = Int((endMHz * 1_000_000).rounded())
        let stepHz = Int((stepKHz * 1_000).rounded())

        guard startHz > 0, endHz > 0, stepHz > 0 else {
            if emitError { validationError = "Start, End, and Step must be positive." }
            return nil
        }
        guard endHz > startHz else {
            if emitError { validationError = "End frequency must be greater than Start." }
            return nil
        }
        guard stepHz <= (endHz - startHz) else {
            if emitError { validationError = "Step is too large for the selected range." }
            return nil
        }

        return (startHz, endHz, stepHz)
    }

    private func scanTagChip(_ tag: Tag?, label: String) -> some View {
        Button {
            selectedScanTag = tag
        } label: {
            Text(label)
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selectedScanTag?.id == tag?.id ? Color.accentColor : Color(.systemGray5))
                .foregroundStyle(selectedScanTag?.id == tag?.id ? .white : .primary)
                .clipShape(Capsule())
        }
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit())
        }
    }

    private func formatFrequency(_ hz: Int) -> String {
        if hz >= 1_000_000 {
            return String(format: "%.6f MHz", Double(hz) / 1_000_000)
        }
        if hz >= 1_000 {
            return String(format: "%.3f kHz", Double(hz) / 1_000)
        }
        return "\(hz) Hz"
    }

    private func focusPreviousField() {
        switch focusedField {
        case .end:
            focusedField = .start
        case .step:
            focusedField = .end
        default:
            break
        }
    }

    private func focusNextField() {
        switch focusedField {
        case .start:
            focusedField = .end
        case .end:
            focusedField = .step
        default:
            break
        }
    }

    private func dismissKeyboard() {
        focusedField = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
