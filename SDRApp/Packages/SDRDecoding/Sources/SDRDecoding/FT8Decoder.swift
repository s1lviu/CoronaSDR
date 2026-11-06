import Foundation
import CFT8

public struct FT8Decode: Sendable, Equatable {
    public let text: String
    public let payload: String
    public let audioHz: Float
    public let startSeconds: Float
    public let supported: Bool
    public let messageType: Int
}

public enum FT8DecodeError: Error { case allocation, invalidInput, cancelled }

/// Call decode/reset serially. cancel is the only operation allowed from another thread.
public final class FT8Decoder: @unchecked Sendable {
    private let handle: OpaquePointer
    public init() throws {
        guard let handle = corona_ft8_create() else { throw FT8DecodeError.allocation }
        self.handle = handle
    }
    deinit { corona_ft8_destroy(handle) }
    public func reset() { corona_ft8_reset(handle) }
    public func cancel() { corona_ft8_cancel(handle) }
    public func decode(_ samples: [Float]) throws -> [FT8Decode] {
        guard (180000...216000).contains(samples.count) else { throw FT8DecodeError.invalidInput }
        var results = [corona_ft8_result](repeating: corona_ft8_result(), count: 160)
        let count = samples.withUnsafeBufferPointer { pcm in
            results.withUnsafeMutableBufferPointer { out in
                corona_ft8_decode(handle, pcm.baseAddress, Int32(pcm.count), out.baseAddress, Int32(out.count))
            }
        }
        if count == -3 { throw FT8DecodeError.cancelled }
        guard count >= 0 else { throw FT8DecodeError.invalidInput }
        return results.prefix(Int(count)).map { item in
            var item = item
            let text = withUnsafeBytes(of: &item.text) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            let payload = withUnsafeBytes(of: &item.payload) { $0.map { String(format: "%02x", $0) }.joined() }
            return FT8Decode(text: text, payload: payload, audioHz: item.audio_hz,
                             startSeconds: item.start_seconds, supported: item.supported != 0,
                             messageType: Int(item.message_type))
        }
    }
}
