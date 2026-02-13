import SwiftUI
import SwiftData
import SDRModels

struct ScanView: View {
    @State private var scanMode: ScanMode = .list
    @State private var isScanning = false
    @State private var currentFrequencyHz: Int = 0
    @State private var progress: Double = 0

    @Query(sort: \Station.name) private var stations: [Station]
    @State private var selectedStationIDs: Set<UUID> = []
    @State private var dwellTimeMs: Double = 2000
    @State private var holdTimeSec: Double = 5

    @State private var startFreqStr = "118.000"
    @State private var endFreqStr = "137.000"
    @State private var stepFreqStr = "25"

    enum ScanMode: String, CaseIterable {
        case list = "List Scan"
        case range = "Range Scan"
    }

    var body: some View {
        NavigationStack {
            Form {
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

                Section("Scan Control") {
                    if isScanning {
                        ProgressView(value: progress)
                        Text(currentFrequencyHz > 0 ? formatFrequency(currentFrequencyHz) : "Scanning...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Stop", role: .destructive) {
                            stopScan()
                        }
                    } else {
                        Button {
                            startScan()
                        } label: {
                            Label("Start Scan", systemImage: "play.fill")
                        }
                        .disabled(scanMode == .list && selectedStationIDs.isEmpty)
                    }
                }
            }
            .navigationTitle("Scan")
        }
    }

    private var listScanSection: some View {
        Group {
            Section("Select Stations") {
                ForEach(stations) { station in
                    HStack {
                        Image(systemName: selectedStationIDs.contains(station.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(station.name).font(.headline)
                            Text(formatFrequency(station.frequencyHz))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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

            Section("Timing") {
                HStack {
                    Text("Dwell")
                    Slider(value: $dwellTimeMs, in: 500...10000, step: 500)
                    Text(String(format: "%.1fs", dwellTimeMs / 1000))
                        .monospacedDigit()
                        .frame(width: 40)
                }

                HStack {
                    Text("Hold")
                    Slider(value: $holdTimeSec, in: 1...30, step: 1)
                    Text(String(format: "%.0fs", holdTimeSec))
                        .monospacedDigit()
                        .frame(width: 40)
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
                    Text("MHz")
                }

                HStack {
                    Text("End")
                    TextField("MHz", text: $endFreqStr)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    Text("MHz")
                }

                HStack {
                    Text("Step")
                    TextField("kHz", text: $stepFreqStr)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    Text("kHz")
                }
            }
        }
    }

    private func startScan() {
        isScanning = true
        progress = 0
        currentFrequencyHz = 0
    }

    private func stopScan() {
        isScanning = false
        progress = 0
        currentFrequencyHz = 0
    }

    private func formatFrequency(_ hz: Int) -> String {
        String(format: "%.6f MHz", Double(hz) / 1_000_000)
    }
}
