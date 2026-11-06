import XCTest
import SDRCoreDSP
import SDRDecoding
import RTLTCPClientKit
import AudioEngineKit
import AVFoundation

@MainActor
final class DecoderPipelineTests: XCTestCase {
    func testRecordedFT8FromQuantizedIQThroughRunningUSBPipeline() async throws {
        let url = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"191111_110130",withExtension:"wav"))
        let file = try AVAudioFile(forReading:url)
        XCTAssertEqual(file.processingFormat.sampleRate,12000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(file.length)))
        try file.read(into:buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        var samples = Array(UnsafeBufferPointer(start:channel,count:Int(buffer.frameLength)))
        samples += [Float](repeating:0,count:60000)
        let peak = samples.map(abs).max() ?? 1
        let upsampled = Resampler(inputRate:12000,outputRate:192000).process(samples)
        let iq = IQRingBuffer(capacity:1<<20)
        let pipeline = DSPPipeline(iqBuffer:iq,audioBuffer:AudioRingBuffer(capacity:1<<20),sampleRate:192000)
        pipeline.mode = .usb; pipeline.bandwidthHz = 3500
        pipeline.configureDecoder(.init(mode:.ft8,frequencyHz:14074000))
        pipeline.start(); defer { pipeline.stop() }
        for i in stride(from:0,to:upsampled.count,by:8192) {
            var bytes = Data(capacity:16384)
            for sample in upsampled[i..<min(i+8192,upsampled.count)] {
                bytes.append(UInt8(clamping:Int((127.5 + sample / peak * 90).rounded())))
                bytes.append(128)
            }
            iq.write(bytes)
            try await Task.sleep(for:.milliseconds(3))
        }
        for _ in 0..<200 {
            if !pipeline.decoder.snapshot().messages.isEmpty { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        XCTAssertEqual(iq.overrunCount,0)
        XCTAssertEqual(pipeline.decoder.snapshot().skippedWindows,0)
        XCTAssertTrue(pipeline.decoder.snapshot().messages.contains { $0.text == "CQ TA6CQ KN70" },"\(pipeline.decoder.snapshot().messages)")
    }

    func testCenteredCWFromRawIQThroughRunningPipeline() async throws {
        let rate = 192000
        let dot = rate * 6 / 100
        var bytes = Data()
        func append(_ count: Int, keyed: Bool) {
            for _ in 0..<count { bytes.append(keyed ? 190 : 128); bytes.append(128) }
        }
        append(rate/2,keyed:false)
        for pattern in ["-.-.", "--.-"] { // CQ, independently specified from decoder alphabet.
            for mark in pattern {
                append(dot * (mark == "." ? 1 : 3),keyed:true)
                append(dot,keyed:false)
            }
            append(dot*2,keyed:false)
        }
        append(rate,keyed:false)
        let iq = IQRingBuffer(capacity:bytes.count+16384)
        let audio = AudioRingBuffer(capacity:1<<20)
        let pipeline = DSPPipeline(iqBuffer:iq,audioBuffer:audio,sampleRate:rate)
        pipeline.mode = .cw
        pipeline.bandwidthHz = 500
        pipeline.bfoOffsetHz = 1000
        pipeline.configureDecoder(.init(mode:.cw,frequencyHz:7000000,pitchHz:1000,automaticSpeed:false))
        pipeline.start()
        defer { pipeline.stop() }
        // Odd transport chunks must never exchange I and Q; the final half pair is retained.
        for i in stride(from:0,to:bytes.count,by:16383) {
            iq.write(bytes.subdata(in:i..<min(i+16383,bytes.count)))
            try await Task.sleep(for:.milliseconds(2))
        }
        for _ in 0..<100 {
            if pipeline.decoder.snapshot().transcript.contains("CQ") { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        XCTAssertEqual(iq.overrunCount,0)
        XCTAssertEqual(pipeline.decoder.snapshot().skippedWindows,0)
        XCTAssertEqual(pipeline.decoder.snapshot().transcript.trimmingCharacters(in:.whitespacesAndNewlines),"CQ")
    }
}
