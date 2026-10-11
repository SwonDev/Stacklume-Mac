import Foundation

/// Estado de un proyecto entendido como ESPACIO DE TRABAJO: reúne en un panel todo lo
/// de aquello que estás construyendo (sus enlaces clave, una nota/scratchpad y un
/// estado). El modelo `Project` de SwiftData es de solo lectura (solo nombre/icono/
/// color), así que la nota, el estado y la pertenencia de enlaces se guardan FUERA del
/// esquema, en `@AppStorage` como JSON indexado por el UUID del proyecto — mismo patrón
/// que `CustomFeedStore` y las búsquedas guardadas (sin tocar paquetes read-only).
enum ProjectStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case active, paused, done

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .active: "Activo"
        case .paused: "En pausa"
        case .done: "Hecho"
        }
    }

    var symbol: String {
        switch self {
        case .active: "play.circle.fill"
        case .paused: "pause.circle.fill"
        case .done: "checkmark.circle.fill"
        }
    }

    var colorHex: String {
        switch self {
        case .active: "#34D399"
        case .paused: "#F59E0B"
        case .done: "#8A8F98"
        }
    }
}

/// Una tarea del proyecto (checklist simple — NO kanban). Conserva su `id` para
/// reordenar/togglear de forma estable.
struct ProjectTask: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var done: Bool = false
}

/// Datos del espacio de trabajo de UN proyecto. `linkIDs` conserva el orden de adición.
/// La decodificación es TOLERANTE a claves ausentes (`decodeIfPresent`) para no perder
/// los datos antiguos al ir añadiendo campos nuevos (tareas, comandos…).
struct ProjectWorkspace: Codable, Equatable {
    var status: ProjectStatus = .active
    var note: String = ""
    var linkIDs: [UUID] = []
    var tasks: [ProjectTask] = []
    var commands: [String] = []

    init(status: ProjectStatus = .active, note: String = "",
         linkIDs: [UUID] = [], tasks: [ProjectTask] = [], commands: [String] = []) {
        self.status = status
        self.note = note
        self.linkIDs = linkIDs
        self.tasks = tasks
        self.commands = commands
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(ProjectStatus.self, forKey: .status) ?? .active
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        linkIDs = try c.decodeIfPresent([UUID].self, forKey: .linkIDs) ?? []
        tasks = try c.decodeIfPresent([ProjectTask].self, forKey: .tasks) ?? []
        commands = try c.decodeIfPresent([String].self, forKey: .commands) ?? []
    }
}

/// Almacén ligero (JSON en `@AppStorage`) de los espacios de trabajo de los proyectos,
/// indexado por `Project.id`. El overload de `Data` de `@AppStorage` no persiste de
/// forma fiable, por eso se usa `String` (igual que `CustomFeedStore`).
enum ProjectWorkspaceStore {
    /// Clave de `@AppStorage` compartida por todas las vistas de proyectos.
    static let storageKey = "stacklume.projects.workspace"

    static func decodeAll(_ json: String) -> [String: ProjectWorkspace] {
        guard let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: ProjectWorkspace].self, from: data) else { return [:] }
        return map
    }

    static func encodeAll(_ map: [String: ProjectWorkspace]) -> String {
        guard let data = try? JSONEncoder().encode(map) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Workspace de un proyecto (uno vacío por defecto si aún no existe).
    static func workspace(for id: UUID, in json: String) -> ProjectWorkspace {
        decodeAll(json)[id.uuidString] ?? ProjectWorkspace()
    }

    /// Devuelve el JSON actualizado tras aplicar `transform` al workspace del proyecto.
    /// Pensado para asignarse directamente a la propiedad `@AppStorage`.
    static func updating(_ json: String, for id: UUID,
                         _ transform: (inout ProjectWorkspace) -> Void) -> String {
        var map = decodeAll(json)
        var ws = map[id.uuidString] ?? ProjectWorkspace()
        transform(&ws)
        map[id.uuidString] = ws
        return encodeAll(map)
    }

    /// Elimina el workspace de un proyecto (al borrar el proyecto). Devuelve el JSON nuevo.
    static func removing(_ json: String, for id: UUID) -> String {
        var map = decodeAll(json)
        map[id.uuidString] = nil
        return encodeAll(map)
    }
}
