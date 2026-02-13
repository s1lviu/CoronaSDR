import SwiftUI
import SwiftData
import SDRModels
import UniformTypeIdentifiers

struct StationsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Station.name) private var stations: [Station]
    @Query(sort: \Tag.name) private var tags: [Tag]

    @State private var searchText = ""
    @State private var selectedTag: Tag?
    @State private var showAddStation = false
    @State private var showImportExport = false
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var exportCSVContent = ""

    var filteredStations: [Station] {
        var result = stations
        if let tag = selectedTag {
            result = result.filter { $0.tags.contains(where: { $0.id == tag.id }) }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                String($0.frequencyHz).contains(searchText)
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                if !tags.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                tagChip(nil, label: "All")
                                ForEach(tags) { tag in
                                    tagChip(tag, label: tag.name)
                                }
                            }
                        }
                    }
                }

                ForEach(filteredStations) { station in
                    StationRow(station: station)
                }
                .onDelete(perform: deleteStations)
            }
            .searchable(text: $searchText, prompt: "Search stations")
            .navigationTitle("Stations")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showAddStation = true } label: {
                            Label("Add Station", systemImage: "plus")
                        }
                        Button { showImportExport = true } label: {
                            Label("Import/Export", systemImage: "arrow.up.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showAddStation) {
                AddStationView()
            }
            .sheet(isPresented: $showImportExport) {
                ImportExportSheet(stations: stations)
            }
            .overlay {
                if filteredStations.isEmpty {
                    ContentUnavailableView(
                        "No Stations",
                        systemImage: "star",
                        description: Text("Add stations to your favorites list.")
                    )
                }
            }
        }
    }

    private func tagChip(_ tag: Tag?, label: String) -> some View {
        Button {
            selectedTag = tag
        } label: {
            Text(label)
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selectedTag?.id == tag?.id ? Color.accentColor : Color(.systemGray5))
                .foregroundStyle(selectedTag?.id == tag?.id ? .white : .primary)
                .clipShape(Capsule())
        }
        .accessibilityLabel("\(label) tag filter")
    }

    private func deleteStations(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(filteredStations[index])
        }
    }
}

struct StationRow: View {
    let station: Station

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(station.name)
                    .font(.headline)
                Spacer()
                Text(station.mode.displayName)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.2))
                    .clipShape(Capsule())
            }

            Text(formatFrequency(station.frequencyHz))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            if !station.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(station.tags) { tag in
                        Text(tag.name)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.systemGray5))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(station.name), \(formatFrequency(station.frequencyHz)), \(station.mode.displayName)")
    }

    private func formatFrequency(_ hz: Int) -> String {
        if hz >= 1_000_000 {
            return String(format: "%.6f MHz", Double(hz) / 1_000_000)
        } else if hz >= 1_000 {
            return String(format: "%.3f kHz", Double(hz) / 1_000)
        }
        return "\(hz) Hz"
    }
}
