import Foundation
import AppKit
import SwiftData
import StacklumeCore
import StacklumeMetadata

/// Monitor PROACTIVO del portapapeles (opt-in, desactivado por defecto). Cuando detecta que
/// has copiado un enlace nuevo (que no está ya en la biblioteca), ofrece guardarlo con una
/// notificación discreta; al tocarla se guarda por el embudo único (`LinkIngest`, con IA).
///
/// Privacidad: solo se sondea `changeCount` (metadato barato) en cada tick; el CONTENIDO del
/// portapapeles solo se lee cuando cambia (una vez por copia), así no dispara constantemente
/// el indicador de pegado de macOS. Es opt-in y se puede desactivar en Ajustes.
@MainActor
final class ClipboardMonitor {
    /// Clave de `@AppStorage` compartida con Ajustes. Desactivado por defecto.
    static let enabledKey = "stacklume.clipboardWatch"

    private let container: ModelContainer
    private var timer: Timer?
    private var lastChangeCount: Int
    private var lastSuggested: String?
    private var preferenceObserver: NSObjectProtocol?

    init(container: ModelContainer) {
        self.container = container
        self.lastChangeCount = NSPasteboard.general.changeCount
        preferenceObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTimer() }
        }
        updateTimer()
    }

    private func updateTimer() {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else {
            timer?.invalidate(); timer = nil
            lastSuggested = nil
            MenuBarController.shared.suggestClipboard(nil)
            return
        }
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    private func tick() {
        guard CommercialLicenseManager.shared.hasAccess else { return }
        // El modo solo-menubar NO amplía permisos: si el usuario revoca el opt-in,
        // Stacklume deja de inspeccionar el contenido del portapapeles en cualquier estado.
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        // Solo aquí se LEE el contenido (una vez por copia).
        guard let saveable = ClipboardLink.currentSaveable() else {
            lastSuggested = nil; MenuBarController.shared.suggestClipboard(nil); return
        }
        let context = container.mainContext
        let effective = CommandDetector.detect(saveable)?.registryURL ?? saveable
        if SavedLinkLookup.shared.contains(effective, in: context) {
            lastSuggested = nil; MenuBarController.shared.suggestClipboard(nil); return
        }
        guard saveable != lastSuggested else { return }
        lastSuggested = saveable
        MenuBarController.shared.suggestClipboard(saveable)
        Task { await ReminderService.notifyClipboardSuggestion(url: saveable) }
    }
}
