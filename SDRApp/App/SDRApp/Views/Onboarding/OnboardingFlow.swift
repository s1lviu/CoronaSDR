import SwiftUI
import SDRModels
import RTLTCPClientKit
import SDRSupport

struct OnboardingFlow: View {
    @Environment(SettingsStore.self) private var settings
    @State private var step = 0
    @State private var host = ""
    @State private var port = "1234"
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var testSuccess = false

    private let discovery = ServiceDiscovery()

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case 0:
                    welcomeStep
                case 1:
                    serverSetupStep
                default:
                    EmptyView()
                }
            }
            .navigationTitle("Welcome to SDR Radio")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 80))
                .foregroundStyle(.tint)

            Text("SDR Radio")
                .font(.largeTitle.bold())

            VStack(spacing: 12) {
                infoRow(icon: "server.rack", text: "You need an rtl_tcp server running on a Raspberry Pi or PC on your local network.")
                infoRow(icon: "wifi", text: "This app connects over Wi-Fi (wired Ethernet to server recommended).")
                infoRow(icon: "antenna.radiowaves.left.and.right", text: "Supports RTL-SDR dongles via rtl_tcp protocol.")
            }
            .padding()

            Spacer()

            Button {
                withAnimation { step = 1 }
            } label: {
                Text("Set Up Connection")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    // MARK: - Step 2: Server Setup

    private var serverSetupStep: some View {
        VStack(spacing: 20) {
            Form {
                Section("Server Address") {
                    TextField("IP Address (e.g. 192.168.1.100)", text: $host)
                        .keyboardType(.decimalPad)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Server IP address")

                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                        .accessibilityLabel("Server port")
                }

                if !discovery.discoveredServers.isEmpty {
                    Section("Discovered Servers") {
                        ForEach(discovery.discoveredServers) { server in
                            Button {
                                host = server.host
                                port = String(server.port)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(server.name)
                                            .font(.headline)
                                        Text("\(server.host):\(server.port)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right.circle")
                                }
                            }
                            .accessibilityLabel("Select server \(server.name)")
                        }
                    }
                }

                Section {
                    Button {
                        testConnectionAction()
                    } label: {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .padding(.trailing, 4)
                            }
                            Text(isTesting ? "Testing..." : "Test Connection")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(host.isEmpty || isTesting)
                    .accessibilityLabel("Test connection to server")

                    if let result = testResult {
                        HStack {
                            Image(systemName: testSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(testSuccess ? .green : .red)
                            Text(result)
                                .font(.caption)
                        }
                    }
                }
            }

            if testSuccess {
                Button {
                    saveAndFinish()
                } label: {
                    Text("Start Listening")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
            }
        }
        .onAppear {
            discovery.startBrowsing()
        }
        .onDisappear {
            discovery.stopBrowsing()
        }
    }

    // MARK: - Helpers

    private func infoRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func testConnectionAction() {
        guard let portNum = UInt16(port), !host.isEmpty else { return }
        isTesting = true
        testResult = nil

        SDRDebug.print("🔌 Testing connection to \(host):\(portNum)")
        let conn = RTLTCPConnection(iqBuffer: IQRingBuffer(capacity: 1024))
        Task {
            SDRDebug.print("🔌 testConnection starting...")
            let result = await conn.testConnection(host: host, port: portNum)
            SDRDebug.print("🔌 testConnection returned: \(result)")
            await MainActor.run {
                isTesting = false
                switch result {
                case .success(let header):
                    testSuccess = true
                    testResult = "Connected! Tuner: \(header.tunerType.displayName), \(header.gainCount) gain steps"
                    SDRDebug.print("✅ Test success: \(header.tunerType.displayName)")
                case .failure(let error):
                    testSuccess = false
                    testResult = "Failed: \(error.localizedDescription)"
                    SDRDebug.print("❌ Test failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func saveAndFinish() {
        settings.lastServerHost = host
        settings.lastServerPort = Int(port) ?? 1234
        settings.hasCompletedOnboarding = true
    }
}
