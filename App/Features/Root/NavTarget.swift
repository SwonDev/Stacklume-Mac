import Foundation

/// Destino de navegación de la columna izquierda (estilo raindrop). La selección
/// del sidebar es un `NavTarget?` que dirige la columna central (`SectionContentView`).
///
/// Reemplaza al antiguo `SidebarSection` como modelo de selección: además de las
/// vistas de herramienta (sesiones, proyectos, reglas, estadísticas, IA, papelera),
/// expresa los accesos de sistema (todos, bandeja, sin clasificar, favoritos, cola), las
/// colecciones (`BookmarkCategory`), las etiquetas (`Tag`) y los filtros inteligentes.
enum NavTarget: Hashable {
    /// Todos los enlaces activos (no archivados ni en papelera). Landing por defecto.
    case all
    /// Capturas pendientes de triaje (`readingStatus == .inbox`).
    case inbox
    /// Enlaces activos sin colección (bandeja «Sin clasificar»).
    case unsorted
    /// Enlaces marcados como favoritos.
    case favorites
    /// Cola de lectura: enlaces con `readingStatus != .done`.
    case readingQueue
    /// Todos los resaltados de la biblioteca, agrupados por enlace (como «Highlights»
    /// de Raindrop).
    case highlights
    /// Explorador visual de relaciones semánticas completamente local.
    case connections
    /// Colección concreta (`BookmarkCategory`) por id, incluyendo descendientes.
    case collection(UUID)
    /// Etiqueta concreta (`Tag`) por id.
    case tag(UUID)
    /// Filtro inteligente (artículos, vídeos, rotos…).
    case smart(SmartFilter)
    /// Búsqueda guardada (Smart Folder) por id: texto + filtros combinados que el usuario
    /// guardó, expuesta como nodo de primer nivel en el lateral.
    case savedSearch(UUID)
    /// Sección «Descubrir» (feeds).
    case discover
    case huggingFace
    case civitai
    /// Conexión integrada con X (Twitter): navegador embebido nativo donde el usuario
    /// inicia sesión con su cuenta; al guardar un tweet (bookmark) se ingiere en Stacklume.
    case x
    case sessions
    case projects
    /// Espacio de trabajo de un proyecto concreto por id (abre `ProjectWorkspaceView`).
    case project(UUID)
    case rules
    case stats
    case ai
    case trash

    var usesExpandedWorkspace: Bool {
        switch self {
        case .ai, .x, .huggingFace, .civitai: true
        default: false
        }
    }

    /// Clave estable (string) para el deep link / menú «Ir» (`stacklumeGoToSection`).
    /// Solo cubre los destinos fijos; colecciones/etiquetas/filtros no se listan en
    /// el menú porque son dinámicos.
    var key: String {
        switch self {
        case .all: "all"
        case .inbox: "inbox"
        case .unsorted: "unsorted"
        case .favorites: "favorites"
        case .readingQueue: "readingQueue"
        case .highlights: "highlights"
        case .connections: "connections"
        case .collection(let id): "collection:\(id.uuidString)"
        case .tag(let id): "tag:\(id.uuidString)"
        case .smart(let f): "smart:\(f.rawValue)"
        case .savedSearch(let id): "saved:\(id.uuidString)"
        case .discover: "discover"
        case .huggingFace: "huggingFace"
        case .civitai: "civitai"
        case .x: "x"
        case .sessions: "sessions"
        case .projects: "projects"
        case .project(let id): "project:\(id.uuidString)"
        case .rules: "rules"
        case .stats: "stats"
        case .ai: "ai"
        case .trash: "trash"
        }
    }

    /// Reconstruye un destino fijo (o smart) a partir de su `key`. Devuelve `nil`
    /// si la clave no corresponde a un destino direccionable por el menú «Ir».
    init?(key: String) {
        switch key {
        case "all": self = .all
        case "inbox": self = .inbox
        case "unsorted": self = .unsorted
        case "favorites": self = .favorites
        case "readingQueue": self = .readingQueue
        case "highlights": self = .highlights
        case "connections": self = .connections
        case "discover": self = .discover
        case "huggingFace": self = .huggingFace
        case "civitai": self = .civitai
        case "x": self = .x
        case "sessions": self = .sessions
        case "projects": self = .projects
        case "rules": self = .rules
        case "stats": self = .stats
        case "ai": self = .ai
        case "trash": self = .trash
        default:
            if key.hasPrefix("smart:"),
               let f = SmartFilter(rawValue: String(key.dropFirst("smart:".count))) {
                self = .smart(f)
            } else if key.hasPrefix("project:"),
                      let id = UUID(uuidString: String(key.dropFirst("project:".count))) {
                self = .project(id)
            } else if key.hasPrefix("saved:"),
                      let id = UUID(uuidString: String(key.dropFirst("saved:".count))) {
                self = .savedSearch(id)
            } else {
                return nil
            }
        }
    }
}
