import Foundation

/// Archivado en la **Wayback Machine** (archive.org): guarda una copia PERMANENTE de la página
/// en internet, complementaria a la copia offline local. Es un diferenciador de Raindrop Pro.
///
/// PRIVACIDAD / principio 100 % local: esto es lo ÚNICO que envía una URL a un tercero, así que
/// SOLO se dispara por acción EXPLÍCITA del usuario (un botón «Archivar»), nunca en segundo
/// plano ni al ingerir. No se sube contenido del usuario: archive.org rastrea la página pública.
enum WaybackArchive {
    private static let saveBase = "https://web.archive.org/save/"
    private static let viewBase = "https://web.archive.org/web/"

    /// Lanza el «Save Page Now» de archive.org para la URL. Devuelve `true` si el servicio
    /// aceptó la captura. Best-effort: puede tardar; un timeout no garantiza fallo (la captura
    /// suele completarse igual), pero solo registramos como archivado si hay respuesta válida.
    @discardableResult
    static func archive(_ urlString: String) async -> Bool {
        guard let sourceURL = StacklumeAutomationPolicy.openableStoredURL(urlString),
              StacklumeAutomationPolicy.allowsExternalCaptureURL(sourceURL)
        else {
            return false
        }
        guard let saveURL = url(saveBase + urlString) else { return false }
        var request = URLRequest(url: saveURL, timeoutInterval: 90)
        request.httpMethod = "GET"
        request.setValue("Stacklume/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let response = try await ExternalHTTPClient.shared.response(for: request)
            let ok = response.statusCode < 400
            if ok { WaybackStore.markArchived(urlString) }
            return ok
        } catch {
            return false
        }
    }

    /// URL de la copia archivada (la MÁS RECIENTE): `web.archive.org/web/<url>` redirige a la
    /// última captura disponible. Para abrir en el navegador.
    static func snapshotURL(for urlString: String) -> URL? {
        guard let sourceURL = StacklumeAutomationPolicy.openableStoredURL(urlString),
              StacklumeAutomationPolicy.allowsExternalCaptureURL(sourceURL)
        else {
            return nil
        }
        return url(viewBase + urlString)
    }

    /// Construye una `URL` admitiendo URLs con caracteres que `URL(string:)` rechazaría, sin
    /// re-codificar lo ya válido (Wayback espera la URL destino LITERAL tras `/save/` o `/web/`).
    private static func url(_ string: String) -> URL? {
        if let u = URL(string: string) { return u }
        let allowed = CharacterSet(charactersIn: "!#$&'()*+,/:;=?@-._~%").union(.alphanumerics)
        return string.addingPercentEncoding(withAllowedCharacters: allowed).flatMap(URL.init(string:))
    }
}

/// Registro lateral de qué enlaces se han archivado en la Wayback Machine y cuándo. El modelo
/// `Bookmark` es read-only (paquete), así que se guarda en `UserDefaults` indexado por la clave
/// canónica de la URL ([[CanonicalURL]]), igual que [[ReadingProgressStore]].
enum WaybackStore {
    private static let key = "stacklume.waybackArchived"
    private static let maxEntries = 5000

    /// ¿Se archivó esta URL alguna vez? (clave canónica → marca de tiempo ISO).
    static func isArchived(_ urlString: String) -> Bool {
        dict()[CanonicalURL.key(urlString)] != nil
    }

    /// Marca la URL como archivada ahora (ISO-8601).
    static func markArchived(_ urlString: String) {
        var d = dict()
        d[CanonicalURL.key(urlString)] = ISO8601DateFormatter().string(from: Date())
        if d.count > maxEntries { d = Dictionary(uniqueKeysWithValues: Array(d).suffix(maxEntries)) }
        UserDefaults.standard.set(try? JSONEncoder().encode(d), forKey: key)
    }

    /// Todas las entradas (clave canónica → fecha ISO), para el backup completo.
    static func allEntries() -> [String: String] { dict() }

    /// Restaura una entrada por su clave canónica (desde el backup). ADITIVO: no pisa si ya existe.
    static func restore(urlKey: String, date: String) {
        var d = dict()
        guard d[urlKey] == nil else { return }
        d[urlKey] = date
        UserDefaults.standard.set(try? JSONEncoder().encode(d), forKey: key)
    }

    static func removeAll() { UserDefaults.standard.removeObject(forKey: key) }

    private static func dict() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let d = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return d
    }
}
