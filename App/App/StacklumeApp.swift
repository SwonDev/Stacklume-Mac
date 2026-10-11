import SwiftUI
import SwiftData
import AppIntents
import UserNotifications
import StacklumePersistence

/// Identificadores internos de escenas. Centralizarlos evita que el icono del menubar
/// intente abrir una escena distinta a la declarada por la aplicación.
enum StacklumeWindowID {
    /// `library` reemplaza al antiguo `main`, cuyo historial de restauración quedó
    /// contaminado por múltiples aperturas externas en versiones anteriores.
    static let main = "library"
}

struct StacklumeApp: App {
    private let qaIsolation = CanonicalQAIsolation.requireBeforeStartup(
        environment: ProcessInfo.processInfo.environment, arguments: ProcessInfo.processInfo.arguments)
    /// Registra el proveedor del Servicio de macOS «Guardar en Stacklume» al arrancar.
    @NSApplicationDelegateAdaptor(StacklumeAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    let container: ModelContainer
    /// Mantiene vivo el atajo GLOBAL ⌃⌘S de guardado rápido del portapapeles.
    private let quickSave: QuickSaveCoordinator
    /// Monitor PROACTIVO del portapapeles (opt-in): sugiere guardar los enlaces copiados.
    private let clipboardMonitor: ClipboardMonitor

    init() {
        ScrollDiagnostics.configure(environment: ProcessInfo.processInfo.environment)
        // Barras de desplazamiento con el dorado de marca (en vez del gris del sistema).
        ScrollerTint.apply()
        // Recordatorios «leer más tarde»: muestra las notificaciones en primer plano
        // y abre el enlace al tocarlas (igual que en el iPhone).
        UNUserNotificationCenter.current().delegate = ReminderNotificationDelegate.shared
        let isMarketingDemo = MarketingDemoRuntime.isActive
        let container = PersistenceController.makeContainer(inMemory: isMarketingDemo)
        CanonicalQAIsolation.requireAfterContainer(qaIsolation, container: container)
        if isMarketingDemo {
            MarketingDemoRuntime.seed(into: container)
        }
        self.container = container
        // Undo/Redo (⌘Z): el contexto principal registra las operaciones para poder
        // deshacerlas (borrar, mover, editar…). Límite acotado para no crecer sin fin.
        let undo = UndoManager()
        undo.levelsOfUndo = 30
        container.mainContext.undoManager = undo
        // Atajo global ⌃⌘S: guarda al instante el enlace del portapapeles.
        self.quickSave = QuickSaveCoordinator(container: container)
        // Monitor proactivo del portapapeles: no lee contenido si está desactivado en
        // Ajustes, tampoco cuando la app queda solo en la barra de menús.
        self.clipboardMonitor = ClipboardMonitor(container: container)
        // Icono de la barra de menús (NSStatusItem propio, animado): le pasamos el contenedor.
        // El `StacklumeAppDelegate` lo arranca en `applicationDidFinishLaunching`.
        MenuBarController.shared.container = container
    }

    var body: some Scene {
        let _ = registerWindowOpener()
        // `Window` expresa la semántica real del producto: una única biblioteca principal.
        // A diferencia de `WindowGroup`, sucesivas aperturas externas reutilizan esta ventana
        // en lugar de crear instancias completas adicionales de SwiftUI + SwiftData.
        Window("Stacklume", id: StacklumeWindowID.main) {
            RootWindowView()
                .stacklumeTextScalePreference()
        }
        .modelContainer(container)
        .commands { StacklumeCommands() }
        // Stacklume es una biblioteca de ventana principal única. Sus preferencias reales
        // (vista, filtros, tamaños, tema) ya se persisten de forma explícita; restaurar cada
        // instancia histórica de `WindowGroup` puede multiplicar ventanas tras una ráfaga de
        // deep links y disparar el coste de SwiftData por cada una. Siempre abre una escena
        // principal limpia y reutiliza la aplicación viva para los eventos externos.
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        // Chrome unificado de macOS 26: el título no se duplica porque cada sección
        // ya presenta su identidad en la cabecera funcional Liquid Glass.
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        // Una app de escritorio premium abre con un lienzo generoso, no con una
        // ventana minúscula.
        .defaultSize(width: RootWindowLayoutMetrics.minimumWindowWidth, height: 760)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .stacklumeTextScalePreference()
                .modelContainer(container)
        }

        // Ventana de Ayuda (menú Ayuda · ⌘?). Escena independiente: HelpView inyecta
        // el tema activo por su cuenta, igual que SettingsView.
        Window("Ayuda de Stacklume", id: HelpView.windowID) {
            HelpView()
                .stacklumeTextScalePreference()
                .modelContainer(container)
        }
        .defaultSize(width: 720, height: 720)
        .windowResizability(.contentMinSize)

        // El icono de la barra de menús (arriba a la derecha) ya NO es un `MenuBarExtra`: es un
        // `NSStatusItem` propio (`MenuBarController`) para poder ANIMAR el icono y mantenerlo vivo
        // solo en el menubar al cerrar la ventana. Reutiliza la misma UI (`MenuBarView`) en un
        // `NSPopover`. Lo arranca `StacklumeAppDelegate.applicationDidFinishLaunching`.
    }

    private func registerWindowOpener() {
        MenuBarController.shared.openMainWindow = { openWindow(id: StacklumeWindowID.main) }
    }
}
