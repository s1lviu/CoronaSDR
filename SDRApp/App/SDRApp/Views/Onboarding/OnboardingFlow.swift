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
    @State private var isNetworkPermissionDenied = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case host
        case port
    }

    var body: some View {
        NavigationStack {
            ZStack {
                onboardingBackground
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
            }
            .toolbar {
                if step == 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            focusedField = nil
                            withAnimation(.easeInOut(duration: 0.2)) {
                                step = 0
                            }
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        ScrollView {
            VStack(spacing: 24) {
                stepIndicator(current: 1, total: 2)
                    .padding(.top, 12)

                VStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.16, green: 0.54, blue: 0.44), Color(red: 0.10, green: 0.37, blue: 0.30)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 120, height: 120)
                            .shadow(color: Color.black.opacity(0.12), radius: 16, x: 0, y: 10)

                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 50, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                    Text("CoronaSDR")
                        .font(.system(size: 36, weight: .bold, design: .rounded))

                    Text("Listen to SDR with a clean, stable experience. Start by connecting to your local `rtl_tcp` server.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }

                VStack(spacing: 12) {
                    infoCard(icon: "server.rack", title: "Local server", text: "You need an `rtl_tcp` server running on Raspberry Pi, Linux, or macOS.")
                    infoCard(icon: "wifi", title: "Stable network", text: "Your phone and server should be on the same local network.")
                    infoCard(icon: "dot.radiowaves.left.and.right", title: "RTL-SDR ready", text: "Works with RTL-SDR dongles using the `rtl_tcp` protocol.")
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        step = 1
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("Set up connection")
                        Image(systemName: "arrow.right")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Step 2: Server Setup

    private var serverSetupStep: some View {
        ScrollView {
            VStack(spacing: 20) {
                stepIndicator(current: 2, total: 2)
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Server Connection")
                        .font(.title3.bold())

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Host or IP")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("ex: 192.168.1.100", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .focused($focusedField, equals: .host)
                            .submitLabel(.next)
                            .onSubmit {
                                focusedField = .port
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.background)
                            )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Port")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("1234", text: $port)
                            .keyboardType(.numberPad)
                            .focused($focusedField, equals: .port)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.background)
                            )
                    }

                    Button {
                        focusedField = nil
                        testConnectionAction()
                    } label: {
                        HStack(spacing: 8) {
                            if isTesting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isTesting ? "Testing..." : "Test Connection")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.regularMaterial)
                )

                if let result = testResult {
                    statusCard(text: result, success: testSuccess)

                    if isNetworkPermissionDenied {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "gear")
                                Text("Open Settings to Allow Local Network")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.large)
                    }
                }

            }
            .padding(.horizontal)
            .padding(.bottom, 120)
            .contentShape(Rectangle())
            .onTapGesture {
                focusedField = nil
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if testSuccess {
                    Button {
                        focusedField = nil
                        saveAndFinish()
                    } label: {
                        HStack(spacing: 8) {
                            Text("Start Listening")
                            Image(systemName: "play.fill")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                        Text("Test your connection before continuing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)
        }
        .onAppear {
            if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                host = settings.lastServerHost
            }
            if port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                port = String(settings.lastServerPort)
            }
        }
    }

    // MARK: - Helpers

    private var onboardingBackground: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            Circle()
                .fill(Color(red: 0.16, green: 0.54, blue: 0.44).opacity(0.12))
                .frame(width: 320, height: 320)
                .offset(x: 140, y: -250)
                .blur(radius: 10)
            Circle()
                .fill(Color(red: 0.10, green: 0.37, blue: 0.30).opacity(0.10))
                .frame(width: 280, height: 280)
                .offset(x: -170, y: 320)
                .blur(radius: 14)
        }
        .ignoresSafeArea()
    }

    private func stepIndicator(current: Int, total: Int) -> some View {
        HStack(spacing: 10) {
            ForEach(1...total, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index == current ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: index == current ? 28 : 16, height: 8)
            }

            Spacer()

                Text("Step \(current) of \(total)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func infoCard(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(red: 0.10, green: 0.37, blue: 0.30))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    private func statusCard(text: String, success: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(success ? .green : .red)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill((success ? Color.green : Color.red).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke((success ? Color.green : Color.red).opacity(0.25), lineWidth: 1)
        )
    }

    private func testConnectionAction() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let portNum = UInt16(port), !trimmedHost.isEmpty else { return }
        isTesting = true
        testSuccess = false
        testResult = nil
        isNetworkPermissionDenied = false

        host = trimmedHost
        SDRDebug.print("🔌 Testing connection to \(trimmedHost):\(portNum)")
        let conn = RTLTCPConnection(iqBuffer: IQRingBuffer(capacity: 1024))
        Task {
            SDRDebug.print("🔌 testConnection starting...")
            let result = await conn.testConnection(host: trimmedHost, port: portNum)
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
                    isNetworkPermissionDenied = RTLTCPConnection.isLocalNetworkDeniedError(error)
                    if isNetworkPermissionDenied {
                        testResult = "Local Network access is required to connect to your SDR server."
                    } else {
                        testResult = "Failed: \(error.localizedDescription)"
                    }
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
