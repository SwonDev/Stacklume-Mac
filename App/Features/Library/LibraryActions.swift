import SwiftUI
import StacklumeCore

/// Destino del editor de enlace.
enum EditorTarget: Identifiable {
    case new(prefilledURL: String?)
    case edit(Bookmark)
    var id: String {
        switch self {
        case .new: "new"
        case .edit(let link): link.id.uuidString
        }
    }
}

/// Acciones de Biblioteca compartidas por la ventana (abrir el editor desde el
/// sidebar, estados vacíos, toolbar o menú). Inyectado por `@Environment`.
@MainActor @Observable
final class LibraryActions {
    var editorTarget: EditorTarget?
    /// Página a previsualizar en la app (Vista rápida). La presenta `RootWindowView`.
    var quickLookTarget: IdentifiableURL?
    /// Enlace para el que abrir el selector BUSCABLE de etiquetas / colección desde el menú
    /// contextual. Antes el menú listaba TODAS las etiquetas inline (miles) → se construían eager
    /// con faults de SwiftData y congelaba la app. Ahora el menú abre estos pickers (List perezosa).
    /// Los presenta `LibraryListView`.
    var tagPickerLink: Bookmark?
    var collectionPickerLink: Bookmark?
    func newLink(url: String? = nil) { editorTarget = .new(prefilledURL: url) }
    func edit(_ link: Bookmark) { editorTarget = .edit(link) }
    func pickTags(for link: Bookmark) { tagPickerLink = link }
    func pickCollection(for link: Bookmark) { collectionPickerLink = link }
    func quickLook(_ url: URL, offlineHTML: String? = nil) {
        quickLookTarget = IdentifiableURL(url: url, offlineHTML: offlineHTML)
    }
}

extension Notification.Name {
    /// La dispara el menú Archivo › Nuevo enlace (⌘N).
    static let stacklumeNewLink = Notification.Name("stacklume.newLink")
    /// La dispara `UserActivityMonitor` al detectar scroll/swipe del trackpad: la capa de la hover
    /// preview la oculta para que no tape las acciones de swipe ni estorbe al desplazarte.
    static let stacklumeUserScrolled = Notification.Name("stacklume.userScrolled")
    /// Pide a la ventana re-comprobar el PORTAPAPELES YA (no solo al activar la app). La dispara
    /// la sección X cuando detecta una copia nueva (p. ej. «Copiar enlace» del menú contextual del
    /// WebView): así el banner «Añadir» del portapapeles ofrece el enlace EXTERNO recién copiado.
    static let stacklumeCheckClipboard = Notification.Name("stacklume.checkClipboard")
    /// La dispara el WebView de X cuando el usuario abre un enlace EXTERNO (clic o `target="_blank"`):
    /// la sección X lo abre en el NAVEGADOR INTERNO (con AdBlock) en vez de sacar al usuario de X.
    /// `userInfo["url"]`: la `URL` externa a abrir.
    static let xOpenExternalURL = Notification.Name("stacklume.x.openExternalURL")
    /// La dispara el menú Archivo › Nueva colección (⌘⇧N).
    static let stacklumeNewCollection = Notification.Name("stacklume.newCollection")
    /// La dispara el menú Ir para navegar a una sección del sidebar.
    /// `object`: `String` con el `rawValue` de `SidebarSection`.
    static let stacklumeGoToSection = Notification.Name("stacklume.goToSection")
    /// La dispara el menú Tema para cambiar el tema activo.
    /// `object`: `String` con el `id` (rawValue) del `Theme`.
    static let stacklumeSetTheme = Notification.Name("stacklume.setTheme")
    /// La dispara el menú Edición › Buscar (⌘K) para abrir la paleta de comandos.
    static let stacklumeOpenCommandPalette = Notification.Name("stacklume.openCommandPalette")
    /// Menú Enlace › Favorito (⌘D): alterna favorito en el/los enlace(s) seleccionado(s).
    static let stacklumeFavoriteSelected = Notification.Name("stacklume.favoriteSelected")
    /// Menú Enlace › Mover a la papelera (⌘⌫): manda a la papelera el/los seleccionado(s).
    static let stacklumeTrashSelected = Notification.Name("stacklume.trashSelected")
    /// Menú Enlace › Abrir original (⌘O): abre la URL del enlace seleccionado (si hay uno).
    static let stacklumeOpenSelected = Notification.Name("stacklume.openSelected")
    /// Menú Enlace › Vista rápida (⌘Y): previsualiza la página del enlace seleccionado en la app.
    static let stacklumeQuickLookSelected = Notification.Name("stacklume.quickLookSelected")
    /// Menú Enlace › Copiar enlace: copia al portapapeles la(s) URL(s) seleccionada(s).
    static let stacklumeCopySelected = Notification.Name("stacklume.copySelected")
    /// Menú Enlace › Copiar como Markdown (⌥⌘C): copia `[título](url)` por línea.
    static let stacklumeCopyMarkdownSelected = Notification.Name("stacklume.copyMarkdownSelected")
    /// Menú Enlace › Editar (⌘E): abre el editor del enlace seleccionado (si hay uno).
    static let stacklumeEditSelected = Notification.Name("stacklume.editSelected")
    /// Menú Enlace › Marcar como leído/pendiente (⌘U): alterna el estado de lectura.
    static let stacklumeToggleReadSelected = Notification.Name("stacklume.toggleReadSelected")
    /// Menú Enlace › Archivar/Desarchivar (⇧⌘A): alterna el archivado de la selección.
    static let stacklumeArchiveSelected = Notification.Name("stacklume.archiveSelected")
    /// Ajustes cambió el atajo global de guardado rápido → el coordinador lo re-registra.
    static let stacklumeReloadHotKey = Notification.Name("stacklume.reloadHotKey")
    /// Menú Visualización (⌃⌘1–4) o la IA cambian el modo de vista de la SECCIÓN activa.
    /// `object`: `String` con el `rawValue` del `LibraryViewMode`. La lista activa lo
    /// aplica a su preferencia por sección (paridad Raindrop: vista recordada por colección).
    static let stacklumeSetViewMode = Notification.Name("stacklume.setViewMode")
    /// Deshacer / Rehacer del menú Edición (⌘Z / ⇧⌘Z) cuando el foco NO es un campo de texto:
    /// la ventana deshace la última operación del `modelContext` (borrar, mover, editar…).
    static let stacklumeUndo = Notification.Name("stacklume.undo")
    static let stacklumeRedo = Notification.Name("stacklume.redo")
    /// «Pegar enlaces» (⌘⇧V): guarda todas las URLs/comandos del portapapeles (una por línea).
    static let stacklumePasteLinks = Notification.Name("stacklume.pasteLinks")
    /// Archivo › Importar pestañas abiertas… (⌥⌘I): abre el selector local de pestañas
    /// de Safari y navegadores Chromium que ya estén ejecutándose.
    static let stacklumeImportOpenTabs = Notification.Name("stacklume.importOpenTabs")
}
