import Foundation

@MainActor enum CanonicalXAuditEntry {
    // El short-circuit conserva la ruta normal sin construir el runner QA.
    static var isRequested: Bool {
        CommandLine.arguments.contains("--stacklume-x91-diagnostic")
            || CommandLine.arguments.contains("--descriptor-sha256")
    }

    static var isArmed: Bool {
        isRequested && CanonicalXAuditCoordinator.shared.status == .armed
    }

    static var canRun: Bool {
        isRequested && CanonicalXAuditCoordinator.shared.canRun
    }

    static func prepareIfRequested() async {
        guard isRequested else { return }
        await CanonicalXAuditCoordinator.shared.prepareFromLaunchArguments()
    }

    static func runIfArmed() async {
        guard canRun else { return }
        await CanonicalXAuditCoordinator.shared.runArmedAudit()
    }
}
