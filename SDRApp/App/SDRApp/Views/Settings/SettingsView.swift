import SwiftUI
import SDRModels

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section("Display") {
                    Picker("Waterfall Palette", selection: $settings.waterfallColorScheme) {
                        Text("Classic").tag("classic")
                        Text("Thermal").tag("thermal")
                        Text("Grayscale").tag("grayscale")
                    }

                    Toggle("Spectrum Peak Hold", isOn: $settings.spectrumPeakHold)
                        .accessibilityLabel("Enable spectrum peak hold display")
                }

                Section("Audio") {
                    Picker("FM De-emphasis", selection: $settings.deemphasis) {
                        Text("50 \u{00B5}s (Europe)").tag(50)
                        Text("75 \u{00B5}s (Americas)").tag(75)
                    }

                    Text("Used by FM demodulation modes (NFM/WFM).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Performance") {
                    Picker("Processing Profile", selection: $settings.selectedSampleProfileLabel) {
                        Text("Ultra Low (250k SPS)").tag("Ultra Low")
                        Text("Low (1.024 MSPS)").tag("Low")
                        Text("Medium (2.048 MSPS)").tag("Medium")
                        Text("High (2.4 MSPS)").tag("High")
                    }

                    Text("Lower profiles reduce CPU/GPU load, heat, and battery usage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Server") {
                    HStack {
                        Text("Last Server")
                        Spacer()
                        Text(settings.lastServerHost.isEmpty ? "None" : "\(settings.lastServerHost):\(settings.lastServerPort)")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Diagnostics") {
                    Toggle("Debug Logs", isOn: $settings.debugLogsEnabled)
                        .accessibilityLabel("Enable debug logging")

                    Text("Enable only while troubleshooting; can impact performance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Advanced") {
                    Button("Run Onboarding Again") {
                        settings.hasCompletedOnboarding = false
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
