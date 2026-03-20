import Foundation
import Network
import Observation
import Synchronization
import SDRSupport
import SDRModels

/// Connection state for the RTL-TCP client.
public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case validatingHeader
    case connected(RTLTCPHeader)
    case reconnecting(attempt: Int)
    case failed(String)
}

/// Sendable helper that ensures a continuation is resumed exactly once.
private final class TestConnectionHelper: Sendable {
    private let state = Mutex<(resumed: Bool, continuation: CheckedContinuation<Result<RTLTCPHeader, Error>, Never>?)>((false, nil))

    func setContinuation(_ cont: CheckedContinuation<Result<RTLTCPHeader, Error>, Never>) {
        state.withLock { $0.continuation = cont }
    }

    func resumeOnce(_ result: Result<RTLTCPHeader, Error>) {
        state.withLock { s in
            guard !s.resumed, let cont = s.continuation else { return }
            s.resumed = true
            s.continuation = nil
            cont.resume(returning: result)
        }
    }
}

/// RTL-TCP client that manages the TCP connection, validates the header,
/// sends commands, and pushes received IQ data into the ring buffer.
@Observable
public final class RTLTCPConnection: @unchecked Sendable {
    public var state: ConnectionState = .disconnected
    public private(set) var header: RTLTCPHeader?
    public var onStateChange: ((ConnectionState) -> Void)?

    private var connection: NWConnection?
    private var pathMonitor: NWPathMonitor?
    private let iqBuffer: IQRingBuffer

    // Reconnect state
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var lastHost: String = ""
    private var lastPort: UInt16 = 0
    private var reconnectPolicy: ReconnectPolicy = .exponentialBackoff

    // Throughput tracking
    private var bytesReceived: Int = 0
    private var lastThroughputCheck: CFAbsoluteTime = 0
    public var throughputBytesPerSec: Double = 0

    // Settle window: discard samples after retune
    private let settleLock = NSLock()
    private var currentSampleRateHz: Int = 1_024_000
    private let settleWindowDurationMs = 150
    private var settleDiscardBytes: Int = 0
    private var isSettling: Bool = false

    private let networkQueue = DispatchQueue(label: "yo6say.coronasdr.network", qos: .utility)
    private let streamReceiveMinLength = 4_096
    private let streamReceiveMaxLength = 262_144

    public init(iqBuffer: IQRingBuffer) {
        self.iqBuffer = iqBuffer
    }

    deinit {
        disconnect()
    }

    // MARK: - Connect / Disconnect

    /// Connect to an rtl_tcp server.
    public func connect(host: String, port: UInt16, policy: ReconnectPolicy = .exponentialBackoff) {
        disconnect()
        self.lastHost = host
        self.lastPort = port
        self.reconnectPolicy = policy
        self.reconnectAttempt = 0
        setState(.connecting)
        SDRDebug.print("🔌 connectInternal: state=connecting, host=\(host):\(port)")

        SDRLogger.network.info("Connecting to \(host):\(port)")

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            setState(.failed("Invalid port: \(port)"))
            return
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let params = NWParameters.tcp
        params.serviceClass = .interactiveVideo

        let conn = NWConnection(to: endpoint, using: params)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            guard self.connection === conn else { return }
            SDRDebug.print("🔌 NWConnection state: \(state)")
            switch state {
            case .ready:
                SDRLogger.network.info("TCP connected, reading header")
                SDRDebug.print("🔌 TCP ready, reading header")
                self.setState(.validatingHeader)
                self.readHeader(conn)
            case .failed(let error):
                SDRLogger.network.error("Connection failed: \(error)")
                SDRDebug.print("🔌 TCP failed: \(error)")
                if RTLTCPConnection.isLocalNetworkDeniedError(error) {
                    self.setState(.failed("Local network access denied"))
                } else {
                    self.setState(.failed(error.localizedDescription))
                    self.attemptReconnect()
                }
            case .waiting(let error):
                SDRLogger.network.warning("Connection waiting: \(error)")
                SDRDebug.print("🔌 TCP waiting: \(error)")
                if RTLTCPConnection.isLocalNetworkDeniedError(error) {
                    self.setState(.failed("Local network access denied"))
                    conn.cancel()
                }
            default:
                SDRDebug.print("🔌 NWConnection other state: \(state)")
                break
            }
        }

