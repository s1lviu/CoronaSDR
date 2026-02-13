import Foundation
import SDRModels

/// Handles deep links via custom URL scheme: coronasdr://
/// Examples:
///   coronasdr://tune?freq=100000000&mode=WFM
///   coronasdr://start
///   coronasdr://stop
enum DeepLinkHandler {
    enum DeepLinkAction {
        case tune(frequencyHz: Int, mode: DemodMode?)
        case start
        case stop
    }

    static func parse(url: URL) -> DeepLinkAction? {
        guard url.scheme == "coronasdr" else { return nil }

        switch url.host {
        case "tune":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let items = components?.queryItems ?? []

            guard let freqStr = items.first(where: { $0.name == "freq" })?.value,
                  let freq = Int(freqStr) else {
                return nil
            }

            let mode = items.first(where: { $0.name == "mode" })?.value.flatMap { raw in
                DemodMode(rawValue: raw)
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
