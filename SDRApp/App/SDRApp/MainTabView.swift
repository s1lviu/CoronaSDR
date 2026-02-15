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
        deepLinkAwareTabs
    }

    private var tabs: some View {
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
    }

    private var lifecycleAwareTabs: some View {
        tabs
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
    }

    private var profileAwareTabs: some View {
        lifecycleAwareTabs
            .onChange(of: settings.selectedSampleProfileLabel) { _, newLabel in
                viewModel.applySampleProfile(label: newLabel)
            }
            .onChange(of: settings.waterfallColorScheme) { _, newScheme in
                viewModel.applyWaterfallColorScheme(newScheme)
            }
            .onChange(of: settings.deemphasis) { _, newValue in
                viewModel.applyDeemphasis(newValue)
            }
    }

    private var rfAwareTabs: some View {
        profileAwareTabs
            .onChange(of: settings.directSamplingPreference) { _, newValue in
                viewModel.setDirectSamplingPreference(directSamplingPreference(from: newValue))
            }
            .onChange(of: settings.isOffsetTuningEnabled) { _, newValue in
                viewModel.setOffsetTuningEnabled(newValue)
            }
            .onChange(of: settings.isBiasTeeEnabled) { _, newValue in
                viewModel.setBiasTeeEnabled(newValue)
            }
    }

    private var audioFilterAwareTabs: some View {
        rfAwareTabs
            .onChange(of: settings.audioHighPassHz) { _, _ in
                applyAudioToneSettings()
            }
            .onChange(of: settings.audioLowPassHz) { _, _ in
                applyAudioToneSettings()
            }
    }

    private var deepLinkAwareTabs: some View {
        audioFilterAwareTabs
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
        viewModel.applyRFControls(
            directSamplingPreference: directSamplingPreference(from: settings.directSamplingPreference),
            offsetTuningEnabled: settings.isOffsetTuningEnabled,
            biasTeeEnabled: settings.isBiasTeeEnabled
        )
        applyAudioToneSettings()
    }

    private func applyAudioToneSettings() {
        viewModel.setAudioToneFilters(
            highPassHz: settings.audioHighPassHz,
            lowPassHz: settings.audioLowPassHz
        )
        if settings.audioHighPassHz != viewModel.audioHighPassHz {
            settings.audioHighPassHz = viewModel.audioHighPassHz
        }
        if settings.audioLowPassHz != viewModel.audioLowPassHz {
            settings.audioLowPassHz = viewModel.audioLowPassHz
        }
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

    private func directSamplingPreference(from rawValue: String) -> DirectSamplingPreference {
        DirectSamplingPreference(rawValue: rawValue) ?? .auto
    }
}
