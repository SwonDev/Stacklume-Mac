import AppKit
import SwiftUI
import SwiftData
import Carbon.HIToolbox

/// Controlador del icono de la barra de menús (arriba a la derecha). Sustituye al
/// `MenuBarExtra` de SwiftUI para poder: (1) ANIMAR el icono (12 frames template de giro,
/// como feedback al guardar/detectar) y (2) controlar el ciclo de vida (seguir vivo solo en
/// el menubar cuando se cierra la ventana). Reutiliza la MISMA UI del popover (`MenuBarView`)
/// dentro de un `NSPopover` (no se reescribe nada del popover).
///
/// Singleton `@MainActor`: lo arranca el `StacklumeAppDelegate` y lo alimenta `StacklumeApp`
/// con el `ModelContainer`.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    static let shared = MenuBarController()

    /// Contenedor de SwiftData (lo fija `StacklumeApp.init` antes de `start()`).
    var container: ModelContainer?
    /// Closure para abrir/crear la ventana principal (lo aporta `RootWindowView`, que sí vive
    /// en el árbol de escenas y tiene `openWindow`). Necesario porque un `NSHostingController`
    /// suelto no puede usar `@Environment(\.openWindow)`.
    var openMainWindow: (() -> Void)?

    /// ¿La app está SOLO en el menubar (ventana cerrada, fuera del dock)?
    /// Es estado de ciclo de vida; nunca concede acceso adicional al portapapeles.
    private(set) var isMenuBarOnly = false

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    // Animación de giro (feedback).
    private var frames: [NSImage] = []
    private var spinTimer: Timer?
    private var spinIndex = 0
    /// Frames de animación que quedan por mostrar (cada `pulse()` añade una vuelta).
    private var spinRemaining = 0
    private var pendingSuggestion: String?
    private var popoverHotKey: GlobalHotKey?
    var isPopoverVisible: Bool { popover?.isShown == true }

    private override init() { super.init() }

    // MARK: - Arranque

    func start() {
        guard statusItem == nil else { return }
        loadFrames()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = frames.first
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.toolTip = "Stacklume — Guardado rápido (⌃⌥⌘B)"
            button.setAccessibilityLabel("Stacklume · Guardado rápido")
        }
        statusItem = item
        configurePopoverShortcut(enabled: QuickSaveShortcut.current != .off)

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        popover = pop
    }

    /// Retira el acceso lateral al desactivar una licencia comercial. Es reversible:
    /// una activación posterior llama de nuevo a `start()` sin reiniciar la app.
    func stop() {
        popoverHotKey = nil
        stopSpin()
        popover?.performClose(nil)
        popover = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        isMenuBarOnly = false
    }

    /// Carga los 12 frames del Asset Catalog como imágenes template (18×18 pt, como recomienda
    /// el README de los assets). macOS las tiñe según el tema de la barra (claro/oscuro).
    private func loadFrames() {
        frames = (0..<12).compactMap { i in
            guard let img = NSImage(named: String(format: "StacklumeMenuSpin-%02d", i)) else { return nil }
            img.isTemplate = true
            img.size = NSSize(width: 18, height: 18)
            return img
        }
    }

    // MARK: - Popover

    func configurePopoverShortcut(enabled: Bool) {
        popoverHotKey = nil
        guard enabled, statusItem != nil else { return }
        popoverHotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_B),
                                    modifiers: UInt32(controlKey | optionKey | cmdKey)) { [weak self] in
            Task { @MainActor in self?.togglePopover(nil) }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        // Recrea el contenido en cada apertura → estado fresco (portapapeles, recientes).
        if let container {
            popover.contentViewController = NSHostingController(
                rootView: MenuBarView().modelContainer(container).stacklumeTextScalePreference())
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func showQuickSave() {
        if !isPopoverVisible { togglePopover(nil) }
    }

    func continueInMenuBar() {
        for window in NSApp.windows where Self.isContentWindow(window) {
            window.performClose(nil)
        }
        // Dejar concluir los cierres, también de Ajustes/Ayuda. Si una ventana rechaza
        // el cierre, conservar el modo de ventanas en vez de declarar un modo falso.
        Task { @MainActor in
            await Task.yield()
            let hasContent = Self.hasVisibleContentWindow
            NSApp.setActivationPolicy(hasContent ? .regular : .accessory)
            setMenuBarOnly(!hasContent)
            if !hasContent { showQuickSave() }
        }
    }

    static var hasVisibleContentWindow: Bool {
        NSApp.windows.contains(where: isContentWindow)
    }

    private static func isContentWindow(_ window: NSWindow) -> Bool {
        window.isVisible && window.canBecomeMain
            && !window.className.contains("Popover")
            && !window.className.contains("StatusBar")
    }

    /// Cierra el popover (lo llama la UI tras «Abrir Stacklume»).
    func closePopover() { popover?.performClose(nil) }

    // MARK: - Animación de feedback

    /// Hace girar el icono una vuelta completa (feedback al guardar o detectar un enlace).
    /// Acumulable: si llega otro `pulse()` durante el giro, encadena otra vuelta.
    func pulse() {
        guard !frames.isEmpty, statusItem?.button != nil else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        spinRemaining = min(spinRemaining + frames.count, frames.count * 2)
        guard spinTimer == nil else { return }
        spinIndex = 0
        // 12 frames · 0.06 s ≈ 0.72 s por vuelta (rango sugerido por el README).
        let t = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceSpin() }
        }
        RunLoop.main.add(t, forMode: .common)
        spinTimer = t
    }

    private func advanceSpin() {
        guard let button = statusItem?.button, !frames.isEmpty else { stopSpin(); return }
        button.image = frames[spinIndex % frames.count]
        spinIndex += 1
        spinRemaining -= 1
        if spinRemaining <= 0 { stopSpin() }
    }

    private func stopSpin() {
        spinTimer?.invalidate()
        spinTimer = nil
        spinIndex = 0
        spinRemaining = 0
        statusItem?.button?.image = frames.first   // vuelve al marcador base
    }

    // MARK: - Ciclo de vida (dock ⇄ solo menubar)

    /// Marca si estamos en modo solo-menubar (lo decide `StacklumeAppDelegate` según queden o no
    /// ventanas de contenido). Cambiar a este modo arranca el «pulso» para confirmar visualmente
    /// que Stacklume sigue activo en la barra.
    func setMenuBarOnly(_ only: Bool) {
        let changed = only != isMenuBarOnly
        isMenuBarOnly = only
        if only, changed {
            LocalAIRunner.shared.unload()
            MultimodalSearchService.shared.suspendBackgroundWork()
            Task { try? await EmbeddingGemmaRuntime.shared.releaseModelMemory() }
        } else if changed, let context = container?.mainContext {
            MultimodalSearchService.shared.attach(context: context)
        }
    }

    func showMainWindow() {
        closePopover()
        NSApp.setActivationPolicy(.regular)
        setMenuBarOnly(false)
        openMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func suggestClipboard(_ value: String?) {
        pendingSuggestion = value
        statusItem?.button?.title = value == nil ? "" : " +"
        statusItem?.button?.toolTip = value == nil ? "Stacklume — Guardado rápido" : "Stacklume — Hay un enlace para guardar"
        statusItem?.button?.setAccessibilityLabel(value == nil ? "Stacklume · Guardado rápido" : "Stacklume · Guardar enlace copiado")
        if value != nil { pulse() }
    }

    func popoverDidClose(_ notification: Notification) {
        // El contenido y su sondeo solo viven mientras el popover está visible.
        popover?.contentViewController = nil
    }
}
