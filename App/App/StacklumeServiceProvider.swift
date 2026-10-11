import AppKit
import Carbon
import AppIntents

/// Proveedor del SERVICIO de macOS «Guardar en Stacklume»: aparece en el menú Servicios
/// (y en el menú contextual) de CUALQUIER app cuando hay una URL o texto seleccionado.
/// Lee la selección y la ingiere reutilizando el deep link `stacklume://add` (mismo camino
/// que la extensión de compartir → dedup + enriquecido con IA). Algo que una web no puede:
/// integración a nivel de sistema. Declarado en `App/Resources/Info.plist` (NSServices).
/// `@MainActor`: el sistema de Servicios despacha el método en el hilo principal.
@MainActor
final class StacklumeServiceProvider: NSObject {
    static let shared = StacklumeServiceProvider()

    /// `NSMessage` declarado en Info.plist. Firma fija que exige el sistema de Servicios.
    @objc func saveToStacklume(_ pboard: NSPasteboard, userData: String?,
                               error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        guard let raw = extractURL(from: pboard), !raw.isEmpty else {
            error?.pointee = "No se encontró ningún enlace en la selección." as NSString
            return
        }
        var components = URLComponents()
        components.scheme = "stacklume"
        components.host = "add"
        components.queryItems = [URLQueryItem(name: "url", value: raw)]
        guard let deepLink = components.url else { return }
        NSWorkspace.shared.open(deepLink)
    }

    /// Extrae una URL de la selección: una URL directa del pasteboard, o el primer enlace
    /// del texto seleccionado (o el texto entero como posible URL «desnuda»).
    private func extractURL(from pboard: NSPasteboard) -> String? {
        if let url = pboard.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL {
            return url.absoluteString
        }
        if let text = pboard.string(forType: .string) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return firstHTTPURL(in: trimmed) ?? trimmed
        }
        return nil
    }

    private func firstHTTPURL(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, range: range)?.url?.absoluteString
    }
}

/// Delegado de la app: registra el proveedor de Servicios, arranca el icono de la barra de
/// menús (`MenuBarController`) y gestiona el ciclo de vida ventana ⇄ solo-menubar. SwiftUI no
/// expone `NSApp.servicesProvider` ni la política de activación, así que se hace aquí vía
/// `@NSApplicationDelegateAdaptor`. `@MainActor`: AppKit despacha el delegate en el hilo
/// principal y así puede tocar el `MenuBarController` (también `@MainActor`) sin saltos de actor.
@MainActor
final class StacklumeAppDelegate: NSObject, NSApplicationDelegate {
    private var launchedAtLogin = false

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        recordLaunchEvent()
        return false
    }

    func applicationWillFinishLaunching(_ notification: Notification) { recordLaunchEvent() }

    private func recordLaunchEvent() {
        launchedAtLogin = launchedAtLogin || StacklumeLaunchPolicy.isLoginEvent(NSAppleEventManager.shared().currentAppleEvent)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        recordLaunchEvent()
        // Refresca Atajos tras el registro nativo del proceso; el broker podía
        // solicitar otra instancia cuando se hacía antes, en App.init.
        StacklumeShortcuts.updateAppShortcutParameters()
        if CanonicalXAuditEntry.isRequested {
            Task { @MainActor in
                await CanonicalXAuditEntry.prepareIfRequested()
            }
        }
        ModelCatalogTemporaryMedia.purgeOnLaunch()
        ModelCatalogDownloads.purgeOnLaunch()
        NSApp.servicesProvider = StacklumeServiceProvider.shared
        // Refresca el registro de Servicios del sistema (para que aparezca sin reiniciar sesión).
        NSUpdateDynamicServices()
        MenuBarController.shared.start()
        StacklumeUpdater.shared.start()
        // Al cerrar la última ventana NO se termina la app: sigue viva en el menubar.
        let quiet = StacklumeLaunchPolicy.startsInMenuBar(arguments: ProcessInfo.processInfo.arguments,
                                                        loginEvent: launchedAtLogin)
        NSApp.setActivationPolicy(quiet ? .accessory : .regular)
        MenuBarController.shared.setMenuBarOnly(quiet)
        if !quiet {
            Task { @MainActor in MenuBarController.shared.showMainWindow() }
        }
        // Cuando se cierra una ventana, recalcula si hay que pasar a modo solo-menubar.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowsChanged(_:)),
            name: NSWindow.willCloseNotification, object: nil)
    }

    /// Al cerrar la última ventana, la app NO termina: el icono del menubar la mantiene viva
    /// (guardado rápido + autodetección de enlaces copiados). Para cerrarla del todo: «Salir».
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Si reabren la app (p. ej. desde Spotlight estando en modo accessory), muestra la ventana.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Activar el popover no debe sustituirlo por la biblioteca.
        if MenuBarController.shared.isPopoverVisible { return false }
        MenuBarController.shared.showMainWindow()
        return false
    }

    /// Tras cerrarse una ventana, en el siguiente ciclo (cuando ya no está en `NSApp.windows`)
    /// comprueba si quedan ventanas de contenido: si no, sale del dock (`.accessory`) y queda
    /// SOLO en el menubar.
    @objc private func windowsChanged(_ note: Notification) {
        Task { @MainActor in self.updateActivationPolicy() }
    }

    /// `.regular` (con icono en el dock) si hay alguna ventana de contenido visible; `.accessory`
    /// (solo menubar, fuera del dock) si no queda ninguna. Avisa al `MenuBarController` para que
    /// libere los recursos pesados en modo solo-menubar.
    func updateActivationPolicy() {
        let hasContentWindow = MenuBarController.hasVisibleContentWindow
        NSApp.setActivationPolicy(hasContentWindow ? .regular : .accessory)
        MenuBarController.shared.setMenuBarOnly(!hasContentWindow)
    }

    /// Cierre LIMPIO para evitar el crash de MLX/Metal al salir.
    ///
    /// El modelo de IA local corre sobre MLX (Metal). Al terminar el proceso, el destructor
    /// ESTÁTICO del scheduler de MLX (`mlx::core::scheduler::Scheduler::~Scheduler`) se ejecuta
    /// durante `__cxa_finalize` e intenta SINCRONIZAR la GPU (`MTLCommandBuffer waitUntilCompleted`)
    /// cuando Metal ya se está desmontando → `SIGABRT` (abort trap 6). Como el proceso va a morir
    /// igualmente y TODA la persistencia es explícita (`context.save()` durante el uso, los stores
    /// laterales escriben al instante, no al salir), terminamos AQUÍ con `_exit(0)`, que se salta
    /// esos destructores estáticos problemáticos. Es el patrón habitual al embeber MLX/Metal.
    func applicationWillTerminate(_ notification: Notification) {
        // Los dos stores de memoria usan debounce; fuerza el último snapshot antes de que
        // `_exit(0)` corte cualquier tarea pendiente.
        ConversationMemory.shared.flushNow()
        EntityGraph.shared.flushNow()
        ModelCatalogTemporaryMedia.purgeOnTermination()
        ModelCatalogDownloads.purgeOnTermination()
        _exit(0)
    }
}
