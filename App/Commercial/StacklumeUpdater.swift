import Foundation
import Sparkle

/// Canal de actualización firmado para la edición gratuita. Sparkle verifica
/// EdDSA antes de aceptar cada archivo y no transmite claves de licencia.
@MainActor
final class StacklumeUpdater {
    static let shared = StacklumeUpdater()

    private let controller: SPUStandardUpdaterController
    private(set) var isStarted = false

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func start() {
        guard !isStarted else { return }
        controller.startUpdater()
        isStarted = true
    }

    func checkForUpdates() {
        guard isStarted else { return }
        controller.updater.checkForUpdates()
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }
}
