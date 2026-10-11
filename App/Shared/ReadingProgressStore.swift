import Foundation

/// Progreso de lectura por enlace (porcentaje de scroll 0–1), para «continuar donde lo
/// dejaste» en el lector. Se guarda en `UserDefaults` (un único diccionario JSON) porque el
/// modelo `Bookmark` vive en un paquete read-only y no se le puede añadir un campo.
/// La clave es la canónica de la URL ([[CanonicalURL]]), así http/https/www/tracking comparten
/// progreso. No se guardan los extremos (recién empezado o casi terminado).
enum ReadingProgressStore {
    private static let key = "stacklume.readingProgress"
    private static let maxEntries = 3000

    /// Progreso guardado (0–1) para una clave canónica ya calculada, o 0 si no hay.
    static func progress(forKey urlKey: String) -> Double { dict()[urlKey] ?? 0 }

    /// Progreso guardado (0–1) para una URL cruda (la canonicaliza), o 0 si no hay.
    static func progress(forURL url: String) -> Double { dict()[CanonicalURL.key(url)] ?? 0 }

    /// Guarda el progreso (0–1). Descarta los extremos (≤3% o ≥97%) para no «recordar» el
    /// principio ni marcar como pendiente algo ya terminado.
    static func setProgress(_ p: Double, forKey urlKey: String) {
        var d = dict()
        if p <= 0.03 || p >= 0.97 {
            d.removeValue(forKey: urlKey)
        } else {
            d[urlKey] = (p * 1000).rounded() / 1000
        }
        // Cota de tamaño: si crece demasiado, conserva una muestra (nunca es incorrecto perder
        // progreso antiguo; se recalcula al volver a leer).
        if d.count > maxEntries { d = Dictionary(uniqueKeysWithValues: Array(d).suffix(maxEntries)) }
        UserDefaults.standard.set(try? JSONEncoder().encode(d), forKey: key)
    }

    /// Elimina en una sola escritura el progreso de varias URLs.
    static func remove(forURLs urls: [String]) {
        guard !urls.isEmpty else { return }
        var d = dict()
        let previousCount = d.count
        for url in urls { d.removeValue(forKey: CanonicalURL.key(url)) }
        if d.count != previousCount {
            UserDefaults.standard.set(try? JSONEncoder().encode(d), forKey: key)
        }
    }

    /// Borra TODO el progreso (restablecer la app).
    static func removeAll() { UserDefaults.standard.removeObject(forKey: key) }

    /// Todas las entradas (clave canónica → %), para el backup completo.
    static func allEntries() -> [String: Double] { dict() }

    private static func dict() -> [String: Double] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let d = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return d
    }
}
