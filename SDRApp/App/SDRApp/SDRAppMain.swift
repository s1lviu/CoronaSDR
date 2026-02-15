import SwiftUI
import SwiftData
import SDRModels
import SDRSupport
import os
#if canImport(UIKit)
import UIKit
#endif
#if canImport(FirebaseCore)
import FirebaseCore
#endif
#if canImport(FirebaseCrashlytics)
import FirebaseCrashlytics
#endif
#if canImport(FirebasePerformance)
import FirebasePerformance
#endif

private let logger = Logger(subsystem: "yo6say.coronasdr", category: "App")

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        TelemetryService.shared.configure()
        return true
    }
}

@main
struct CoronaSDRApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let modelContainer: ModelContainer?
    private let containerError: String?

    @State private var settingsStore = SettingsStore()
    @State private var deepLinkCoordinator = DeepLinkCoordinator()

    init() {
        TelemetryService.shared.configure()
        #if DEBUG
        SDRDebug.setEnabled(true)
        #else
        SDRDebug.setEnabled(false)
        #endif
        Self.installDebugCrashHandlers()

        logger.info("CoronaSDR init starting")
        SDRDebug.print("📻 CoronaSDR init starting")

        do {
            let schema = Schema([Station.self, Tag.self, ServerProfile.self, SampleProfile.self])
            let config = ModelConfiguration(isStoredInMemoryOnly: false)
            modelContainer = try ModelContainer(for: schema, configurations: [config])
            containerError = nil
            logger.info("ModelContainer created successfully")
            SDRDebug.print("✅ ModelContainer created")
        } catch {
            modelContainer = nil
            containerError = error.localizedDescription
            logger.error("ModelContainer failed: \(error.localizedDescription)")
            SDRDebug.print("❌ ModelContainer failed: \(error)")
        }

        logger.info("CoronaSDR init complete")
        SDRDebug.print("📻 CoronaSDR init complete")
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let modelContainer {
                    ContentView()
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
            .environment(settingsStore)
            .environment(deepLinkCoordinator)
            .onOpenURL { url in
                logger.info("Received deep link: \(url.absoluteString, privacy: .public)")
                deepLinkCoordinator.handle(url: url)
            }
        }
    }

    private static func installDebugCrashHandlers() {
        #if DEBUG
        // Keep explicit crash printing in DEBUG builds only.
        NSSetUncaughtExceptionHandler { exception in
            logger.fault("UNCAUGHT EXCEPTION: \(exception.name.rawValue): \(exception.reason ?? "nil")")
            logger.fault("Stack: \(exception.callStackSymbols.joined(separator: "\n"))")
            TelemetryService.shared.recordNonFatal(
                kind: "uncaught_exception",
                message: exception.reason ?? exception.name.rawValue,
                metadata: ["exception_name": exception.name.rawValue]
            )
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
        #endif
    }
}

final class TelemetryService: @unchecked Sendable {
    static let shared = TelemetryService()

    private struct RuntimeContext {
        var mode: DemodMode = .wfm
        var sampleRate: Int = 1_024_000
        var protocolType: SDRProtocol = .rtlTcp
    }

    private let lock = NSLock()
    private var hasConfigured = false
    private var isFirebaseEnabled = false
    private var runtimeContext = RuntimeContext()

    private init() {}

    func configure() {
        lock.lock()
        if hasConfigured {
            lock.unlock()
            return
        }
        hasConfigured = true
        lock.unlock()

        let firebaseEnabled: Bool = {
            #if canImport(FirebaseCore)
            guard let googleServiceInfoPath = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") else {
                SDRLogger.general.warning("GoogleService-Info.plist missing; telemetry runs in local-only mode.")
                return false
            }

            guard let options = FirebaseOptions(contentsOfFile: googleServiceInfoPath) else {
                SDRLogger.general.error("Failed to load FirebaseOptions from GoogleService-Info.plist")
                return false
            }

            FirebaseApp.configure(options: options)
            SDRLogger.general.info("Firebase configured successfully")
            return true
            #else
            SDRLogger.general.warning("Firebase SDK not linked; telemetry runs in local-only mode.")
            return false
            #endif
        }()

        lock.lock()
        isFirebaseEnabled = firebaseEnabled
        lock.unlock()

        PerformanceTrace.setReporter { [weak self] name, durationMs, metadata in
            self?.recordPerformanceTrace(name: name, durationMs: durationMs, metadata: metadata)
        }

