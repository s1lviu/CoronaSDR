import SwiftUI
import SwiftData
import SDRModels
import os

private let logger = Logger(subsystem: "com.sdrapp.ios", category: "App")

@main
struct SDRAppMain: App {
    let modelContainer: ModelContainer?
    private let containerError: String?

    @State private var settingsStore = SettingsStore()

    init() {
        // Install signal/exception handlers so we see crashes in console
        NSSetUncaughtExceptionHandler { exception in
            logger.fault("UNCAUGHT EXCEPTION: \(exception.name.rawValue): \(exception.reason ?? "nil")")
            logger.fault("Stack: \(exception.callStackSymbols.joined(separator: "\n"))")
            print("💥 UNCAUGHT EXCEPTION: \(exception.name.rawValue): \(exception.reason ?? "nil")")
            print("Stack:\n\(exception.callStackSymbols.joined(separator: "\n"))")
        }

        signal(SIGABRT) { sig in
            print("💥 SIGABRT received (signal \(sig))")
            Thread.callStackSymbols.forEach { print($0) }
        }
        signal(SIGSEGV) { sig in
            print("💥 SIGSEGV received (signal \(sig))")
            Thread.callStackSymbols.forEach { print($0) }
        }
        signal(SIGBUS) { sig in
            print("💥 SIGBUS received (signal \(sig))")
            Thread.callStackSymbols.forEach { print($0) }
        }

        logger.info("SDRApp init starting")
        print("📻 SDRApp init starting")

        do {
            let schema = Schema([Station.self, Tag.self, ServerProfile.self, SampleProfile.self])
            let config = ModelConfiguration(isStoredInMemoryOnly: false)
            modelContainer = try ModelContainer(for: schema, configurations: [config])
            containerError = nil
            logger.info("ModelContainer created successfully")
            print("✅ ModelContainer created")
        } catch {
            modelContainer = nil
            containerError = error.localizedDescription
            logger.error("ModelContainer failed: \(error.localizedDescription)")
            print("❌ ModelContainer failed: \(error)")
        }

        logger.info("SDRApp init complete")
        print("📻 SDRApp init complete")
    }

    var body: some Scene {
        WindowGroup {
            if let modelContainer {
                ContentView()
                    .environment(settingsStore)
                    .modelContainer(modelContainer)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text("Database Error")
                        .font(.title2.bold())
                    Text(containerError ?? "Unknown error")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Text("Try deleting and reinstalling the app.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
