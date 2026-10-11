import Foundation
import SwiftData
import Carbon.HIToolbox
import StacklumeCore
import StacklumeMetadata

/// Opciones del atajo GLOBAL de guardado rápido. Persistido en `@AppStorage`
/// (`stacklume.quickSaveShortcut`) y elegible en Ajustes. Permite desactivarlo o
/// cambiarlo para evitar conflictos con ⌃⌘S de otras apps.
enum QuickSaveShortcut: String, CaseIterable, Identifiable {
    case off, ctrlCmdS, optCmdS, shiftCmdS, ctrlOptCmdS, ctrlCmdB

    var id: String { rawValue }

    /// Clave de `@AppStorage` compartida por el coordinador y por Ajustes.
    static let storageKey = "stacklume.quickSaveShortcut"
    static var current: QuickSaveShortcut {
        QuickSaveShortcut(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .ctrlCmdS
    }

    var displayName: String {
        switch self {
        case .off: "Desactivado"
        case .ctrlCmdS: "⌃⌘S"
        case .optCmdS: "⌥⌘S"
        case .shiftCmdS: "⇧⌘S"
        case .ctrlOptCmdS: "⌃⌥⌘S"
        case .ctrlCmdB: "⌃⌘B"
        }
    }

    /// Código de tecla virtual; `nil` si está desactivado.
    var keyCode: UInt32? {
        switch self {
        case .off: nil
        case .ctrlCmdS, .optCmdS, .shiftCmdS, .ctrlOptCmdS: UInt32(kVK_ANSI_S)
        case .ctrlCmdB: UInt32(kVK_ANSI_B)
        }
    }

    /// Máscara de modificadores Carbon.
    var carbonModifiers: UInt32 {
        switch self {
        case .off: 0
        case .ctrlCmdS: UInt32(controlKey | cmdKey)
        case .optCmdS: UInt32(optionKey | cmdKey)
        case .shiftCmdS: UInt32(shiftKey | cmdKey)
        case .ctrlOptCmdS: UInt32(controlKey | optionKey | cmdKey)
        case .ctrlCmdB: UInt32(controlKey | cmdKey)
        }
    }
}

/// Registra el atajo GLOBAL de guardado rápido: guarda al instante el enlace que haya
/// en el portapapeles, sin abrir la app, con feedback por notificación. Reutiliza el
/// mismo camino de alta que el resto (`LinkIngest`, con enriquecido IA en 2.º plano).
/// Se re-registra en vivo al cambiar el atajo en Ajustes (`stacklumeReloadHotKey`).
@MainActor
final class QuickSaveCoordinator {
    private let container: ModelContainer
    private var hotKey: GlobalHotKey?

    init(container: ModelContainer) {
        self.container = container
        register()
        NotificationCenter.default.addObserver(
            forName: .stacklumeReloadHotKey, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.register() }
        }
        // Sugerencia del monitor de portapapeles: al tocar la notificación, guarda esa URL.
        NotificationCenter.default.addObserver(
            forName: .stacklumeSaveURL, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let url = note.object as? String else { return }
            Task { @MainActor in QuickSaveCoordinator.saveSpecific(url, container: self.container) }
        }
    }

    /// Guarda una URL concreta (sugerencia del portapapeles), con dedup y feedback.
    static func saveSpecific(_ urlString: String, container: ModelContainer) {
        guard CommercialLicenseManager.shared.hasAccess else { return }
        let context = container.mainContext
        if isInLibrary(urlString, in: context) {
            Task { await ReminderService.notifyNow(title: "Ya estaba guardado", body: urlString.urlHost) }
            return
        }
        LinkIngest.ingestLink(urlString: urlString, in: context, aiEnrich: true)
        MenuBarController.shared.pulse()   // gira el icono del menubar como feedback
        Task { await ReminderService.notifyNow(title: "Guardado en Stacklume", body: urlString.urlHost) }
    }

    /// (Re)registra el atajo según la preferencia actual. Soltar el `GlobalHotKey`
    /// anterior lo desregistra (su `deinit`). Si está «Desactivado», no registra ninguno.
    func register() {
        hotKey = nil
        guard CommercialLicenseManager.shared.hasAccess else { return }
        let shortcut = QuickSaveShortcut.current
        MenuBarController.shared.configurePopoverShortcut(enabled: shortcut != .off)
        guard let keyCode = shortcut.keyCode else { return }
        let container = self.container
        hotKey = GlobalHotKey(keyCode: keyCode, modifiers: shortcut.carbonModifiers) {
            Task { @MainActor in QuickSaveCoordinator.saveFromClipboard(container: container) }
        }
    }

    static func saveFromClipboard(container: ModelContainer) {
        guard CommercialLicenseManager.shared.hasAccess else { return }
        let context = container.mainContext
        // Acepta una URL o un COMANDO de instalación (npm i…) — app para desarrolladores.
        guard let saveable = ClipboardLink.currentSaveable() else {
            Task { await ReminderService.notifyNow(title: "Stacklume",
                                                   body: "No hay ningún enlace ni comando en el portapapeles.") }
            return
        }
        let command = CommandDetector.detect(saveable)
        let body = command.map { "Comando: \($0.command)" } ?? saveable.urlHost
        if isInLibrary(saveable, in: context) {
            Task { await ReminderService.notifyNow(title: "Ya estaba guardado", body: body) }
            return
        }
        LinkIngest.ingestLink(urlString: saveable, in: context, aiEnrich: true)
        MenuBarController.shared.pulse()   // gira el icono del menubar como feedback
        Task { await ReminderService.notifyNow(title: "Guardado en Stacklume", body: body) }
    }

    private static func isInLibrary(_ input: String, in context: ModelContext) -> Bool {
        // Compara por clave EXACTA ([[CanonicalURL]]). Si es un comando, se compara por la
        // página del registro a la que apunta (igual que se guardará).
        let effective = CommandDetector.detect(input)?.registryURL ?? input
        let key = CanonicalURL.key(effective)
        let active = (try? context.fetch(FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        return active.contains { CanonicalURL.key($0.url) == key }
    }
}
