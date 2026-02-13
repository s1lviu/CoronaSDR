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
