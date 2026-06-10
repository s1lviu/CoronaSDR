import SwiftUI
import SwiftData
import SDRModels
import UniformTypeIdentifiers

struct ImportExportSheet: View {
    let stations: [Station]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var showFilePicker = false
    @State private var showFileExporter = false
    @State private var statusMessage: String?
    @State private var exportDocument = CSVExportDocument(content: "")

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

                if let result = statusMessage {
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
            .fileExporter(
                isPresented: $showFileExporter,
                document: exportDocument,
                contentType: .commaSeparatedText,
                defaultFilename: "stations.csv"
            ) { result in
                switch result {
                case .success:
                    statusMessage = "Exported \(stations.count) stations"
                case .failure(let error):
                    statusMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func exportStations() {
        exportDocument = CSVExportDocument(content: CSVImportExport.exportCSV(stations: stations))
        showFileExporter = true
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            guard url.startAccessingSecurityScopedResource() else {
                statusMessage = "Could not access file"
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

                statusMessage = "Imported \(importedCount) stations"
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }

        case .failure(let error):
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }
}

private struct CSVExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    var content: String

    init(content: String) {
        self.content = content
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let content = String(data: data, encoding: .utf8) else {
            self.content = ""
            return
        }
        self.content = content
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(content.utf8))
    }
}
