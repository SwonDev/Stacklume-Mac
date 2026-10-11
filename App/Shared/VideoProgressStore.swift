import Foundation

/// Progreso de visionado por vídeo (segundos), para «continuar viendo» donde lo dejaste —igual
/// que el progreso de lectura ([[ReadingProgressStore]])—. Se guarda en `UserDefaults` (un único
/// diccionario JSON) porque el modelo `Bookmark` vive en un paquete read-only. La clave es la
/// canónica de la URL ([[CanonicalURL]]). No se guardan los primeros segundos (recién empezado).
enum VideoProgressStore {
    private static let key = "stacklume.videoProgress"
    private static let maxEntries = 2000
    /// Por debajo de esto se considera «recién empezado» y no se recuerda.
    private static let minSeconds: Double = 10

    /// Segundos guardados para reanudar una URL (0 si no hay).
    static func progress(for url: String) -> Double { dict()[CanonicalURL.key(url)] ?? 0 }

    /// Guarda el segundo actual. Descarta el principio para no «recordar» algo apenas empezado.
    static func save(_ seconds: Double, for url: String) {
        let urlKey = CanonicalURL.key(url)
        var d = dict()
        if seconds < minSeconds {
            guard d[urlKey] != nil else { return }   // nada que borrar
            d.removeValue(forKey: urlKey)
        } else {
            // El reproductor avisa cada segundo; solo se escribe si cambió ≥5 s (evita I/O constante).
            if let existing = d[urlKey], abs(existing - seconds) < 5 { return }
            d[urlKey] = seconds.rounded()
        }
        if d.count > maxEntries { d = Dictionary(uniqueKeysWithValues: Array(d).suffix(maxEntries)) }
        UserDefaults.standard.set(try? JSONEncoder().encode(d), forKey: key)
    }

    /// Borra el progreso de una URL (p. ej. al terminar el vídeo).
    static func clear(for url: String) {
        var d = dict()
        guard d.removeValue(forKey: CanonicalURL.key(url)) != nil else { return }
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

    /// Todas las entradas (clave canónica → segundos), para el backup completo.
    static func allEntries() -> [String: Double] { dict() }

    static func removeAll() { UserDefaults.standard.removeObject(forKey: key) }

    private static func dict() -> [String: Double] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let d = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
        return d
    }
}
