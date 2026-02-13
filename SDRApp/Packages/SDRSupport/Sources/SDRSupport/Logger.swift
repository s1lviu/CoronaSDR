import Foundation
import os

/// Centralized logging categories for the SDR app.
/// Uses os.Logger for structured, performant logging.
public enum SDRLogger {
    private static let subsystem = "com.sdrapp.ios"

    public static let network = Logger(subsystem: subsystem, category: "Network")
    public static let dsp = Logger(subsystem: subsystem, category: "DSP")
    public static let audio = Logger(subsystem: subsystem, category: "Audio")
    public static let ui = Logger(subsystem: subsystem, category: "UI")
    public static let scan = Logger(subsystem: subsystem, category: "Scan")
    public static let data = Logger(subsystem: subsystem, category: "Data")
    public static let general = Logger(subsystem: subsystem, category: "General")
}

/// Runtime toggle for verbose debug prints.
public enum SDRDebug {
    private nonisolated(unsafe) static var verboseLogsEnabled = false
    private static let lock = NSLock()

    public static func setEnabled(_ enabled: Bool) {
        lock.lock()
        verboseLogsEnabled = enabled
        lock.unlock()
    }

    public static func print(_ message: @autoclosure () -> String) {
        lock.lock()
        let isEnabled = verboseLogsEnabled
        lock.unlock()
        guard isEnabled else { return }
        Swift.print(message())
    }
}
