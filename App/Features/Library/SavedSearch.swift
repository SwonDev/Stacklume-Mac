import Foundation

/// Una búsqueda guardada de la Biblioteca: captura el texto y los filtros activos
/// para reaplicarlos en un clic (equivalente a `saved-searches` de la web). Se
/// serializa en `@AppStorage` (sin esquema nuevo en SwiftData). Porte fiel del
/// modelo del iPhone: misma forma JSON, así las búsquedas son interoperables.
struct SavedSearch: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var searchText: String
    var smartFilter: String?    // SmartFilter.rawValue
    var platform: String?       // Platform.rawValue
    var contentType: String?    // ContentType.rawValue
    var categoryID: UUID?
    var onlyFavorites: Bool
    var sort: String            // LinkSort.rawValue
}

/// Almacén ligero de búsquedas guardadas respaldado por un `String` JSON de
/// `@AppStorage` (el overload de `Data` no persiste de forma fiable).
enum SavedSearchStore {
    static func decode(_ json: String) -> [SavedSearch] {
        guard let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([SavedSearch].self, from: data) else { return [] }
        return list
    }
    static func encode(_ list: [SavedSearch]) -> String {
        guard let data = try? JSONEncoder().encode(list) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
