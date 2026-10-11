import Foundation

/// Criterio de agrupación de la lista (paridad con Raindrop «Group by»). Aplica SOLO a
/// las vistas Lista y Titulares —las visuales (Cuadrícula/Moodboard) no se agrupan, igual
/// que Raindrop—. `none` = sin secciones (comportamiento clásico).
enum LibraryGrouping: String, CaseIterable, Identifiable {
    case none, collection, domain, type, dateAdded
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: "Sin agrupar"
        case .collection: "Colección"
        case .domain: "Dominio"
        case .type: "Tipo"
        case .dateAdded: "Fecha"
        }
    }
    var icon: String {
        switch self {
        case .none: "rectangle.grid.1x2"
        case .collection: "folder"
        case .domain: "globe"
        case .type: "doc.text"
        case .dateAdded: "calendar"
        }
    }
}

/// Preferencia de visualización de UNA sección de la biblioteca (paridad con
/// Raindrop, que recuerda la vista y los ajustes de cada colección por separado).
/// Guarda el modo de vista, el «amplificador» de tamaño de portada y la agrupación.
struct LibraryViewPref: Codable, Equatable {
    /// `LibraryViewMode.rawValue` (list/grid/moodboard/headlines).
    var mode: String
    /// Multiplicador del tamaño de portada en Cuadrícula/Moodboard. 1.0 = tamaño base.
    var coverScale: Double
    /// `LibraryGrouping.rawValue` (none/collection/domain/type/dateAdded).
    var grouping: String

    init(mode: String, coverScale: Double = 1.0, grouping: String = LibraryGrouping.none.rawValue) {
        self.mode = mode
        self.coverScale = coverScale
        self.grouping = grouping
    }

    // Decodificación TOLERANTE: el JSON guardado por versiones anteriores no trae
    // `coverScale` ni `grouping`; se rellenan con sus valores por defecto en vez de fallar.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(String.self, forKey: .mode)
        coverScale = try c.decodeIfPresent(Double.self, forKey: .coverScale) ?? 1.0
        grouping = try c.decodeIfPresent(String.self, forKey: .grouping) ?? LibraryGrouping.none.rawValue
    }
}

/// Codifica/decodifica el diccionario `scope → LibraryViewPref` que persiste en
/// `@AppStorage` (forma interoperable JSON, igual que las búsquedas guardadas y el
/// workspace de proyectos). La «scope» es la clave estable del `NavTarget`
/// (`all`, `collection:<uuid>`, `tag:<uuid>`, `smart:<f>`…), de modo que CADA
/// sección recuerda su propia vista y su tamaño de portada.
enum LibraryViewPrefsStore {
    static func decode(_ json: String) -> [String: LibraryViewPref] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: LibraryViewPref].self, from: data)
        else { return [:] }
        return dict
    }

    static func encode(_ dict: [String: LibraryViewPref]) -> String {
        guard let data = try? JSONEncoder().encode(dict),
              let json = String(data: data, encoding: .utf8)
        else { return "" }
        return json
    }
}
