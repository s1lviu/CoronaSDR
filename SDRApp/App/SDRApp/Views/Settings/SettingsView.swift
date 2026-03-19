import SwiftUI
import SDRModels

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    private let landingPageURL = URL(string: "https://coronasdr.pages.dev/")!
    private let issuesURL = URL(string: "https://github.com/s1lviu/CoronaSDR/issues")!

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
                }

                Section("Audio") {
                    Picker("FM De-emphasis", selection: $settings.deemphasis) {
                        Text("50 \u{00B5}s (Europe)").tag(50)
                        Text("75 \u{00B5}s (Americas)").tag(75)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Audio High-pass")
                            Spacer()
                            Text(settings.audioHighPassHz == 0 ? "Off" : "\(settings.audioHighPassHz) Hz")
                                .foregroundStyle(.secondary)
                                .font(.caption.monospacedDigit())
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.audioHighPassHz) },
                                set: { settings.audioHighPassHz = Int($0.rounded()) }
                            ),
                            in: 0...3_000,
                            step: 25
                        )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Audio Low-pass")
                            Spacer()
                            Text(settings.audioLowPassHz == 0 ? "Off" : "\(settings.audioLowPassHz) Hz")
                                .foregroundStyle(.secondary)
                                .font(.caption.monospacedDigit())
                        }
                        Slider(
                            value: Binding(
                                get: { Double(settings.audioLowPassHz) },
                                set: { settings.audioLowPassHz = Int($0.rounded()) }
                            ),
                            in: 0...20_000,
                            step: 100
                        )
                    }

                    Text("De-emphasis is used by FM modes. HP/LP apply to demodulated audio in all modes (0 = Off).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("When both HP and LP are active, HP is automatically clamped below LP.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("RF Controls") {
                    Picker("Direct Sampling", selection: $settings.directSamplingPreference) {
                        ForEach(DirectSamplingPreference.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }

                    Toggle("Offset Tuning", isOn: $settings.isOffsetTuningEnabled)
                    Toggle("Bias-Tee", isOn: $settings.isBiasTeeEnabled)

                    Text("Availability depends on tuner hardware and server support.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Performance") {
                    Picker("Processing Profile", selection: $settings.selectedSampleProfileLabel) {
                        Section("RTL-SDR") {
                            Text("Ultra Low (250k SPS)").tag("Ultra Low")
                            Text("Low (1.024 MSPS)").tag("Low")
                            Text("Medium (2.048 MSPS)").tag("Medium")
                            Text("High (2.4 MSPS)").tag("High")
                        }
                        Section("Airspy HF+") {
                            Text("HF+ Low (192k SPS)").tag("HF+ Low")
                            Text("HF+ High (768k SPS)").tag("HF+ High")
                        }
                    }

                    Text("Lower profiles reduce CPU/GPU load, heat, and battery usage. Select an HF+ profile when using an Airspy HF+ Discovery via hfp_tcp.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Server") {
                    HStack {
                        Text("Last Server")
                        Spacer()
                        Text(settings.lastServerHost.isEmpty ? "None" : "\(settings.lastServerHost):\(String(settings.lastServerPort))")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Build")
                        Spacer()
                        Text(appBuild)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("The app was built by Silviu YO6SAY for the radio community.")
                        Text("Free to use, with updates and support provided on a best-effort basis.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Link(destination: landingPageURL) {
                        HStack {
                            Text("Project Website")
                            Spacer()
                            Text("coronasdr.pages.dev")
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Link(destination: issuesURL) {
                        HStack {
                            Text("Issues")
                            Spacer()
                            Text("github.com/s1lviu/CoronaSDR/issues")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

            }
            .navigationTitle("Settings")
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
