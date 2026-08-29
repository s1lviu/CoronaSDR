import SwiftUI
import SwiftData
import SDRModels

struct AddStationView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var frequencyStr = ""
    @State private var mode: DemodMode = .nfm
    @State private var tagsStr = ""
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Station Info") {
                    TextField("Name", text: $name)
                        .accessibilityLabel("Station name")

                    TextField("Frequency (MHz)", text: $frequencyStr)
                        .keyboardType(.decimalPad)
                        .accessibilityLabel("Frequency in MHz")

                    Picker("Mode", selection: $mode) {
                        ForEach(DemodMode.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .accessibilityLabel("Demodulation mode")
                }

                Section("Tags (comma separated)") {
                    TextField("e.g. Airband, Local", text: $tagsStr)
                        .accessibilityLabel("Tags")
                }
            }
            .navigationTitle("Add Station")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Cannot Save Station", isPresented: Binding(
                get: { validationMessage != nil },
                set: { if !$0 { validationMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationMessage ?? "Unknown error")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(trimmedName.isEmpty || trimmedFrequency.isEmpty)
                        .bold()
                }
            }
        }
    }

    private func save() {
        validationMessage = nil

        guard !trimmedName.isEmpty else {
            validationMessage = "Station name is required."
            return
        }

        guard let freqMHz = parseFrequencyMHz(trimmedFrequency) else {
            validationMessage = "Frequency format is invalid. Example: 99.5"
            return
        }

        let freqHz = Int((freqMHz * 1_000_000).rounded())
        guard freqHz >= 1_000 else {
            validationMessage = "Frequency must be greater than 0."
            return
        }

        let station = Station(name: trimmedName, frequencyHz: freqHz, mode: mode)

        // Parse and create tags
        let tagNames = tagsStr.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for tagName in tagNames {
            let descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.name == tagName })
            if let existing = try? modelContext.fetch(descriptor).first {
                station.tags.append(existing)
            } else {
                let newTag = Tag(name: tagName)
                modelContext.insert(newTag)
                station.tags.append(newTag)
            }
        }

        modelContext.insert(station)
        do {
            try modelContext.save()
            dismiss()
        } catch {
            validationMessage = "Could not save station: \(error.localizedDescription)"
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedFrequency: String {
        frequencyStr.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseFrequencyMHz(_ raw: String) -> Double? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale.current
        if let number = formatter.number(from: raw) {
            return number.doubleValue
        }

        // Fallback for mixed separators (e.g. comma entered on some keyboards/locales).
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }
}
