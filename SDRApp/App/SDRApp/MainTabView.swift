import SwiftUI
import SDRModels
import SDRSupport

struct MainTabView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
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

            ScanView(viewModel: viewModel)
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
            applyRuntimeSettings()
            updateRadioVisibility()
        }
        .onChange(of: selectedTab) { _, newValue in
            viewModel.setRadioTabVisible(newValue == 0 && scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, _ in
            updateRadioVisibility()
        }
        .onChange(of: settings.selectedSampleProfileLabel) { _, newLabel in
            viewModel.applySampleProfile(label: newLabel)
        }
        .onChange(of: settings.waterfallColorScheme) { _, newScheme in
            viewModel.applyWaterfallColorScheme(newScheme)
        }
        .onChange(of: settings.spectrumPeakHold) { _, isEnabled in
            viewModel.applySpectrumPeakHold(isEnabled)
        }
        .onChange(of: settings.deemphasis) { _, newValue in
            viewModel.applyDeemphasis(newValue)
        }
        .onChange(of: settings.debugLogsEnabled) { _, isEnabled in
            SDRDebug.setEnabled(isEnabled)
        }
    }

    private func updateRadioVisibility() {
        viewModel.setRadioTabVisible(selectedTab == 0 && scenePhase == .active)
    }

    private func applyRuntimeSettings() {
        viewModel.applySampleProfile(label: settings.selectedSampleProfileLabel)
        viewModel.applyWaterfallColorScheme(settings.waterfallColorScheme)
        viewModel.applySpectrumPeakHold(settings.spectrumPeakHold)
        viewModel.applyDeemphasis(settings.deemphasis)
        SDRDebug.setEnabled(settings.debugLogsEnabled)
    }
}
