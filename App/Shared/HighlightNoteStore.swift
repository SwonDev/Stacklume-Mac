import Foundation

/// Nota/anotación opcional por resaltado (además del fragmento citado). Como el modelo
/// `Highlight` vive en un paquete read-only y no se le puede añadir un campo, la nota se
/// guarda aparte en `UserDefaults` (un diccionario JSON keyed por el `id` del resaltado).
/// Las notas huérfanas (de resaltados borrados) se purgan al arrancar (`prune(keeping:)`).
enum HighlightNoteStore {
    private static let key = "stacklume.highlightNotes"

    /// Nota del resaltado, o cadena vacía si no tiene.
    static func note(for id: UUID) -> String { dict()[id.uuidString] ?? "" }

    static func notes(for ids: [UUID]) -> [String] {
        let values = dict()
        return ids.compactMap { values[$0.uuidString] }.filter { !$0.isEmpty }
    }

    /// Guarda (o borra, si queda vacía) la nota de un resaltado.
    static func setNote(_ note: String, for id: UUID) {
        var d = dict()
        let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { d.removeValue(forKey: id.uuidString) } else { d[id.uuidString] = clean }
        UserDefaults.standard.set(try? JSONEncoder().encode(d), forKey: key)
    }

    /// Elimina notas en lote para evitar decodificar/codificar el diccionario por resaltado.
    static func remove(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        var d = dict()
        let previousCount = d.count
        for id in ids { d.removeValue(forKey: id.uuidString) }
        if d.count != previousCount {
            UserDefaults.standard.set(try? JSONEncoder().encode(d), forKey: key)
        }
    }

    /// Elimina las notas cuyos resaltados ya no existen (limpieza de huérfanas).
    static func prune(keeping ids: Set<UUID>) {
        let keep = Set(ids.map(\.uuidString))
        let d = dict()
        let filtered = d.filter { keep.contains($0.key) }
        if filtered.count != d.count {
            UserDefaults.standard.set(try? JSONEncoder().encode(filtered), forKey: key)
        }
    }

    /// Borra TODAS las notas (restablecer la app).
    static func removeAll() { UserDefaults.standard.removeObject(forKey: key) }

    private static func dict() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let d = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return d
    }
}
