import SwiftUI
import SDRModels

struct ContentView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        if settings.hasCompletedOnboarding {
            MainTabView()
        } else {
            OnboardingFlow()
        }
    }
}
