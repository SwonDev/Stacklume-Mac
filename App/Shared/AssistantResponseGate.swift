import Foundation

/// Identidad inmutable de una respuesta del asistente. Una tarea solo puede modificar la
/// conversación mientras su ticket siga siendo el activo y pertenezca a la misma sesión.
/// Esto evita que una generación cancelada escriba tarde sobre otro chat.
struct AssistantResponseTicket: Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
}

/// Compuerta determinista para las tareas de respuesta. Es Foundation puro para probar las
/// carreras de cancelación/cambio de sesión sin cargar SwiftData ni MLX.
struct AssistantResponseGate: Sendable {
    private(set) var current: AssistantResponseTicket?

    mutating func begin(sessionID: UUID) -> AssistantResponseTicket {
        let ticket = AssistantResponseTicket(id: UUID(), sessionID: sessionID)
        current = ticket
        return ticket
    }

    func accepts(_ ticket: AssistantResponseTicket, activeSessionID: UUID) -> Bool {
        current == ticket && ticket.sessionID == activeSessionID
    }

    @discardableResult
    mutating func finish(_ ticket: AssistantResponseTicket) -> Bool {
        guard current == ticket else { return false }
        current = nil
        return true
    }

    @discardableResult
    mutating func invalidate() -> AssistantResponseTicket? {
        defer { current = nil }
        return current
    }
}
