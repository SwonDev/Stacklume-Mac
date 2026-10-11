import AppKit
import ServiceManagement
import Observation

@Observable
@MainActor
final class LaunchAtLoginController {
    static let shared = LaunchAtLoginController()
    private(set) var enabled = false
    private(set) var needsApproval = false
    private(set) var message: String?

    private init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            message = nil
        } catch {
            message = "No se pudo cambiar el inicio con macOS: \(error.localizedDescription)"
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
