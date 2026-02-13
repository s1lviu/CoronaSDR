import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    @State private var viewModel = RadioViewModel()

    var body: some View {
        TabView(selection: $selectedTab) {
            RadioView(viewModel: viewModel)
                .tabItem {
                    Label("Radio", systemImage: "antenna.radiowaves.left.and.right")
                }
                .tag(0)

            StationsView()
                .tabItem {
                    Label("Stations", systemImage: "star.fill")
                }
                .tag(1)

            ScanView()
                .tabItem {
                    Label("Scan", systemImage: "magnifyingglass")
                }
                .tag(2)

            DiagnosticsView(viewModel: viewModel)
                .tabItem {
                    Label("Diagnostics", systemImage: "waveform.path.ecg")
                }
                .tag(3)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(4)
        }
        .onAppear {
            viewModel.setRadioTabVisible(selectedTab == 0)
        }
        .onChange(of: selectedTab) { _, newValue in
            viewModel.setRadioTabVisible(newValue == 0)
        }
    }
}
