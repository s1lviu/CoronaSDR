import SwiftUI
import SDRModels

struct ConnectionSheet: View {
    let viewModel: RadioViewModel
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = "1234"
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testSuccess = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Host or IP", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityLabel("Server host or IP address")

                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                        .accessibilityLabel("Server port")
                }

                Section {
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            if isTesting { ProgressView().padding(.trailing, 4) }
                            Text(isTesting ? "Testing..." : "Test Connection")
                        }
                    }
                    .disabled(host.isEmpty || isTesting)

                    if let result = testResult {
                        Label(result, systemImage: testSuccess ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(testSuccess ? .green : .red)
                            .font(.caption)
                    }
                }

                if viewModel.isConnected {
                    Section {
                        Button("Disconnect", role: .destructive) {
                            viewModel.disconnect()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        connectAndDismiss()
                    }
                    .disabled(host.isEmpty)
                    .bold()
                }
            }
            .onAppear {
                host = settings.lastServerHost
                port = String(settings.lastServerPort)
            }
        }
    }

    private func testConnection() {
        guard let portNum = UInt16(port) else { return }
        isTesting = true
        testResult = nil

        Task {
            let result = await viewModel.testConnection(host: host, port: portNum)
            await MainActor.run {
                isTesting = false
                switch result {
                case .success(let header):
                    testSuccess = true
                    testResult = "OK - \(header.tunerType.displayName)"
                case .failure(let error):
                    testSuccess = false
                    testResult = error.localizedDescription
                }
            }
        }
    }

    private func connectAndDismiss() {
        guard let portNum = UInt16(port) else { return }
        settings.lastServerHost = host
        settings.lastServerPort = Int(port) ?? 1234
        viewModel.connect(host: host, port: portNum)
        dismiss()
    }
}
