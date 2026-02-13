import SwiftUI

struct FrequencyKeypadView: View {
    let frequencyHz: Int
    let onSubmit: (Int) -> Void

    private let directSamplingThresholdHz = 24_000_000

    @State private var input = ""
    @State private var unit: FreqUnit = .mhz
    @Environment(\.dismiss) private var dismiss

    enum FreqUnit: String, CaseIterable {
        case hz = "Hz"
        case khz = "kHz"
        case mhz = "MHz"
        case ghz = "GHz"

        var multiplier: Double {
            switch self {
            case .hz: return 1
            case .khz: return 1_000
            case .mhz: return 1_000_000
            case .ghz: return 1_000_000_000
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Display
                VStack(spacing: 4) {
                    Text(input.isEmpty ? "Enter frequency" : input)
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal)
                        .accessibilityLabel("Frequency input: \(input.isEmpty ? "empty" : input)")

                    // Unit picker
                    Picker("Unit", selection: $unit) {
                        ForEach(FreqUnit.allCases, id: \.self) { u in
                            Text(u.rawValue).tag(u)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }

                // Keypad
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "0", "DEL"], id: \.self) { key in
                        Button {
                            handleKey(key)
                        } label: {
                            Text(key)
                                .font(.title2.bold())
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .background(Color(.systemGray5))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .accessibilityLabel(key == "DEL" ? "Delete" : key)
                    }
                }
                .padding(.horizontal)

                if let hz = computedHz, hz < directSamplingThresholdHz {
                    Text("Sub 24 MHz aplicația va activa automat Direct Sampling (Q).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Quick presets
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        presetButton("FM", freq: 100_000_000)
                        presetButton("Air", freq: 118_000_000)
                        presetButton("2m", freq: 144_000_000)
                        presetButton("70cm", freq: 432_000_000)
                        presetButton("MW", freq: 1_000_000)
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Set Frequency")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") { submitFrequency() }
                        .disabled(computedHz == nil)
                        .bold()
                }
            }
            .onAppear {
                input = String(format: "%.6f", Double(frequencyHz) / unit.multiplier)
            }
        }
    }

    private var computedHz: Int? {
        guard let value = Double(input), value > 0 else { return nil }
        return Int(value * unit.multiplier)
    }

    private func handleKey(_ key: String) {
        switch key {
        case "DEL":
            if !input.isEmpty { input.removeLast() }
        case ".":
            if !input.contains(".") { input += "." }
        default:
            input += key
        }
    }

    private func submitFrequency() {
        guard let hz = computedHz else { return }
        onSubmit(hz)
    }

    private func presetButton(_ label: String, freq: Int) -> some View {
        Button {
            onSubmit(freq)
        } label: {
            Text(label)
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.tint.opacity(0.2))
                .clipShape(Capsule())
        }
        .accessibilityLabel("\(label) preset")
    }
}
