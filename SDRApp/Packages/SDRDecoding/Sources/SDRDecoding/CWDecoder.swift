import Foundation

/// Single-tone Morse receiver. Durations are measured in samples, never callback time.
public final class CWDecoder {
    public static let alphabet: [String: String] = [
        ".-":"A", "-...":"B", "-.-.":"C", "-..":"D", ".":"E", "..-.":"F",
        "--.":"G", "....":"H", "..":"I", ".---":"J", "-.-":"K", ".-..":"L",
        "--":"M", "-.":"N", "---":"O", ".--.":"P", "--.-":"Q", ".-.":"R",
        "...":"S", "-":"T", "..-":"U", "...-":"V", ".--":"W", "-..-":"X",
        "-.--":"Y", "--..":"Z", "-----":"0", ".----":"1", "..---":"2",
        "...--":"3", "....-":"4", ".....":"5", "-....":"6", "--...":"7",
        "---..":"8", "----.":"9", ".-.-.-":".", "--..--":",", "..--..":"?",
        "-..-.":"/", "-....-":"-", ".----.":"'", "-.-.--":"!", "---...":":",
        "-.-.-.":";", ".--.-.":"@", "...-.-":"<SK>", ".-...":"<AS>",
        "-...-":"<BT/=>", ".-.-.":"<AR/+>", "-.--.":"<KN/(>", "-.--.-":")"
    ]
    private let pitch: Double
    private let automatic: Bool
    private var dot: Double
    private var phase = 0.0
    private var i1 = 0.0, q1 = 0.0, i2 = 0.0, q2 = 0.0
    private var energy = 0.0, wideEnergy = 0.0, frameCount = 0
    private var peak = 0.00001
    private var acquisitionLevels: [Double] = []
    private var noiseFloor: Double?
    private var keyed = false
    private var run = 0.0
    private var marks: [Double] = []
    private var recent: [Double] = []
    private var emittedCharacter = false
    private var emittedSpace = true
    public private(set) var estimatedWPM: Double?
    public private(set) var hasTone = false

    public init(pitchHz: Float = 600, speedWPM: Double = 20, automaticSpeed: Bool = true) {
        pitch = Double(pitchHz.isFinite ? min(1200, max(300, pitchHz)) : 600)
        dot = 1.2 / (speedWPM.isFinite ? min(60, max(5, speedWPM)) : 20)
        automatic = automaticSpeed
        if !automaticSpeed { estimatedWPM = 1.2 / dot }
    }

    public func process(_ samples: [Float]) -> String {
        var text = ""
        let alpha = 1 - exp(-2 * Double.pi * 100 / 12000)
        for sample in samples {
            let x = sample.isFinite ? Double(sample) : 0
            i1 += alpha * (x * cos(phase) - i1)
            q1 += alpha * (x * sin(phase) - q1)
            i2 += alpha * (i1 - i2); q2 += alpha * (q1 - q2)
            phase += 2 * Double.pi * pitch / 12000
            if phase >= 2 * Double.pi { phase -= 2 * Double.pi }
            energy += 4 * (i2 * i2 + q2 * q2)
            wideEnergy += x * x
            frameCount += 1
            if frameCount == 60 {
                let amplitude = sqrt(energy / 60)
                let coherent = energy > wideEnergy * 0.65
                peak = max(amplitude, peak * 0.995)
                if let floor = noiseFloor {
                    // A steady receiver offset at startup must not become a false first mark.
                    noiseFloor = min(floor, amplitude)
                    let threshold = max(0.00001, max((noiseFloor ?? 0) * 2, peak * (keyed ? 0.22 : 0.4)))
                    text += consume(coherent && amplitude > threshold, seconds: 0.005)
                } else {
                    acquisitionLevels.append(amplitude)
                    if acquisitionLevels.count == 40 {
                        noiseFloor = acquisitionLevels.sorted()[20]
                        acquisitionLevels.removeAll(keepingCapacity: false)
                    }
                }
                energy = 0; wideEnergy = 0; frameCount = 0
            }
        }
        return text
    }

    private func consume(_ next: Bool, seconds: Double) -> String {
        var text = ""
        if next != keyed {
            if keyed {
                if run >= 0.012 && run <= 1.0 {
                    marks.append(run)
                    recent.append(run)
                    if recent.count > 40 { recent.removeFirst(recent.count - 40) }
                    updateSpeed()
                } else if run > 1.0 { marks.append(-1) }
            }
            keyed = next; run = 0
            if next { emittedCharacter = false; emittedSpace = false }
        }
        run += seconds
        hasTone = keyed || run < 1.0
        if !keyed && !emittedCharacter && run >= 2.2 * dot && !marks.isEmpty {
            let pattern = marks.map { duration -> String in
                if duration < 0 || duration < 0.4 * dot || duration > 4.5 * dot { return "?" }
                return duration < 2 * dot ? "." : "-"
            }.joined()
            text += Self.alphabet[pattern] ?? "□"
            marks.removeAll(keepingCapacity: true)
            emittedCharacter = true
        }
        if !keyed && !emittedSpace && run >= 5.5 * dot {
            text += " "; emittedSpace = true
        }
        // Bound pathological carriers and malformed keying without accumulating state forever.
        if marks.count > 12 { marks.removeAll(keepingCapacity: true); text += "□" }
        if run > 3 { hasTone = false }
        return text
    }

    private func updateSpeed() {
        guard automatic, recent.count >= 4 else { return }
        let sorted = recent.sorted()
        let short = sorted[sorted.count / 4]
        let long = sorted[sorted.count * 3 / 4]
        // Both clusters are needed: a run of only dots or only dashes is ambiguous.
        guard long > short * 2.1, long < short * 4.2 else { return }
        let estimate = (short + long / 3) / 2
        guard estimate >= 0.02, estimate <= 0.24 else { return }
        dot = dot * 0.4 + estimate * 0.6
        estimatedWPM = 1.2 / dot
    }
}
