import SwiftUI
import SwiftData
import SDRModels
import UniformTypeIdentifiers

struct ImportExportSheet: View {
    let stations: [Station]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var showFilePicker = false
    @State private var importResult: String?
    @State private var exportContent = ""
    @State private var showShareSheet = false

    var body: some View {
        NavigationStack {
            List {
                Section("Export") {
                    Button {
                        exportStations()
                    } label: {
                        Label("Export \(stations.count) stations as CSV", systemImage: "square.and.arrow.up")
                    }
                    .disabled(stations.isEmpty)
                }

                Section("Import") {
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Import from CSV/TSV file", systemImage: "square.and.arrow.down")
                    }
                }

                if let result = importResult {
                    Section {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Import / Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText]
            ) { result in
                handleImport(result)
            }
            .sheet(isPresented: $showShareSheet) {
                if !exportContent.isEmpty {
                    ShareSheet(text: exportContent)
                }
            }
        }
    }

    private func exportStations() {
        exportContent = CSVImportExport.exportCSV(stations: stations)
        showShareSheet = true
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            guard url.startAccessingSecurityScopedResource() else {
                importResult = "Could not access file"
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                let rows = CSVImportExport.parseCSV(content)
                var importedCount = 0

                for row in rows {
                    let station = Station(
                        name: row.name,
                        frequencyHz: row.frequencyHz,
                        mode: row.mode,
                        bandwidthHz: row.bandwidthHz,
                        stepHz: row.stepHz,
                        squelch: row.squelch
                    )

                    for tagName in row.tagNames {
                        let descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.name == tagName })
                        if let existing = try modelContext.fetch(descriptor).first {
                            station.tags.append(existing)
                        } else {
                            let newTag = Tag(name: tagName)
                            modelContext.insert(newTag)
                            station.tags.append(newTag)
                        }
                    }

                    modelContext.insert(station)
                    importedCount += 1
                }

                importResult = "Imported \(importedCount) stations"
            } catch {
                importResult = "Error: \(error.localizedDescription)"
            }

        case .failure(let error):
            importResult = "Error: \(error.localizedDescription)"
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let data = text.data(using: .utf8)!
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("stations.csv")
        try? data.write(to: tmpURL)
        return UIActivityViewController(activityItems: [tmpURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
