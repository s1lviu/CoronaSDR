import SwiftUI
import SDRModels
import SDRSupport

struct MainTabView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(DeepLinkCoordinator.self) private var deepLinkCoordinator
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

            StationsView(viewModel: viewModel)
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
            viewModel.setAppActive(scenePhase == .active)
            if scenePhase == .active {
                attemptAutoReconnectIfNeeded()
            }
            processPendingDeepLinkIfNeeded()
        }
        .onChange(of: selectedTab) { _, newValue in
            viewModel.setRadioTabVisible(newValue == 0 && scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, _ in
            updateRadioVisibility()
            viewModel.setAppActive(scenePhase == .active)
            if scenePhase == .active {
                attemptAutoReconnectIfNeeded()
            }
        }
        .onChange(of: settings.selectedSampleProfileLabel) { _, newLabel in
            viewModel.applySampleProfile(label: newLabel)
        }
        .onChange(of: settings.waterfallColorScheme) { _, newScheme in
            viewModel.applyWaterfallColorScheme(newScheme)
        }
        .onChange(of: settings.deemphasis) { _, newValue in
            viewModel.applyDeemphasis(newValue)
        }
        .onChange(of: deepLinkCoordinator.lastEventToken) { _, _ in
            processPendingDeepLinkIfNeeded()
        }
    }

    private func updateRadioVisibility() {
        viewModel.setRadioTabVisible(selectedTab == 0 && scenePhase == .active)
    }

    private func applyRuntimeSettings() {
        viewModel.applySampleProfile(label: settings.selectedSampleProfileLabel)
        viewModel.applyWaterfallColorScheme(settings.waterfallColorScheme)
        viewModel.applyDeemphasis(settings.deemphasis)
    }

    private func attemptAutoReconnectIfNeeded() {
        viewModel.autoConnectIfConfigured(
            host: settings.lastServerHost,
            port: UInt16(settings.lastServerPort)
        )
    }

    private func processPendingDeepLinkIfNeeded() {
        guard let action = deepLinkCoordinator.consumePendingAction() else { return }
        selectedTab = 0

        switch action {
        case .tune(let frequencyHz, let mode):
            if let mode {
                viewModel.setMode(mode)
            }
            viewModel.setFrequency(max(1_000, frequencyHz))
            viewModel.requestStartListeningWhenConnected()
            attemptAutoReconnectIfNeeded()

        case .start:
            viewModel.requestStartListeningWhenConnected()
            attemptAutoReconnectIfNeeded()

        case .stop:
            viewModel.cancelPendingStartListening()
            viewModel.stopListening()
        }
    }
}
