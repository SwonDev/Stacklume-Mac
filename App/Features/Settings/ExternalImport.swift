import Foundation

// Orígenes de importación EXTERNOS (no navegadores locales): archivo HTML de marcadores
// con jerarquía de carpetas y estrellas de GitHub. Ambos producen `[BrowserBookmark]`
// para pasar por el núcleo compartido `BrowserImportRunner.ingest` (dedup, carpetas →
// colecciones, autoenriquecido con IA). Así NO se duplica la lógica de guardado.
//
// Nota: el paquete read-only tiene `NetscapeBookmarks.parse`, pero es PLANO (solo
// url+título, ignora `<H3>`/carpetas). Aquí se hace un parser CON carpetas para que el
// import de HTML sea de primera clase (colecciones desde las carpetas), igual que el de
// navegadores.

// MARK: - Archivo HTML de marcadores (Netscape) con carpetas

enum NetscapeHTMLImporter {
    /// Parsea el HTML de marcadores recorriendo `<H3>` (carpetas), `</DL>` (cierre) y
    /// `<A HREF>` (enlaces) EN ORDEN, manteniendo una pila de carpetas. Cada enlace queda
    /// asignado a la carpeta que lo contiene (su colección). Compatible con las
    /// exportaciones de Raindrop, Pocket, Pinboard, Instapaper y los navegadores.
    static func parse(_ html: String) -> [BrowserBookmark] {
        (try? parseChecked(html)) ?? []
    }

    static func parseChecked(_ html: String) throws -> [BrowserBookmark] {
        guard html.utf8.count <= ImportSafety.maximumTextBytes else { throw ImportSafetyError.limitExceeded }
        let pattern = #"<H3[^>]*>(.*?)</H3>|(</DL>)|<A\s+[^>]*?HREF="([^"]*)"[^>]*>(.*?)</A>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        var stack: [String] = []          // pila de carpetas abiertas (la última = actual)
        var out: [BrowserBookmark] = []
        var exceeded = false
        regex.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            guard let match else { return }
            guard match.range.length <= ImportSafety.maximumShortFieldBytes * 8 else {
                exceeded = true; stop.pointee = true; return
            }
            if match.range(at: 1).location != NSNotFound {            // <H3>carpeta</H3>
                guard stack.count < ImportSafety.maximumDepth else {
                    exceeded = true; stop.pointee = true; return
                }
                stack.append(clean(ns.substring(with: match.range(at: 1))))
            } else if match.range(at: 2).location != NSNotFound {     // </DL> → cierra carpeta
                if !stack.isEmpty { stack.removeLast() }
            } else if match.range(at: 3).location != NSNotFound {     // <A HREF>…</A>
                guard out.count < ImportSafety.maximumRecords else {
                    exceeded = true; stop.pointee = true; return
                }
                let url = ns.substring(with: match.range(at: 3))
                guard let validated = StacklumeAutomationPolicy.openableStoredURL(url) else { return }
                let rawTitle = match.range(at: 4).location != NSNotFound
                    ? ns.substring(with: match.range(at: 4)) : ""
                let title = clean(rawTitle)
                out.append(BrowserBookmark(url: validated.absoluteString,
                                           title: title.isEmpty ? validated.absoluteString : title,
                                           folder: stack.last ?? ""))
            }
        }
        guard !exceeded else { throw ImportSafetyError.limitExceeded }
        try ImportSafety.validateBookmarks(out)
        return out
    }

    /// Quita etiquetas y decodifica las entidades HTML comunes; recorta espacios.
    private static func clean(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                        "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - GitHub Stars (por usuario, vía API pública)

enum GitHubStarsImporter {
    enum ImportError: LocalizedError {
        case emptyUsername, userNotFound, rateLimited, network

        var errorDescription: String? {
            switch self {
            case .emptyUsername: "Escribe un nombre de usuario de GitHub."
            case .userNotFound: "No se encontró ese usuario en GitHub."
            case .rateLimited: "GitHub limitó las peticiones; inténtalo de nuevo dentro de un rato."
            case .network: "No se pudo conectar con GitHub. Revisa tu conexión."
            }
        }
    }

    /// Tope de páginas (100 repos/página). Sin token, GitHub permite 60 peticiones/hora;
    /// 20 páginas = hasta 2000 estrellas con margen de sobra. Si hubiera más, se importan
    /// las primeras 2000 (las más recientes primero).
    private static let maxPages = 20

    /// Trae los repos marcados con estrella por `username` y los mapea a `BrowserBookmark`
    /// (colección «GitHub Stars», título «owner/repo», descripción + lenguaje como semilla).
    static func fetch(username: String) async throws -> [BrowserBookmark] {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@/"))
        guard !user.isEmpty else { throw ImportError.emptyUsername }
        guard let enc = user.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw ImportError.network
        }

        var out: [BrowserBookmark] = []
        var seen = Set<String>()
        for page in 1...maxPages {
            guard let url = URL(string:
                "https://api.github.com/users/\(enc)/starred?per_page=100&page=\(page)") else { break }
            var req = URLRequest(url: url)
            req.timeoutInterval = 20
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("Stacklume/1.0 (macOS; bookmark manager)", forHTTPHeaderField: "User-Agent")

            let result: ExternalHTTPResponse
            do {
                result = try await ExternalHTTPClient.shared.data(
                    for: req,
                    maximumBytes: 8 * 1_024 * 1_024,
                    acceptedStatusCodes: 200...499,
                    allowedMIMEPrefixes: ["application/json"]
                )
            } catch {
                throw ImportError.network
            }
            switch result.response.statusCode {
            case 200..<300: break
            case 404: throw ImportError.userNotFound
            case 403, 429: throw ImportError.rateLimited
            default: throw ImportError.network
            }
            guard let arr = try? JSONSerialization.jsonObject(with: result.data) as? [[String: Any]] else {
                throw ImportError.network
            }
            if arr.isEmpty { break }
            for repo in arr {
                guard let html = repo["html_url"] as? String,
                      let validated = StacklumeAutomationPolicy.openableStoredURL(html),
                      seen.insert(CanonicalURL.key(validated.absoluteString)).inserted else { continue }
                let full = (repo["full_name"] as? String)
                    ?? (repo["name"] as? String)
                    ?? validated.absoluteString
                var detail = (repo["description"] as? String) ?? ""
                if let lang = repo["language"] as? String, !lang.isEmpty {
                    detail = detail.isEmpty ? lang : "\(detail) · \(lang)"
                }
                out.append(BrowserBookmark(url: validated.absoluteString, title: full, folder: "GitHub Stars",
                                           detail: detail.isEmpty ? nil : detail))
            }
            if arr.count < 100 { break }   // última página
        }
        return out
    }
}
