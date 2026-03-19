import SwiftUI

struct FrequencyKeypadView: View {
    let frequencyHz: Int
    let onSubmit: (Int) -> Void

    private let directSamplingThresholdHz = 24_000_000

    @State private var input = ""
    @State private var unit: FreqUnit = .mhz
    @State private var cursorOffset = 0
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
                    inputDisplay
                        .padding(.horizontal)
                        .accessibilityLabel("Frequency input: \(input.isEmpty ? "empty" : input), cursor \(cursorOffset)")

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

                directSamplingHint

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
                unit = suggestedUnit(for: frequencyHz)
                input = formatValue(Double(frequencyHz) / unit.multiplier)
                cursorOffset = input.count
            }
            .onChange(of: unit) { oldValue, newValue in
                guard oldValue != newValue else { return }
                guard let value = Double(input) else {
                    return
                }
                let hz = value * oldValue.multiplier
                input = formatValue(hz / newValue.multiplier)
                cursorOffset = input.count
            }
        }
    }

    private var inputDisplay: some View {
        Group {
            if input.isEmpty {
                HStack(spacing: 0) {
                    Text("|")
                        .foregroundStyle(.tint)
                    Text("Enter frequency")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture {
                    cursorOffset = 0
                }
            } else {
                HStack(spacing: 0) {
                    let chars = Array(input)
                    ForEach(0...chars.count, id: \.self) { i in
                        ZStack {
                            Color.clear
                                .frame(width: 14, height: 44)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    cursorOffset = i
                                }
                            if cursorOffset == i {
                                Text("|")
                                    .foregroundStyle(.tint)
                            }
                        }
                        if i < chars.count {
                            Text(String(chars[i]))
                                .foregroundStyle(.primary)
                                .onTapGesture {
                                    cursorOffset = i + 1
                                }
                        }
                    }
                }
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(height: 44)
    }

    private var computedHz: Int? {
        guard let value = Double(input), value > 0 else { return nil }
        return Int(value * unit.multiplier)
    }

    private var showDirectSamplingHint: Bool {
        guard let hz = computedHz else { return false }
        return hz < directSamplingThresholdHz
    }

    private var directSamplingHint: some View {
        Text("Below 24 MHz, the app automatically enables Direct Sampling (Q).")
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(.horizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(showDirectSamplingHint ? 1 : 0)
    }

    private func handleKey(_ key: String) {
        switch key {
        case "DEL":
            handleDelete()
        case ".":
            guard !input.contains(".") else { return }
            insertAtCursor(".")
        default:
            insertAtCursor(key)
        }
    }

    private func handleDelete() {
        guard !input.isEmpty, cursorOffset > 0 else { return }
        let deleteIndex = input.index(input.startIndex, offsetBy: cursorOffset - 1)
        input.remove(at: deleteIndex)
        cursorOffset -= 1
    }

    private func insertAtCursor(_ token: String) {
        let safeOffset = max(0, min(cursorOffset, input.count))
        let idx = input.index(input.startIndex, offsetBy: safeOffset)
        input.insert(contentsOf: token, at: idx)
        cursorOffset = min(input.count, cursorOffset + token.count)
    }

    private func submitFrequency() {
        guard let hz = computedHz else { return }
        onSubmit(hz)
    }

    private func suggestedUnit(for hz: Int) -> FreqUnit {
        if hz >= 1_000_000_000 { return .ghz }
        if hz >= 1_000_000 { return .mhz }
        if hz >= 1_000 { return .khz }
        return .hz
    }

    private func formatValue(_ value: Double) -> String {
        let formatted = String(format: "%.6f", value)
        return formatted
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
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
