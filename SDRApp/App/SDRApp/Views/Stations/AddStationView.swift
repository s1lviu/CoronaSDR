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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.isEmpty || frequencyStr.isEmpty)
                        .bold()
                }
            }
        }
    }

    private func save() {
        guard let freqMHz = Double(frequencyStr) else { return }
        let freqHz = Int(freqMHz * 1_000_000)

        let station = Station(name: name, frequencyHz: freqHz, mode: mode)

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
        dismiss()
    }
}
