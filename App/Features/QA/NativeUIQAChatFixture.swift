import Foundation
import Observation

/// El JSON se codifica únicamente en RAM; nunca usa load, save o defaultURL del historial.
struct NativeUIQAChatFixture {
    enum Profile: String, CaseIterable, Identifiable {
        case ascii = "400 × 24 000 ASCII"
        case unicode = "400 × 24 000 Unicode"
        case aggregate = "JSON agregado cerca de 32 MiB"
        case references = "Fuentes y acciones locales"
        var id: String { rawValue }
    }
    enum Failure: Error { case invalidMessageLimit, invalidSessionLimit, encodedLimitExceeded }
    let profile: Profile
    let sessions: [AssistantStoredSession]
    let encodedBytes: Int
    var active: AssistantStoredSession { sessions[0] }

    static func make(_ profile: Profile) throws -> Self {
        let date = Date(timeIntervalSince1970: 0)
        func text(_ ordinal: Int, unicode: Bool) -> String {
            let prefix = String(format: "Mensaje %03d ", ordinal)
            let remaining = AssistantConversationStore.maximumMessageCharacters - prefix.count
            if unicode {
                return prefix + String(repeating: "🧩", count: 11_800)
                    + String(repeating: "漢", count: remaining - 11_800)
            }
            let unit = "Texto de ensayo local. "
            return prefix + String((String(repeating: unit, count: remaining / unit.count + 1)).prefix(remaining))
        }
        func session(_ count: Int, unicode: Bool) -> AssistantStoredSession {
            .init(id: UUID(), title: "Historial QA en RAM", createdAt: date, updatedAt: date,
                messages: (0..<count).map {
                    AssistantStoredMessage(isUser: $0.isMultiple(of: 2), text: text($0, unicode: unicode))
                })
        }
        let sessions: [AssistantStoredSession]
        switch profile {
        case .ascii, .unicode:
            sessions = [session(AssistantConversationStore.maximumMessagesPerSession, unicode: profile == .unicode)]
        case .aggregate:
            let full = (0..<3).map { _ in session(AssistantConversationStore.maximumMessagesPerSession, unicode: false) }
            let filler = session(AssistantConversationStore.maximumMessagesPerSession, unicode: false)
            var lower = 0
            var upper = filler.messages.count
            while lower < upper {
                let count = (lower + upper + 1) / 2
                var candidate = filler
                candidate.messages = Array(filler.messages.prefix(count))
                let bytes = try JSONEncoder().encode(full + [candidate]).count
                if bytes <= AssistantConversationStore.maximumFileBytes { lower = count }
                else { upper = count - 1 }
            }
            var partial = filler
            partial.messages = Array(filler.messages.prefix(lower))
            sessions = full + [partial]
        case .references:
            let references = (0..<8).map { ordinal in
                AssistantLinkReference(title: "Fuente local de ensayo \(ordinal + 1)",
                    url: "https://example.invalid/qa/\(ordinal)", summary: "Resumen sintético en RAM.",
                    collection: nil, tags: [], origin: ordinal.isMultiple(of: 2) ? .library : .web)
            }
            sessions = [.init(id: UUID(), title: "Fuentes QA", createdAt: date, updatedAt: date, messages: [
                .init(isUser: true, text: "Compara estas fuentes de ensayo."),
                .init(isUser: false, text: "Fuentes sintéticas verificadas solo para disposición.", references: references)
            ])]
        }
        return .init(profile: profile, sessions: sessions, encodedBytes: try validatedEncodedBytes(sessions))
    }

    /// Rechaza un payload completo fuera de contrato; no lo sanea ni lo recorta para hacer pasar QA.
    static func validatedEncodedBytes(_ sessions: [AssistantStoredSession]) throws -> Int {
        guard !sessions.isEmpty, sessions.count <= AssistantConversationStore.maximumSessions else {
            throw Failure.invalidSessionLimit
        }
        guard sessions.allSatisfy({ $0.messages.count <= AssistantConversationStore.maximumMessagesPerSession
            && $0.messages.allSatisfy({ $0.text.count <= AssistantConversationStore.maximumMessageCharacters }) }) else {
            throw Failure.invalidMessageLimit
        }
        let bytes = try JSONEncoder().encode(sessions).count
        guard bytes <= AssistantConversationStore.maximumFileBytes else { throw Failure.encodedLimitExceeded }
        return bytes
    }
}

/// Streaming sintético con cancelación y barrera de generación; no posee un modelo ni una conversación.
@MainActor
@Observable
final class NativeUIQAChatStream {
    private(set) var isRunning = false
    private(set) var inFlightTasks = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var tasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = 0

    func begin(from initial: String, to complete: String, interval: Duration = .milliseconds(40),
               onChunk: @escaping @MainActor (String) -> Void) {
        invalidate()
        guard initial.count < complete.count, complete.hasPrefix(initial) else { return }
        let token = generation
        isRunning = true
        inFlightTasks += 1
        task = Task { [weak self] in
            defer {
                if let self {
                    self.inFlightTasks -= 1
                    self.tasks.removeValue(forKey: token)
                    if self.generation == token { self.isRunning = false; self.task = nil }
                }
            }
            var count = initial.count
            while count < complete.count {
                do { try await Task.sleep(for: interval) }
                catch { return }
                guard let self, !Task.isCancelled, self.generation == token else { return }
                count = min(complete.count, count + 180)
                onChunk(String(complete.prefix(count)))
            }
        }
        tasks[token] = task
    }

    func invalidate() {
        generation &+= 1
        for pending in tasks.values { pending.cancel() }
        task = nil
        isRunning = false
    }

    func stopAndDrain() async {
        let pending = Array(tasks.values)
        invalidate()
        for task in pending { await task.value }
    }
}
