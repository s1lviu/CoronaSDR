import SwiftUI
import SDRModels

@MainActor
private final class RadioViewModelStore: ObservableObject {
    let viewModel: RadioViewModel

    init() {
        self.viewModel = RadioViewModel()
    }
}

struct MainTabView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(DeepLinkCoordinator.self) private var deepLinkCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @StateObject private var viewModelStore = RadioViewModelStore()
    @State private var didApplyInitialState = false
    @State private var hasSeenActiveScene = false

    private var viewModel: RadioViewModel { viewModelStore.viewModel }

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
                applyInitialStateIfNeeded()
                updateRadioVisibility()
                if scenePhase == .active {
                    hasSeenActiveScene = true
                    viewModel.setAppActive(true)
                    attemptAutoReconnectIfNeeded()
                }
                processPendingDeepLinkIfNeeded()
            }
            .onChange(of: selectedTab) { _, newValue in
                viewModel.setRadioTabVisible(newValue == 0 && scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, newPhase in
                updateRadioVisibility()
                if newPhase == .active {
                    hasSeenActiveScene = true
                    viewModel.setAppActive(true)
                    attemptAutoReconnectIfNeeded()
                } else if hasSeenActiveScene {
                    viewModel.setAppActive(false)
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

    private func applyInitialStateIfNeeded() {
        guard !didApplyInitialState else { return }
        didApplyInitialState = true
        applyRuntimeSettings()
        restoreRadioDefaultsFromSettings()
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

    private func restoreRadioDefaultsFromSettings() {
        if let restoredMode = DemodMode(rawValue: settings.lastMode) {
            viewModel.setMode(restoredMode)
        }

        viewModel.stepHz = max(1, settings.lastStepHz)
        viewModel.setBandwidth(max(500, settings.lastBandwidthHz))
        viewModel.setSquelch(max(0, min(1, settings.lastSquelchLevel)))
        viewModel.setBFOOffset(max(-5_000, min(5_000, settings.lastBFOOffset)))

        if let restoredGainMode = GainMode(rawValue: settings.lastGainMode) {
            viewModel.setGain(mode: restoredGainMode, value: settings.lastGainValue)
        }

        viewModel.setPPM(settings.lastPPM)
        let maxTunableFrequencyHz = Int(UInt32.max)
        viewModel.setFrequency(max(1_000, min(maxTunableFrequencyHz, settings.lastFrequencyHz)))
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
        let maxTunableFrequencyHz = Int(UInt32.max)

        switch action {
        case .tune(let frequencyHz, let mode):
            if let mode {
                viewModel.setMode(mode)
            }
            viewModel.setFrequency(min(maxTunableFrequencyHz, max(1_000, frequencyHz)))
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
