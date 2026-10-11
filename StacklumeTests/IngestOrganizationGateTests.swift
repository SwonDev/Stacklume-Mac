import Foundation
import Testing

struct IngestOrganizationGateTests {
    @Test("Mover o editar el enlace invalida la organización pendiente de su alta")
    func humanEditWins() {
        var gate = IngestOrganizationGate()
        let id = UUID()
        let ticket = gate.begin(id)
        #expect(gate.accepts(ticket, for: id))
        gate.invalidate(id)
        #expect(gate.accepts(ticket, for: id) == false)
    }

    @Test("Editar un enlace conserva la protección de los demás")
    func independentBookmarks() {
        var gate = IngestOrganizationGate()
        let first = UUID(), second = UUID()
        let firstTicket = gate.begin(first), secondTicket = gate.begin(second)
        gate.invalidate(first)
        #expect(gate.accepts(firstTicket, for: first) == false)
        #expect(gate.accepts(secondTicket, for: second))
    }

    @Test("Terminar un trabajo antiguo no invalida otro posterior")
    func staleCompletionCannotInvalidateNewJob() {
        var gate = IngestOrganizationGate()
        let id = UUID()
        let old = gate.begin(id), current = gate.begin(id)
        gate.finish(old, for: id)
        #expect(gate.accepts(current, for: id))
        gate.finish(current, for: id)
        #expect(gate.accepts(current, for: id) == false)
    }
}
