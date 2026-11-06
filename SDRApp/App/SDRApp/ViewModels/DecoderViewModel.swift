import Foundation
import Observation
import SDRDecoding

@Observable @MainActor
final class DecoderViewModel {
    var mode: DecodeMode = .off
    var snapshot = DecodeSnapshot()
    var speedWPM: Double = 20
    var automaticSpeed = true
    var monitorMuted = false
}
