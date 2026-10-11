import Foundation

/// Una referencia guardada no demuestra que haya bytes decodificables. Se prueban
/// todas sus variantes locales antes de adquirir una, conservando siempre el origen.
enum CoverRecoveryPolicy {
    enum Result: Equatable, Sendable {
        case stored
        case acquired
        case unavailable
        case cancelled
    }

    @MainActor
    static func recover(
        reference: String?,
        stored: (URL) async -> Bool,
        acquire: (URL) async -> Bool
    ) async -> Result {
        let candidates = HDImage.candidates(reference).compactMap { candidate in
            candidate.flatMap(URL.init(string:))
        }
        for url in candidates {
            guard !Task.isCancelled else { return .cancelled }
            if await stored(url) { return Task.isCancelled ? .cancelled : .stored }
        }
        for url in candidates {
            guard !Task.isCancelled else { return .cancelled }
            guard StacklumeAutomationPolicy.allowsAutomaticNetworkURL(url) else { continue }
            if await acquire(url) { return Task.isCancelled ? .cancelled : .acquired }
        }
        return Task.isCancelled ? .cancelled : .unavailable
    }
}
