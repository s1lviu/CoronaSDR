import Foundation
import Network

/// Test-only rtl_tcp peer. Streams a recorded waveform as quantized I/Q at 250 kS/s.
/// All mutable transport state belongs to queue; the app uses its normal network path.
final class RadioReplayServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.radio-replay")
    private let listener: NWListener
    private let iq: Data
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var offset = 0
    private var started: UInt64 = 0
    private var sent = 0
    private var sending = false
    private var commands = Data()
    private var receivedCommands: [(UInt8, UInt32)] = []

    init(wav: URL) throws {
        let data = try Data(contentsOf: wav)
        func u32(_ i: Int) -> Int { (0..<4).reduce(0) { $0 | Int(data[i+$1]) << (8*$1) } }
        var pcm: [Double] = [], pos = 12
        while pos + 8 <= data.count {
            let count = u32(pos+4)
            guard count >= 0, pos+8+count <= data.count else { throw CocoaError(.fileReadCorruptFile) }
            if String(decoding: data[pos..<pos+4], as: UTF8.self) == "data" {
                pcm = stride(from: pos+8, to: pos+8+count, by: 2).map {
                    Double(Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0+1]) << 8)) / 32768
                }
            }
            pos += 8 + count + count % 2
        }
        guard !pcm.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        pcm += [Double](repeating: 0, count: max(0, 216001-pcm.count))
        let gain = 100 / max(0.001, pcm.map(abs).max() ?? 1)
        var bytes = [UInt8](repeating:128, count:18*250000*2)
        for i in 0..<(bytes.count/2) {
            let source = Double(i)*12000/250000
            let lower = Int(source), fraction = source-Double(lower)
            let sample = pcm[lower] + fraction*(pcm[lower+1]-pcm[lower])
            bytes[2*i] = UInt8(clamping:Int((128+gain*sample).rounded()))
        }
        iq = Data(bytes)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1", port:.any)
        listener = try NWListener(using:parameters)
    }

    func start(ready: @escaping @Sendable (UInt16) -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = self?.listener.port { ready(port.rawValue) }
        }
        listener.newConnectionHandler = { [weak self] peer in
            guard let self else { return }
            connection?.cancel(); connection = peer
            offset = 0; commands.removeAll(); receivedCommands.removeAll()
            peer.stateUpdateHandler = { [weak self] state in
                if case .ready = state { self?.begin(peer) }
            }
            peer.start(queue:queue)
        }
        listener.start(queue:queue)
    }

    private func begin(_ peer: NWConnection) {
        peer.send(content:Data([82,84,76,48,0,0,0,5,0,0,0,0]), completion:.contentProcessed { _ in })
        receive(peer)
        timer?.cancel()
        started = DispatchTime.now().uptimeNanoseconds; sent = 0; sending = false
        let timer = DispatchSource.makeTimerSource(queue:queue)
        timer.schedule(deadline:.now(), repeating:.milliseconds(10))
        timer.setEventHandler { [weak self] in self?.sendDue(peer) }
        self.timer = timer; timer.resume()
    }

    private func sendDue(_ peer: NWConnection) {
        guard !sending, connection === peer else { return }
        // Account for delayed/coalesced timer callbacks without slowing the sample clock.
        let target = Int(Double(DispatchTime.now().uptimeNanoseconds-started)*500000/1_000_000_000)
        let count = min(16383, iq.count-offset, max(0,target-sent))
        guard count > 0 else { return }
        let bytes = iq.subdata(in:offset..<offset+count)
        offset = (offset+count) % iq.count; sent += count; sending = true
        peer.send(content:bytes, completion:.contentProcessed { [weak self] error in
            guard let self else { return }
            sending = false
            if error == nil { sendDue(peer) }
        })
    }

    private func receive(_ peer: NWConnection) {
        peer.receive(minimumIncompleteLength:1, maximumLength:1024) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { commands.append(data) }
            while commands.count >= 5 {
                let bytes = Array(commands.prefix(5))
                let value = bytes[1...4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                receivedCommands.append((bytes[0],value)); commands.removeFirst(5)
            }
            if !done && error == nil { receive(peer) }
        }
    }

    func received(command: UInt8, value: UInt32) -> Bool {
        queue.sync { receivedCommands.contains { $0.0 == command && $0.1 == value } }
    }
    var port: UInt16? { queue.sync { listener.port?.rawValue } }
    func stop() {
        queue.sync { timer?.cancel(); timer = nil; connection?.cancel(); connection = nil; listener.cancel() }
    }
}
