import Foundation
import Observation
import SDRModels

/// Handles deep links via custom URL scheme: coronasdr://
/// Examples:
///   coronasdr://tune?freq=100000000&mode=WFM
///   coronasdr://start
///   coronasdr://stop
enum DeepLinkHandler {
    private static let minFrequencyHz = 1_000
    private static let maxFrequencyHz = Int(UInt32.max)

    enum DeepLinkAction: Equatable {
        case tune(frequencyHz: Int, mode: DemodMode?)
        case start
        case stop
    }

    static func parse(url: URL) -> DeepLinkAction? {
        guard url.scheme?.lowercased() == "coronasdr" else { return nil }
        let command = url.host?.lowercased() ?? url.pathComponents.dropFirst().first?.lowercased()

        switch command {
        case "tune":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let items = components?.queryItems ?? []

            guard
                let freqStr = items.first(where: { $0.name == "freq" })?.value,
                let freq = Int(freqStr),
                (minFrequencyHz...maxFrequencyHz).contains(freq)
            else {
                return nil
            }

            let mode = items.first(where: { $0.name == "mode" })?.value.flatMap { raw in
                DemodMode(rawValue: raw.uppercased())
            }
            return .tune(frequencyHz: freq, mode: mode)

        case "start":
            return .start

        case "stop":
            return .stop

        default:
            return nil
        }
    }
}

@Observable
@MainActor
final class DeepLinkCoordinator {
    var pendingAction: DeepLinkHandler.DeepLinkAction?
    private(set) var lastEventToken: UInt64 = 0

    func handle(url: URL) {
        guard let action = DeepLinkHandler.parse(url: url) else { return }
        pendingAction = action
        lastEventToken &+= 1
    }

    func consumePendingAction() -> DeepLinkHandler.DeepLinkAction? {
        defer { pendingAction = nil }
        return pendingAction
    }
}
