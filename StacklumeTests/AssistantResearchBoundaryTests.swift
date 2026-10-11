import Foundation
import NaturalLanguage
import Testing

private struct FieldSnapshot: Sendable {
    let text: String
    let defaultSubjectIDs: Set<String>
    let allowedIDs: Set<String>
    let sources: [String: AssistantResearchSource]
}

private actor BoundaryLatch {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        entry?.resume(); entry = nil
        await withCheckedContinuation { release = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entry = $0 }
    }
    func resume() { release?.resume(); release = nil }
}

private enum BoundaryCPU {
    @concurrent
    static func validate(_ snapshot: FieldSnapshot, latch: BoundaryLatch? = nil) async throws -> [String] {
        try Task.checkCancellation()
        precondition(!Thread.isMainThread)
        if let latch { await latch.pause() }
        try Task.checkCancellation()
        let issues = AssistantResearchAnswer.structuredCapabilityIssues(in: snapshot.text,
            defaultSubjectIDs: snapshot.defaultSubjectIDs, allowedIDs: snapshot.allowedIDs, sources: snapshot.sources)
        try Task.checkCancellation()
        return issues
    }
    // Equivalente exacto del closure actual de LiquidConversation: cada instancia
    // permanece dentro de esta llamada y no cruza la frontera de aislamiento.
    static func language(_ text: String) -> String? {
        let english = NLLanguageRecognizer()
        english.processString(text)
        if english.dominantLanguage == .english,
           (english.languageHypotheses(withMaximum: 3)[.english] ?? 0) >= 0.65 { return "en" }
        let general = NLLanguageRecognizer()
        general.processString(text)
        return general.dominantLanguage == .spanish ? "es" : nil
    }
}

@MainActor
private final class PublicationHarness {
    var activeID = UUID()
    var gate = AssistantResponseGate()
    var published: [String]?
    func publish(_ snapshot: FieldSnapshot, ticket: AssistantResponseTicket, latch: BoundaryLatch) async throws -> Bool {
        let issues = try await BoundaryCPU.validate(snapshot, latch: latch)
        guard gate.accepts(ticket, activeSessionID: activeID), !Task.isCancelled else { return false }
        published = issues
        return true
    }
    func changeSession() { gate.invalidate(); activeID = UUID() }
}

@Suite("Frontera CPU — prototipo Swift 6, sin MLX ni app")
struct BoundaryTests {
    private func source(_ formats: String = "JSON") -> AssistantResearchSource {
        .init(title: "ApiOne", url: "https://example.org/apione", bookmarkID: UUID(), summary: "ApiOne implementa backend mediante una API REST. Permite exportación " + formats + ".", evidence: "", origin: .library, facets: [.engine, .integration], collection: nil, tags: [])
    }
    private func snapshot(_ sources: [String: AssistantResearchSource], text: String = "ApiOne implementa una API REST. Permite exportación JSON.") -> FieldSnapshot {
        .init(text: text, defaultSubjectIDs: ["B1"], allowedIDs: ["B1"], sources: sources)
    }
    private func acceptsSendable<Value: Sendable>(_ value: Value) {}

    @Test("Fuente, dossier, ticket y composición cruzan con Sendable verificado")
    @MainActor
    func signaturesAndOffMain() async throws {
        let record = source()
        acceptsSendable(record)
        acceptsSendable(AssistantResearchDossier())
        acceptsSendable(AssistantResearchPlan.make(request: "Quiero una app con backend.", priorUserRequests: []))
        acceptsSendable(AssistantResponseTicket(id: UUID(), sessionID: UUID()))
        acceptsSendable(AssistantResearchComposition(text: "", sources: ["B1": record], issues: [], rounds: 1, generatedCharacters: 0))
        let result = try await BoundaryCPU.validate(snapshot(["B1": record]))
        MainActor.preconditionIsolated()
        #expect(result.isEmpty)
        let detector: @Sendable (String) -> String? = BoundaryCPU.language
        #expect(detector("The server handles requests and exports data for the application.") == "en")
        #expect(detector("El servidor procesa las peticiones y exporta los datos de la aplicación.") == "es")
    }

    @Test("La fuente capturada no cambia al modificar la copia del caller")
    @MainActor
    func immutableSnapshot() async throws {
        var records = ["B1": source()]
        let captured = snapshot(records)
        let latch = BoundaryLatch()
        let worker = Task { try await BoundaryCPU.validate(captured, latch: latch) }
        await latch.waitForEntry()
        records["B1"] = source("CSV")
        await latch.resume()
        #expect(try await worker.value.isEmpty)
        #expect(!AssistantResearchAnswer.structuredCapabilityIssues(in: captured.text,
            defaultSubjectIDs: ["B1"], allowedIDs: ["B1"], sources: records).isEmpty)
    }

    @Test("La cancelación cruza @concurrent en la misma tarea")
    @MainActor
    func cancellation() async throws {
        let captured = snapshot(["B1": source()])
        let latch = BoundaryLatch()
        let worker = Task { try await BoundaryCPU.validate(captured, latch: latch) }
        await latch.waitForEntry()
        worker.cancel()
        await latch.resume()
        await #expect(throws: CancellationError.self) { _ = try await worker.value }
    }

    @Test("El ticket invalidado rechaza el resultado aun con índice de mensaje reutilizado")
    @MainActor
    func staleSession() async throws {
        let caller = PublicationHarness()
        let ticket = caller.gate.begin(sessionID: caller.activeID)
        let captured = snapshot(["B1": source()])
        let latch = BoundaryLatch()
        let worker = Task { try await caller.publish(captured, ticket: ticket, latch: latch) }
        await latch.waitForEntry()
        caller.changeSession()
        _ = caller.gate.begin(sessionID: caller.activeID)
        await latch.resume()
        #expect(try await !worker.value)
        #expect(caller.published == nil)
    }
}
