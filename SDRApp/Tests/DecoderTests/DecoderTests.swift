import XCTest
import Foundation
import SDRDecoding
import SDRCoreDSP
import RTLTCPClientKit
import DecoderFixtures

final class DecoderTests: XCTestCase {
    func testIQEveryChunkBoundaryPreservesPairsAndIndices() {
        let input = Data((0..<200).map(UInt8.init))
        for size in 1...31 {
            let ring = IQRingBuffer(capacity: 256)
            for start in stride(from: 0, to: input.count, by: size) {
                ring.write(input.subdata(in: start..<min(input.count, start + size)))
            }
            let storage = UnsafeMutableRawBufferPointer.allocate(byteCount: 256, alignment: 16)
            defer { storage.deallocate() }
            let info = ring.readBlock(into: storage, maxCount: 255)
            XCTAssertEqual(info.firstSampleIndex, 0)
            XCTAssertEqual(info.byteCount, 200)
            XCTAssertEqual(Data(storage.prefix(info.byteCount)), input)
        }
    }
    func testIQOverrunAndOversizedWriteRetainNewestCompletePairs() {
        let ring = IQRingBuffer(capacity: 8)
        ring.write(Data(0..<6)); ring.write(Data(6..<10))
        XCTAssertEqual(Array(ring.read(maxCount: 8)), Array(UInt8(2)..<UInt8(10)))
        ring.reset(); ring.write(Data(0..<31))
        let storage = UnsafeMutableRawBufferPointer.allocate(byteCount: 8, alignment: 16)
        defer { storage.deallocate() }
        let info = ring.readBlock(into: storage, maxCount: 8)
        XCTAssertEqual(info.firstSampleIndex, 11)
        XCTAssertEqual(info.droppedSamples, 11)
        XCTAssertEqual(Array(storage), Array(UInt8(22)..<UInt8(30)))
        ring.write(Data([31]))
        XCTAssertEqual(Array(ring.read(maxCount: 8)), [30,31])
    }
    func testSettlingAndFlushPreserveParity() {
        let ring = IQRingBuffer(capacity: 32)
        ring.write(Data([0])); ring.flush()
        ring.write(Data([1,2,3]))
        XCTAssertEqual(Array(ring.read(maxCount: 32)), [2,3])
        ring.discard(byteCount: 3) // 4,5,6 discarded; Q=7 must also be discarded.
        ring.write(Data([7,8,9]))
        XCTAssertEqual(Array(ring.read(maxCount: 32)), [8,9])
    }
    func testDecimationIsInvariantUnderArbitraryPartitions() {
        let input = (0..<10007).map { sin(Float($0) * 0.017) }
        for factor in [1,4,21,50] {
            let full = FIRFilter(cutoffNormalized: 0.08, numTaps: 127, decimationFactor: factor).process(input)
            for size in [1,7,60,8192] {
                let filter = FIRFilter(cutoffNormalized: 0.08, numTaps: 127, decimationFactor: factor)
                var parts: [Float] = []
                for i in stride(from: 0, to: input.count, by: size) { parts += filter.process(Array(input[i..<min(i+size,input.count)])) }
                XCTAssertEqual(parts.count, full.count)
                XCTAssertLessThan(zip(parts,full).map { abs($0-$1) }.max() ?? 0, 0.00001)
                filter.reset()
                XCTAssertEqual(filter.process(input), full)
            }
        }
    }
    func testFT8GeneratedMessageTimeAndFrequency() throws {
        let decoder = try FT8Decoder()
        for (hz,start) in [(300.0,0.0),(1234.0,1.18),(2700.0,4.5)] {
            let results = try decoder.decode(ft8("CQ K1ABC FN42", hz: Float(hz), start: Float(start)))
            let message = try XCTUnwrap(results.first { $0.text == "CQ K1ABC FN42" })
            XCTAssertEqual(message.audioHz, Float(hz), accuracy: 4)
            XCTAssertEqual(message.startSeconds, Float(start), accuracy: 0.09)
        }
    }
    func testFT8RecordedRadioFixture() throws {
        let results = try FT8Decoder().decode(recording("191111_110130"))
        let expected = Set(["CQ R7IW LN35", "CQ DX R6WA LN32", "CQ TA6CQ KN70", "OH3NIV ZS6S -03", "TK4LS YC1MRF 73"])
        let actual = Set(results.map(\.text))
        let referenceOnly = Set(["DO2JHE LZ1JZ -13"])
        XCTAssertTrue(expected.isSubset(of: actual), "\(results)")
        XCTAssertTrue(actual.isSubset(of: expected.union(referenceOnly)))
        print("110130 coverage: \(actual.intersection(expected).count)/5 original annotations")
        print("110130 missing WSJT-X outputs: \(referenceOnly.subtracting(actual).sorted())")
    }
    func testFT8FreeTextTelemetryNonstandardAndUnsupportedFormats() throws {
        let expected = ["HELLO WORLD", "123456789ABCDEF012", "CQ PJ4/K1ABC", "Unsupported FT8 message type"]
        for kind in 0..<4 {
            var samples = [Float](repeating:0,count:216000)
            XCTAssertEqual(samples.withUnsafeMutableBufferPointer { fixture_ft8_kind(Int32(kind),$0.baseAddress,Int32($0.count)) },0)
            let message = try XCTUnwrap(FT8Decoder().decode(samples).first)
            XCTAssertEqual(message.text,expected[kind])
            XCTAssertEqual(message.supported,kind != 3)
        }
    }
    func testRecordedBusyBandAndKnownReferenceMissAreCharacterized() throws {
        let results = try FT8Decoder().decode(recording("websdr_test1"))
        let expected = Set(["G4CUS SP4FCA +10", "LZ1LZ G4UJS IO83", "YO6OGJ F4IAG R-09", "SQ5FBI G3NDC IO91", "CQ IK4LZH JN54", "GM0LIR UA9SIX -09", "R2EA IZ4OUL R-08", "CQ MM1AWV IO75", "ES5GI DD3SF 73", "CQ EA1ABT IN73", "2M0OGG RA6ABO KN96", "CQ IZ3XJM JN55", "VK3EVE SQ3MZM -24", "LZ1CWK DC8VA RR73", "CQ EA1HTF IN52", "YO7CGS A41ZZ -11", "R2ATW IZ0VLL -16", "CQ DX Z33Z KN11"])
        let actual = Set(results.map(\.text))
        // Every additional output below is independently reproduced by WSJT-X 3.0.2.
        // Preserve the original annotation gap explicitly; do not relabel it as a success.
        let additional = Set(["CQ LZ532PSO", "R7FE IK4ISR -12", "CQ IU8DMZ JN70",
                              "EY8MM YB1BML 73", "EY8MM EA3NW -15", "CQ YP4XMAS", "CQ F5JQQ JN08"])
        let unresolved = Set(["LZ1CWK DC8VA RR73"])
        XCTAssertTrue(expected.subtracting(unresolved).isSubset(of: actual))
        let referenceOnly = Set(["SQ5FBI UA9CJM MO09"])
        XCTAssertTrue(actual.isSubset(of: expected.union(additional).union(referenceOnly)))
        XCTAssertTrue(additional.isSubset(of: actual))
        print("Busy-band missing WSJT-X outputs: \(referenceOnly.subtracting(actual).sorted())")
        print("Busy-band missing original annotations: \(expected.subtracting(actual).sorted())")
        print("RF coverage: busy band \(actual.intersection(expected).count)/18 original annotations; \(actual.subtracting(expected).count) additional reference-confirmed outputs")
    }
    func testPreviouslyMissedSingleRecordingIsDecoded() throws {
        let results = try FT8Decoder().decode(recording("191111_110115"))
        XCTAssertEqual(Set(results.map(\.text)), ["GJ0KYZ RK9AX MO05"])
    }

