import SwiftUI
import SwiftData
import SDRModels
import UniformTypeIdentifiers

struct StationsView: View {
    @Environment(\.modelContext) private var modelContext
    let viewModel: RadioViewModel

    @Query(sort: \Station.name) private var stations: [Station]
    @Query(sort: \Tag.name) private var tags: [Tag]

    @State private var searchText = ""
    @State private var selectedTag: Tag?
    @State private var showAddStation = false
    @State private var showImportExport = false
    @State private var playErrorMessage: String?

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
                    StationRow(
                        station: station,
                        onPlay: { play(station) }
                    )
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
            .alert("Cannot Start Station", isPresented: Binding(
                get: { playErrorMessage != nil },
                set: { if !$0 { playErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(playErrorMessage ?? "Unknown error")
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

    private func play(_ station: Station) {
        guard viewModel.isConnected else {
            playErrorMessage = "Connect to server first from the Radio tab (Wi-Fi button)."
            return
        }

        viewModel.setMode(station.mode)
        viewModel.setBandwidth(station.bandwidthHz)
        viewModel.stepHz = station.stepHz
        viewModel.setSquelch(station.squelch)
        viewModel.setGain(mode: station.gainMode, value: station.gainValue)
        viewModel.setPPM(station.ppm)
        viewModel.setFrequency(station.frequencyHz)
        viewModel.startListening()

        station.lastUsedAt = Date()
        station.updatedAt = Date()
        try? modelContext.save()
    }
}

struct StationRow: View {
    let station: Station
    let onPlay: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(station.name)
                    .font(.headline)

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

            Spacer(minLength: 8)
            actionCluster
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            onPlay()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(station.name), \(formatFrequency(station.frequencyHz)), \(station.mode.displayName)")
    }

    private var actionCluster: some View {
        VStack(spacing: 8) {
            Button {
                onPlay()
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(station.name)")

            Text(station.mode.displayName)
                .font(.subheadline.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.tint.opacity(0.2))
                .clipShape(Capsule())
        }
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