        conn.start(queue: networkQueue)
        startPathMonitor()
    }

    /// Disconnect and clean up.
    public func disconnect() {
        reconnectPolicy = .never
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        let conn = connection
        connection = nil
        conn?.cancel()
        setState(.disconnected)
        header = nil
        settleLock.lock()
        settleDiscardBytes = 0
        isSettling = false
        settleLock.unlock()
    }

    // MARK: - Test Connection

    /// Test connection: connect, validate header, report result, then disconnect.
    public func testConnection(host: String, port: UInt16) async -> Result<RTLTCPHeader, Error> {
        if isConnected(to: host, port: port), let header {
            return .success(header)
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            return .failure(NSError(domain: "RTLTCPConnection", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Invalid port"]))
        }

        let helper = TestConnectionHelper()
        return await withCheckedContinuation { continuation in
            helper.setContinuation(continuation)

            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
            let params = NWParameters.tcp
            let conn = NWConnection(to: endpoint, using: params)

            conn.stateUpdateHandler = { [helper] state in
                switch state {
                case .ready:
                    conn.receive(minimumIncompleteLength: 12, maximumLength: 12) { data, _, _, error in
                        defer { conn.cancel() }
                        if let error {
                            helper.resumeOnce(.failure(error))
                            return
                        }
                        guard let data, let header = RTLTCPHeader(data: data), header.isValid else {
                            helper.resumeOnce(.failure(
                                NSError(domain: "RTLTCPConnection", code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "Invalid server header (expected RTL0)"])
                            ))
                            return
                        }
                        helper.resumeOnce(.success(header))
                    }
                case .failed(let error):
                    conn.cancel()
                    helper.resumeOnce(.failure(error))
                case .waiting(let error):
                    conn.cancel()
                    helper.resumeOnce(.failure(error))
                default:
                    break
                }
            }

            conn.start(queue: self.networkQueue)

            // Timeout after 5s
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [helper] in
                conn.cancel()
                helper.resumeOnce(.failure(
                    NSError(domain: "RTLTCPConnection", code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "Connection timeout (5s)"])
                ))
            }
        }
    }

    // MARK: - Commands

    /// Send a command to the server.
    public func sendCommand(_ command: RTLTCPCommand, parameter: UInt32) {
        guard let connection, case .connected = state else { return }
        let data = command.encode(parameter: parameter)
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                SDRLogger.network.error("Command send failed: \(error)")
            }
        })
    }

    /// Set frequency in Hz.
    public func setFrequency(_ hz: Int) {
        let clampedHz = max(0, min(Int(UInt32.max), hz))
        sendCommand(.setFrequency, parameter: UInt32(clampedHz))
        beginSettleWindow()
    }

    /// Set sample rate in Hz.
    public func setSampleRate(_ hz: Int) {
        let clampedHz = max(1, min(Int(UInt32.max), hz))
        let previousRate = currentSampleRateHz
        currentSampleRateHz = clampedHz
        sendCommand(.setSampleRate, parameter: UInt32(clampedHz))
        beginSettleWindow(transitionRateHz: max(previousRate, clampedHz))
    }

    /// Set gain mode (0 = auto, 1 = manual).
    public func setGainMode(_ mode: GainMode) {
        sendCommand(.setGainMode, parameter: mode == .auto ? 0 : 1)
    }

    /// Set gain in tenths of dB.
    public func setGain(_ tenthsDb: Int) {
        let clamped = max(0, min(Int(UInt32.max), tenthsDb))
        sendCommand(.setGain, parameter: UInt32(clamped))
    }

    /// Set RTL2832 AGC mode (0 = off, 1 = on).
    public func setAGCMode(_ enabled: Bool) {
        sendCommand(.setAGCMode, parameter: enabled ? 1 : 0)
    }

    /// Set direct sampling mode (0 = off, 1 = I, 2 = Q).
    public func setDirectSampling(_ mode: DirectSamplingMode) {
        sendCommand(.setDirectSampling, parameter: mode.rawValue)
    }

    /// Enable or disable tuner offset tuning.
    public func setOffsetTuning(_ enabled: Bool) {
        sendCommand(.setOffsetTuning, parameter: enabled ? 1 : 0)
    }

    /// Set PPM correction.
    public func setPPM(_ ppm: Int32) {
        sendCommand(.setFrequencyCorrection, parameter: UInt32(bitPattern: ppm))
    }

    /// Set bias-tee (0 = off, 1 = on).
    public func setBiasTee(_ enabled: Bool) {
        sendCommand(.setBiasTee, parameter: enabled ? 1 : 0)
    }

    public func isConnected(to host: String, port: UInt16) -> Bool {
        guard case .connected = state else { return false }
        return lastHost == host && lastPort == port
    }

    // MARK: - Private

    private func readHeader(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 12, maximumLength: 12) { [weak self] data, _, _, error in
            guard let self else { return }
            guard self.connection === conn else { return }
            if let error {
                SDRLogger.network.error("Header read failed: \(error)")
                self.setState(.failed("Header read failed: \(error.localizedDescription)"))
                return
            }
            guard let data, let header = RTLTCPHeader(data: data), header.isValid else {
                SDRLogger.network.error("Invalid RTL-TCP header")
                self.setState(.failed("Invalid server: expected RTL0 header"))
                conn.cancel()
                return
            }

            SDRLogger.network.info("Header valid: tuner=\(header.tunerType.displayName), gains=\(header.gainCount)")
            SDRDebug.print("🔌 Header valid: \(header.tunerType.displayName), setting state=connected")
            self.header = header
            self.setState(.connected(header))
            SDRDebug.print("🔌 State set to connected on main thread")
            self.reconnectAttempt = 0
            self.reconnectTask = nil
            self.lastThroughputCheck = CFAbsoluteTimeGetCurrent()
            self.bytesReceived = 0
            self.startReceiveLoop(conn)
        }
    }

    private func startReceiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: streamReceiveMinLength, maximumLength: streamReceiveMaxLength) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard self.connection === conn else { return }

            if let data, !data.isEmpty {
                self.bytesReceived += data.count

                // Update throughput
                let now = CFAbsoluteTimeGetCurrent()
                let elapsed = now - self.lastThroughputCheck
                if elapsed >= 1.0 {
                    let throughput = Double(self.bytesReceived) / elapsed
                    DispatchQueue.main.async {
                        self.throughputBytesPerSec = throughput
                    }
                    self.bytesReceived = 0
                    self.lastThroughputCheck = now
                }

                // Handle settle window
                if self.consumeSettleWindow(bytesReceived: data.count) {
                    // Don't write to buffer while settling.
                } else {
                    self.iqBuffer.write(data)
                }
            }

            if isComplete {
                SDRLogger.network.info("Connection completed (server closed)")
                self.setState(.failed("Server closed connection"))
                self.attemptReconnect()
                return
            }

            if let error {
                SDRLogger.network.error("Receive error: \(error)")
                self.setState(.failed(error.localizedDescription))
                self.attemptReconnect()
                return
            }

            // Continue receiving
            self.startReceiveLoop(conn)
        }
    }

    /// Begin settle window: flush buffer and discard incoming data for a fixed time window.
    /// - Parameter transitionRateHz: The rate to use for calculating discard bytes.
    ///   For sample rate changes, pass max(oldRate, newRate) so the window covers
    ///   whichever rate the data actually arrives at during the transition.
    private func beginSettleWindow(transitionRateHz: Int? = nil) {
        iqBuffer.flush()
        let rateForCalc = transitionRateHz ?? currentSampleRateHz
        let bytesPerSecond = max(1, rateForCalc * 2) // 8-bit I + 8-bit Q
        let requested = Int(Double(bytesPerSecond) * Double(settleWindowDurationMs) / 1_000.0)
        let clampedBytes = max(8_192, min(bytesPerSecond, requested))
        settleLock.lock()
        settleDiscardBytes = clampedBytes
        isSettling = true
        settleLock.unlock()
    }

    private func consumeSettleWindow(bytesReceived: Int) -> Bool {
        settleLock.lock()
        defer { settleLock.unlock() }
        guard isSettling else { return false }
        settleDiscardBytes -= bytesReceived
        if settleDiscardBytes <= 0 {
            settleDiscardBytes = 0
            isSettling = false
        }
        return true
    }

    // MARK: - Reconnect

    private func attemptReconnect() {
        guard reconnectPolicy != .never else { return }
        guard connection != nil else { return }
        guard reconnectTask == nil else { return }

        reconnectAttempt += 1
        let attempt = reconnectAttempt

        if attempt > 10 {
            SDRLogger.network.error("Max reconnect attempts reached")
            return
        }

        let delay: Double
        switch reconnectPolicy {
        case .immediate:
            delay = 0.5
        case .exponentialBackoff:
            let base = min(pow(2.0, Double(attempt - 1)) * 0.5, 8.0)
            let jitter = Double.random(in: 0...(base * 0.25))
            delay = base + jitter
        case .never:
            return
        }

        SDRLogger.network.info("Reconnecting in \(String(format: "%.1f", delay))s (attempt \(attempt))")

        setState(.reconnecting(attempt: attempt))

        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            self.connect(host: self.lastHost, port: self.lastPort, policy: self.reconnectPolicy)
        }
    }

    // MARK: - Path Monitor

    private func startPathMonitor() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            if path.status == .unsatisfied {
                SDRLogger.network.warning("Network path unsatisfied")
            } else if path.status == .satisfied {
                // If we were in a failed state, try reconnecting
                if case .failed = self.state {
                    SDRLogger.network.info("Network path restored, attempting reconnect")
                    self.attemptReconnect()
                }
            }
        }
        monitor.start(queue: networkQueue)
        self.pathMonitor = monitor
    }

    /// Detect NWError patterns that indicate iOS denied local network access.
    /// POSIX ENETDOWN/EHOSTUNREACH in the .waiting state, or DNS PolicyDenied (-65570)
    /// when resolving .local hostnames without permission.
    public static func isLocalNetworkDeniedError(_ error: any Error) -> Bool {
        if let nwError = error as? NWError {
            switch nwError {
            case .posix(let code):
                return code == .ENETDOWN || code == .EHOSTUNREACH
            case .dns(let dnsCode):
                // kDNSServiceErr_PolicyDenied = -65570
                return dnsCode == -65570
            default:
                return false
            }
        }
        // NWError sometimes wraps inside NSError with domain "Network.NWError"
        let nsError = error as NSError
        if nsError.domain == "Network.NWError" {
            return nsError.code == -65570
        }
        return error.localizedDescription.contains("PolicyDenied")
    }

    private func setState(_ newState: ConnectionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state = newState
            self.onStateChange?(newState)
        }
    }
}
