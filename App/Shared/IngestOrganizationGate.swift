import Foundation

/// La protección dura lo mismo que el enriquecido; una edición humana posterior la invalida.
struct IngestOrganizationGate {
    private var tickets: [UUID: UUID] = [:]

    mutating func begin(_ bookmarkID: UUID) -> UUID {
        let ticket = UUID()
        tickets[bookmarkID] = ticket
        return ticket
    }

    func accepts(_ ticket: UUID, for bookmarkID: UUID) -> Bool {
        tickets[bookmarkID] == ticket
    }

    mutating func invalidate(_ bookmarkID: UUID) { tickets.removeValue(forKey: bookmarkID) }

    mutating func finish(_ ticket: UUID, for bookmarkID: UUID) {
        if accepts(ticket, for: bookmarkID) { tickets.removeValue(forKey: bookmarkID) }
    }
}
