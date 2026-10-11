import Foundation

/// Secciones del sidebar de la ventana principal de Stacklume en Mac.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case home, stats, library, favorites, readingQueue, sessions, projects, categories, tags, rules, ai, trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Inicio"
        case .stats: "Estadísticas"
        case .library: "Biblioteca"
        case .favorites: "Favoritos"
        case .readingQueue: "Cola de lectura"
        case .sessions: "Sesiones"
        case .projects: "Proyectos"
        case .categories: "Categorías"
        case .tags: "Etiquetas"
        case .rules: "Reglas"
        case .ai: "Asistente IA"
        case .trash: "Papelera"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .stats: "chart.bar.fill"
        case .library: "books.vertical"
        case .favorites: "star"
        case .readingQueue: "clock"
        case .sessions: "rectangle.stack.fill"
        case .projects: "folder"
        case .categories: "square.grid.2x2"
        case .tags: "tag"
        case .rules: "wand.and.stars"
        case .ai: "sparkles"
        case .trash: "trash"
        }
    }

    /// Texto de la acción principal de la sección (botón de cristal del estado
    /// vacío). `nil` si la sección no ofrece una creación directa.
    var primaryAction: String? {
        switch self {
        case .library: "Añadir enlace"
        case .sessions: "Nueva sesión"
        case .projects: "Nuevo proyecto"
        case .categories: "Nueva categoría"
        case .tags: "Nueva etiqueta"
        case .rules: "Nueva regla"
        default: nil
        }
    }

    /// Mensaje del estado vacío, con tono de marca, mientras la sección no tiene
    /// su vista real (bloques posteriores).
    var emptyMessage: String {
        switch self {
        case .home: "Tu panel personal. Aquí verás un resumen de tu actividad y tus accesos rápidos."
        case .stats: "Guarda algunos enlaces y aquí verás tus estadísticas: racha, progreso de lectura y dominios principales."
        case .library: "Aún no has guardado ningún enlace. Empieza por el primero y constrúyete una biblioteca a tu medida."
        case .favorites: "Marca tus enlaces favoritos para tenerlos siempre a un clic."
        case .readingQueue: "Tu cola de lectura está vacía. Guarda enlaces para leerlos con calma más tarde."
        case .sessions: "Agrupa los enlaces que sueles abrir juntos y ábrelos todos de una vez."
        case .projects: "Agrupa en proyectos lo que va junto y mantén cada cosa en su sitio."
        case .categories: "Crea categorías para clasificar tu biblioteca con orden y claridad."
        case .tags: "Usa etiquetas de color para encontrar cualquier enlace al instante."
        case .rules: "Crea reglas para clasificar tus enlaces automáticamente al guardarlos."
        case .ai: "Tu asistente local. Clasifica, resume y organiza tu biblioteca con IA on-device."
        case .trash: "La papelera está vacía. Lo que elimines aparecerá aquí antes de borrarse para siempre."
        }
    }
}