    private func recording(_ name: String) throws -> [Float] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        func u32(_ i: Int) -> Int { (0..<4).reduce(0) { $0 | Int(data[i+$1]) << ($1*8) } }
        var pos = 12; var pcm: [Float] = []
        while pos + 8 <= data.count {
            let size = u32(pos+4)
            guard size >= 0 && pos+8+size <= data.count else { XCTFail("Malformed WAV fixture"); return [] }
            let chunk = String(decoding: data[pos..<pos+4], as: UTF8.self)
            if chunk == "fmt " { XCTAssertEqual(u32(pos+12), 12000) }
            if chunk == "data" {
                pcm = stride(from: pos+8, to: pos+8+size, by: 2).map {
                    Float(Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0+1]) << 8)) / 32768
                }
            }
            pos += 8 + size + size % 2
        }
        if pcm.count < 216000 { pcm += [Float](repeating: 0, count: 216000-pcm.count) }
        return pcm
    }
    func testFT8SilenceNoiseInvalidInputAndTwoSignals() throws {
        let decoder = try FT8Decoder()
        XCTAssertTrue(try decoder.decode([Float](repeating: 0, count: 216000)).isEmpty)
        XCTAssertThrowsError(try decoder.decode([.nan] + [Float](repeating: 0, count: 215999)))
        XCTAssertThrowsError(try decoder.decode([0]))
        var rng: UInt64 = 42
        let noise = (0..<216000).map { _ -> Float in
            rng = rng &* 6364136223846793005 &+ 1
            return Float(Int32(truncatingIfNeeded: rng >> 32)) / Float(Int32.max) * 0.1
        }
        XCTAssertTrue(try decoder.decode(noise).isEmpty)
        let a = ft8("CQ K1ABC FN42", hz: 700, start: 1)
        let b = ft8("CQ W9XYZ EN37", hz: 1800, start: 1.1)
        let results = try decoder.decode(zip(zip(a,b),noise).map { ($0.0 + $0.1) * 0.25 + $1 })
        XCTAssertTrue(results.contains { $0.text == "CQ K1ABC FN42" })
        XCTAssertTrue(results.contains { $0.text == "CQ W9XYZ EN37" })
    }
    func testFT8SampleClockVariationAndUnequalSignals() throws {
        let decoder = try FT8Decoder()
        let strong = ft8("CQ K1ABC FN42", hz: 1201.3, start: 0.83)
        let weak = ft8("CQ W9XYZ EN37", hz: 1256.7, start: 1.17)
        let mixed = zip(strong, weak).map { $0 * 0.7 + $1 * 0.035 }
        for ppm in [-100.0, 0, 100] {
            let ratio = 1 + ppm / 1_000_000
            let samples: [Float] = mixed.indices.map { i in
                let source = Double(i) * ratio
                let lower = Int(source)
                guard lower + 1 < mixed.count else { return 0 }
                let fraction = Float(source - Double(lower))
                return mixed[lower] + fraction * (mixed[lower+1] - mixed[lower])
            }
            let messages = Set(try decoder.decode(samples).map(\.text))
            XCTAssertEqual(messages, ["CQ K1ABC FN42", "CQ W9XYZ EN37"], "sample clock offset \(ppm) ppm")
        }
    }
    func testFT8TruncatedFrameDoesNotProduceAPartialMessage() throws {
        let complete = ft8("CQ K1ABC FN42", hz: 1450, start: 0)
        let samples = [Float](repeating:0, count:84000) + complete.prefix(132000)
        XCTAssertTrue(try FT8Decoder().decode(samples).isEmpty)
    }
    func testServiceClockChangePreservesSampleContinuityAndDeduplication() {
        let service = DecoderService()
        let token = service.configure(.init(mode:.ft8, frequencyHz:14074000))
        let samples = ft8("CQ K1ABC FN42", hz:900, start:4) + [Float](repeating:0, count:36000)
        let epoch = Date(timeIntervalSince1970:1700000000)
        for i in stride(from:0, to:samples.count, by:12000) {
            let clockJump = i >= 120000 ? 3600.0 : 0
            service.submit(Array(samples[i..<i+12000]), stream:1, firstSampleIndex:UInt64(i),
                           receivedAt:epoch.addingTimeInterval(Double(i)/12000 + clockJump), configurationRevision:token)
            service.waitUntilIdle()
        }
        let state = service.snapshot()
        XCTAssertEqual(state.messages.count,1)
        XCTAssertEqual(state.messages.first?.receivedAt.timeIntervalSince(epoch) ?? 0,3604,accuracy:0.1)
        XCTAssertEqual(state.skippedWindows,0)
        XCTAssertNil(state.lastInterruption)
    }

    func testCWCleanMessagesAtKnownSpeedsAndChunkBoundaries() {
        for speed in [5.0,10,20,35,50,60] {
            let samples = morse("CQ TEST 123", speed: speed)
            let decoder = CWDecoder(speedWPM: speed, automaticSpeed: false)
            var text = ""
            for i in stride(from: 0, to: samples.count, by: 137) { text += decoder.process(Array(samples[i..<min(i+137,samples.count)])) }
            XCTAssertEqual(text.trimmingCharacters(in: .whitespaces), "CQ TEST 123", "speed \(speed)")
        }
    }
    func testCWSilenceAndOffFrequencySignal() {
        let decoder = CWDecoder()
        XCTAssertEqual(decoder.process([Float](repeating: 0,count: 36000)), "")
        XCTAssertEqual(decoder.process(morse("CQ TEST", pitch: 2500)), "")
    }
    func testCWAutomaticSpeedWithNoiseAndFading() {
        let clean = morse("CQ CQ TEST 123", speed: 22)
        var seed: UInt64 = 77
        let samples = clean.enumerated().map { i,x -> Float in
            seed = seed &* 6364136223846793005 &+ 1
            let noise = Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max) * 0.025
            return x * Float(0.7 + 0.2 * sin(Double(i)/12000)) + noise
        }
        let decoder = CWDecoder(speedWPM: 20, automaticSpeed: true)
        XCTAssertEqual(decoder.process(samples).trimmingCharacters(in: .whitespaces), "CQ CQ TEST 123")
        XCTAssertEqual(decoder.estimatedWPM ?? 0, 22, accuracy: 2)
    }
    func testCWNoiseDoesNotInventAStation() {
        var seed: UInt64 = 91
        let noise = (0..<120000).map { _ -> Float in
            seed = seed &* 6364136223846793005 &+ 1
            return Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max) * 0.2
        }
        XCTAssertEqual(CWDecoder().process(noise), "")
    }
    func testCWAcquiresAboveSteadyWeakReceiverCarrierWithoutCorruptingFirstCharacter() {
        let samples = morse("CQ TEST").enumerated().map { i,x in
            x + Float(0.005 * sin(2 * Double.pi * 600 * Double(i)/12000))
        }
        XCTAssertEqual(CWDecoder(automaticSpeed:false).process(samples).trimmingCharacters(in:.whitespaces),"CQ TEST")
    }
    func testDecoderAudioClockIsPartitionInvariantAndRejectsAliasing() {
        for rate in [48000.0, 1024000.0/21, 2400000.0/50] {
            let count = Int(rate * 2)
            let input = (0..<count).map { sin(Float(2 * Double.pi * 1000 * Double($0) / rate)) }
            let full = DecoderAudioPath(inputRate: rate)
            var expected: [Float] = []
            full.process(input, into: &expected)
            XCTAssertEqual(expected.count, 24000, accuracy: 2)
            let split = DecoderAudioPath(inputRate: rate)
            var actual: [Float] = [], block: [Float] = []
            for i in stride(from: 0, to: count, by: 197) {
                split.process(Array(input[i..<min(i+197,count)]), into: &block); actual += block
            }
            XCTAssertEqual(actual.count, expected.count)
            XCTAssertLessThan(zip(actual,expected).map { abs($0-$1) }.max() ?? 0, 0.00001)
            split.reset(); split.process(input, into: &block)
            XCTAssertEqual(block, expected)
            let high = (0..<count).map { sin(Float(2 * Double.pi * 9000 * Double($0) / rate)) }
            full.reset(); full.process(high, into: &block)
            let rms = sqrt(block.dropFirst(1000).reduce(0) { $0+$1*$1 } / Float(block.count-1000))
            XCTAssertLessThan(rms,0.001)
        }
    }
    func testFT8RecordedAudioSurvivesProductionResampling() throws {
        let samples = try recording("191111_110130")
        let inputRate = 1024000.0 / 21
        let up = Resampler(inputRate: 12000, outputRate: inputRate).process(samples)
        let path = DecoderAudioPath(inputRate: inputRate)
        var pcm: [Float] = [], part: [Float] = []
        for i in stride(from: 0, to: up.count, by: 401) {
            path.process(Array(up[i..<min(i+401,up.count)]), into: &part); pcm += part
        }
        let results = try FT8Decoder().decode(Array(pcm.prefix(216000)))
        XCTAssertTrue(Set(["CQ R7IW LN35", "CQ DX R6WA LN32", "CQ TA6CQ KN70", "OH3NIV ZS6S -03"]).isSubset(of: Set(results.map(\.text))))
    }
    func testUSBRejectsOppositeSidebandBeforeFT8Input() {
        let rate = 48000.0
        func rms(_ hz: Double) -> Float {
            let demod = SSBDemodulator(isUSB: true); demod.agcEnabled = false
            let real = (0..<48000).map { Float(cos(2 * .pi * hz * Double($0)/rate)) }
            let imag = (0..<48000).map { Float(sin(2 * .pi * hz * Double($0)/rate)) }
            let out = demod.demodulate(real:real, imag:imag).dropFirst(4096)
            return sqrt(out.reduce(0) { $0+$1*$1 } / Float(out.count))
        }
        let wanted = rms(1200)
        XCTAssertGreaterThan(wanted,0.5)
        XCTAssertLessThan(rms(-1200)/wanted,0.02)
    }
    func testCWChannelRejectsAdjacentCarrierAndPitchDoesNotMovePassband() {
        let rate: Float = 48000
        let n = 24000
        func level(offset: Float, pitch: Float) -> Float {
            let demod = CWDemodulator(sampleRate: rate, bandwidthHz: 500)
            demod.pitchHz = pitch
            let real = (0..<n).map { cos(2 * Float.pi * offset * Float($0) / rate) }
            let imag = (0..<n).map { sin(2 * Float.pi * offset * Float($0) / rate) }
            let out = demod.demodulate(real: real, imag: imag).dropFirst(4096)
            return sqrt(out.reduce(0) { $0 + $1*$1 } / Float(out.count))
        }
        let center = level(offset:0,pitch:600)
        XCTAssertGreaterThan(center,0.65)
        XCTAssertEqual(level(offset:0,pitch:1000),center,accuracy:0.01)
        XCTAssertLessThan(level(offset:1000,pitch:600)/center,0.01)
        XCTAssertLessThan(level(offset:3000,pitch:600)/center,0.001)
    }

    func testServiceRejectsOldResultsAndResetsOnSampleGap() {
        let service = DecoderService()
        service.configure(.init(mode: .cw, frequencyHz: 7000000, automaticSpeed: false))
        let samples = morse("CQ TEST")
        var first: UInt64 = 0
        for i in stride(from: 0, to: samples.count, by: 12000) {
            let part = Array(samples[i..<min(i+12000,samples.count)])
            service.submit(part, stream: 1, firstSampleIndex: first, receivedAt: Date())
            first += UInt64(part.count); service.waitUntilIdle()
        }
        XCTAssertTrue(service.snapshot().transcript.contains("CQ TEST"))
        service.submit([Float](repeating: 0,count:12000), stream: 2, firstSampleIndex:0, receivedAt: Date())
        service.waitUntilIdle()
        XCTAssertTrue(service.snapshot().transcript.contains("Reception changed"))
        service.clearHistory()
        XCTAssertTrue(service.snapshot().transcript.isEmpty)
        service.configure(.init(mode: .off,frequencyHz:0))
        service.submit(samples, stream:3, firstSampleIndex:0, receivedAt: Date())
        service.waitUntilIdle()
        XCTAssertTrue(service.snapshot().transcript.isEmpty)
        XCTAssertEqual(service.snapshot().status,"Decoder off")
    }
    func testServiceOverlappingWindowsDeduplicateAndKeepLaterRepeats() {
        let service = DecoderService()
        let token = service.configure(.init(mode:.ft8,frequencyHz:14074000))
        let first = ft8("CQ K1ABC FN42",hz:900,start:4)
        var samples = first + [Float](repeating:0,count:180000)
        let second = ft8("CQ K1ABC FN42",hz:900,start:1)
        for i in second.indices { samples[180000+i] += second[i] }
        let date = Date(timeIntervalSince1970:1700000000)
        for i in stride(from:0,to:samples.count,by:12000) {
            service.submit(Array(samples[i..<min(i+12000,samples.count)]),stream:1,firstSampleIndex:UInt64(i),
                           receivedAt:date.addingTimeInterval(Double(i)/12000),configurationRevision:token)
            service.waitUntilIdle()
        }
        let messages = service.snapshot().messages.filter { $0.text == "CQ K1ABC FN42" }
        XCTAssertEqual(messages.count,2)
        XCTAssertEqual(messages.first?.receivedAt.timeIntervalSince(date) ?? -1,4,accuracy:0.1)
        XCTAssertEqual(messages.last?.receivedAt.timeIntervalSince(date) ?? -1,16,accuracy:0.1)
        XCTAssertNotNil(service.snapshot().lastWindowSummary)
    }
    func testServiceOversizedBlockRecoversAndStaleConfigurationCannotPublish() {
        let service = DecoderService()
        let old = service.configure(.init(mode:.cw,frequencyHz:7000000,automaticSpeed:false))
        let token = service.configure(.init(mode:.cw,frequencyHz:7001000,automaticSpeed:false))
        let samples = morse("TEST")
        service.submit(Array(samples.prefix(12000)),stream:1,firstSampleIndex:0,receivedAt:Date(),configurationRevision:old)
        service.waitUntilIdle()
        XCTAssertEqual(service.snapshot().status,"Waiting for receiver samples")
        service.submit([Float](repeating:0,count:48001),stream:1,firstSampleIndex:0,receivedAt:Date(),configurationRevision:token)
        for i in stride(from:0,to:samples.count,by:12000) {
            service.submit(Array(samples[i..<min(i+12000,samples.count)]),stream:1,firstSampleIndex:UInt64(48001+i),receivedAt:Date(),configurationRevision:token)
            service.waitUntilIdle()
        }
        XCTAssertEqual(service.snapshot().skippedWindows,1)
        XCTAssertEqual(service.snapshot().transcript.trimmingCharacters(in:.whitespaces),"TEST")
    }
    func testFT8CancellationDuringReconfigurationDoesNotLeakOldFrequency() {
        let service = DecoderService()
        let old = service.configure(.init(mode:.ft8,frequencyHz:14074000))
        let samples = ft8("CQ K1ABC FN42",hz:1200,start:1)
        for i in stride(from:0,to:samples.count,by:36000) {
            service.submit(Array(samples[i..<i+36000]),stream:1,firstSampleIndex:UInt64(i),receivedAt:Date(),configurationRevision:old)
            if i < 180000 { service.waitUntilIdle() }
        }
        service.configure(.init(mode:.off,frequencyHz:7074000))
        service.clearHistory(); service.waitUntilIdle()
        XCTAssertEqual(service.snapshot().status,"Decoder off")
        XCTAssertTrue(service.snapshot().messages.isEmpty)
    }

    private func ft8(_ message: String, hz: Float, start: Float) -> [Float] {
        var result = [Float](repeating: 0,count:216000)
        let code = result.withUnsafeMutableBufferPointer { out in
            message.withCString { fixture_ft8($0,hz,start,out.baseAddress,Int32(out.count)) }
        }
        XCTAssertEqual(code,0)
        return result
    }
    private func morse(_ text: String, speed: Double = 20, pitch: Double = 600) -> [Float] {
        var out = [Float](repeating:0,count:6000)
        let dot = Int((12000 * 1.2 / speed).rounded())
        // Independent fixture mapping; changing the production alphabet must fail these tests.
        let reverse = ["C":"-.-.", "Q":"--.-", "T":"-", "E":".", "S":"...", "1":".----", "2":"..---", "3":"...--"]
        for (wi,word) in text.split(separator:" ").enumerated() {
            if wi > 0 { out += [Float](repeating:0,count:dot*4) }
            for char in word {
                let pattern = reverse[String(char)]!
                for element in pattern {
                    let count = dot * (element == "." ? 1 : 3)
                    for i in 0..<count {
                        let ramp = min(1,Double(min(i,count-1-i))/48)
                        out.append(Float(sin(2 * .pi * pitch * Double(out.count) / 12000) * 0.5 * ramp))
                    }
                    out += [Float](repeating:0,count:dot)
                }
                out += [Float](repeating:0,count:dot*2)
            }
        }
        out += [Float](repeating:0,count:12000)
        return out
    }
}
