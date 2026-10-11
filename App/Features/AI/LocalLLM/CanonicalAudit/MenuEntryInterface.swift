import Foundation

// Contrato para la integración futura del menú; ninguna implementación se añade a App.
@MainActor protocol CanonicalXAuditMenuEntry: AnyObject {
    var canRun: Bool { get }
    var status: CanonicalXAuditStatus { get }
    func prepareFromLaunchArguments() async
    func runArmedAudit() async
}

enum CanonicalXAuditStatus: String, Sendable {
    case disarmed, armed, running, finished, failed
}
