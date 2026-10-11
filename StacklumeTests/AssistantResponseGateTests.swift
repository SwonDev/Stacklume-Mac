import Foundation
import Testing

@Suite("Asistente IA — aislamiento de respuestas")
struct AssistantResponseGateTests {
    @Test("Una respuesta cancelada no puede escribir en la siguiente")
    func staleResponseIsRejected() {
        let session = UUID()
        var gate = AssistantResponseGate()
        let first = gate.begin(sessionID: session)

        gate.invalidate()
        let second = gate.begin(sessionID: session)

        #expect(!gate.accepts(first, activeSessionID: session))
        #expect(gate.accepts(second, activeSessionID: session))
        let staleFinished = gate.finish(first)
        let activeFinished = gate.finish(second)
        #expect(!staleFinished)
        #expect(activeFinished)
    }

    @Test("Un ticket nunca atraviesa un cambio de sesión")
    func ticketIsBoundToSession() {
        let original = UUID()
        let replacement = UUID()
        var gate = AssistantResponseGate()
        let ticket = gate.begin(sessionID: original)

        #expect(gate.accepts(ticket, activeSessionID: original))
        #expect(!gate.accepts(ticket, activeSessionID: replacement))
    }

    @Test("Finalizar dos veces es idempotente")
    func finishIsIdempotent() {
        var gate = AssistantResponseGate()
        let ticket = gate.begin(sessionID: UUID())

        let firstFinish = gate.finish(ticket)
        let secondFinish = gate.finish(ticket)
        #expect(firstFinish)
        #expect(!secondFinish)
        #expect(gate.current == nil)
    }
}