        applyStaticCrashKeys()
        updateRuntimeContext(mode: runtimeContext.mode, sampleRate: runtimeContext.sampleRate, protocolType: runtimeContext.protocolType)
    }

    func updateRuntimeContext(mode: DemodMode, sampleRate: Int, protocolType: SDRProtocol) {
        lock.lock()
        runtimeContext = RuntimeContext(mode: mode, sampleRate: sampleRate, protocolType: protocolType)
        let enabled = isFirebaseEnabled
        lock.unlock()

        guard enabled else { return }
        #if canImport(FirebaseCrashlytics)
        let crashlytics = Crashlytics.crashlytics()
        crashlytics.setCustomValue(mode.rawValue, forKey: "mode")
        crashlytics.setCustomValue(sampleRate, forKey: "sample_rate_hz")
        crashlytics.setCustomValue(protocolType.rawValue, forKey: "protocol_type")
        #endif
    }

    func recordNonFatal(kind: String, message: String, metadata: [String: String] = [:]) {
        let enabled = firebaseIsEnabled()
        let sanitized = sanitizeAttributes(metadata)

        SDRLogger.general.error("Non-fatal [\(kind)]: \(message)")

        guard enabled else { return }
        #if canImport(FirebaseCrashlytics)
        let crashlytics = Crashlytics.crashlytics()
        crashlytics.setCustomValue(kind, forKey: "last_nonfatal_kind")
        crashlytics.setCustomValue(message, forKey: "last_nonfatal_message")
        for (key, value) in sanitized {
            crashlytics.setCustomValue(value, forKey: "nf_\(key)")
        }

        let error = NSError(
            domain: "yo6say.coronasdr.nonfatal",
            code: stableCode(for: kind),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        crashlytics.record(error: error)
        #endif
    }

    private func recordPerformanceTrace(name: PerformanceTrace.TraceName, durationMs: Double, metadata: [String: String]) {
        guard firebaseIsEnabled() else { return }
        #if canImport(FirebasePerformance)
        guard let trace = Performance.startTrace(name: name.rawValue) else { return }

        let mergedMetadata = mergedMetadataWithContext(extra: metadata)
        for (key, value) in mergedMetadata {
            trace.setValue(value, forAttribute: key)
        }
        trace.setValue(Int64(max(0, durationMs.rounded())), forMetric: "duration_ms")
        trace.stop()
        #endif
    }

    private func applyStaticCrashKeys() {
        guard firebaseIsEnabled() else { return }
        #if canImport(FirebaseCrashlytics)
        let crashlytics = Crashlytics.crashlytics()
        crashlytics.setCustomValue(deviceClass(), forKey: "device_class")
        crashlytics.setCustomValue(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown", forKey: "app_version")
        crashlytics.setCustomValue(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown", forKey: "build_number")
        #endif
    }

    private func mergedMetadataWithContext(extra: [String: String]) -> [String: String] {
        lock.lock()
        let context = runtimeContext
        lock.unlock()

        var metadata = sanitizeAttributes(extra)
        metadata["mode"] = context.mode.rawValue.lowercased()
        metadata["sample_rate"] = String(context.sampleRate)
        metadata["protocol"] = context.protocolType.rawValue
        metadata["device_class"] = deviceClass()
        return metadata
    }

    private func sanitizeAttributes(_ attributes: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]
        sanitized.reserveCapacity(attributes.count)

        for (rawKey, rawValue) in attributes {
            let keyLower = rawKey.lowercased()
            if keyLower.contains("host") || keyLower.contains("ip") || keyLower.contains("address") {
                continue
            }

            let key = rawKey
                .lowercased()
                .replacingOccurrences(of: "[^a-z0-9_]", with: "_", options: .regularExpression)
                .prefix(32)
            let value = String(rawValue.prefix(100))
            guard !key.isEmpty, !value.isEmpty else { continue }
            sanitized[String(key)] = value
        }

        return sanitized
    }

    private func deviceClass() -> String {
        #if targetEnvironment(macCatalyst)
        return "mac"
        #elseif os(iOS)
        return "ios"
        #else
        return "unknown"
        #endif
    }

    private func stableCode(for value: String) -> Int {
        var hash = 5381
        for scalar in value.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return abs(hash % 10_000)
    }

    private func firebaseIsEnabled() -> Bool {
        lock.lock()
        let enabled = isFirebaseEnabled
        lock.unlock()
        return enabled
    }
}
