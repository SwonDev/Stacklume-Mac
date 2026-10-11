import Foundation
import SQLite3

// MARK: - Navegadores soportados

/// Navegador del que Stacklume puede importar marcadores LEYENDO DIRECTAMENTE su
/// almacén local — sin que el usuario tenga que exportar nada a mano (a diferencia de
/// Raindrop/Pocket). Los basados en Chromium comparten el mismo `Bookmarks` (JSON);
/// Safari usa un plist binario (requiere Acceso a Disco Completo).
enum ImportableBrowser: String, CaseIterable, Identifiable {
    case brave, chrome, edge, vivaldi, opera, firefox, arc, safari

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .brave: "Brave"
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        case .vivaldi: "Vivaldi"
        case .opera: "Opera"
        case .firefox: "Firefox"
        case .arc: "Arc"
        case .safari: "Safari"
        }
    }

    /// SF Symbol de respaldo para la fila (Safari tiene símbolo propio).
    var icon: String { self == .safari ? "safari.fill" : "globe" }

    /// `true` si usa el formato `Bookmarks` JSON de Chromium.
    var isChromium: Bool { self != .safari && self != .firefox && self != .arc }

    /// Rutas candidatas del archivo de marcadores (varios perfiles para Chromium).
    var bookmarkURLs: [URL] {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        let profiles = ["Default", "Profile 1", "Profile 2", "Profile 3"]
        func chromium(_ relative: String) -> [URL] {
            profiles.map { appSupport.appendingPathComponent("\(relative)/\($0)/Bookmarks") }
        }
        switch self {
        case .brave: return chromium("BraveSoftware/Brave-Browser")
        case .chrome: return chromium("Google/Chrome")
        case .edge: return chromium("Microsoft Edge")
        case .vivaldi: return chromium("Vivaldi")
        case .opera: return [appSupport.appendingPathComponent("com.operasoftware.Opera/Bookmarks")]
        case .firefox:
            // El perfil de Firefox tiene un nombre aleatorio: hay que enumerar Profiles/*.
            let profiles = appSupport.appendingPathComponent("Firefox/Profiles")
            let dirs = (try? FileManager.default.contentsOfDirectory(
                at: profiles, includingPropertiesForKeys: nil)) ?? []
            return dirs.map { $0.appendingPathComponent("places.sqlite") }
        case .arc: return [appSupport.appendingPathComponent("Arc/StorableSidebar.json")]
        case .safari: return [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari/Bookmarks.plist")]
        }
    }
}

// MARK: - Resultados

/// Un navegador detectado con marcadores legibles (uno o varios perfiles).
struct DetectedBrowser: Identifiable {
    let browser: ImportableBrowser
    let fileURLs: [URL]
    let count: Int
    var id: String { browser.rawValue }
    var displayName: String { browser.displayName }
}

/// Un marcador leído de un navegador o de un origen externo. `folder` es el nombre de
/// la carpeta que lo contiene (se convertirá en colección); vacío para los de la barra
/// de marcadores. `detail` es una descripción opcional que algunos orígenes (p. ej.
/// GitHub Stars) ya traen y que se usa como semilla antes del autoenriquecido con IA.
struct BrowserBookmark: Hashable {
    let url: String
    let title: String
    let folder: String
    var detail: String? = nil
}

// MARK: - Importador

/// Detecta y parsea los marcadores de los navegadores instalados. Todo en local,
/// solo lectura. Es síncrono y rápido (los archivos de marcadores pesan pocos KB).
enum BrowserImporter {

    /// Navegadores instalados con marcadores legibles, con su recuento. Safari solo
    /// aparece si la app tiene Acceso a Disco Completo (si no, su archivo no es legible).
    static func detect() -> [DetectedBrowser] {
        var detected: [DetectedBrowser] = []
        for browser in ImportableBrowser.allCases {
            var readable: [URL] = []
            var total = 0
            for url in browser.bookmarkURLs
            where FileManager.default.isReadableFile(atPath: url.path) {
                let count = parse(browser: browser, fileURL: url).count
                if count > 0 { readable.append(url); total += count }
            }
            if total > 0 {
                detected.append(DetectedBrowser(browser: browser, fileURLs: readable, count: total))
            }
        }
        return detected
    }

    /// Todos los marcadores de un navegador detectado (uniendo perfiles).
    static func parse(_ detected: DetectedBrowser) -> [BrowserBookmark] {
        (try? parseChecked(detected)) ?? []
    }

    static func parseChecked(_ detected: DetectedBrowser) throws -> [BrowserBookmark] {
        var bookmarks: [BrowserBookmark] = []
        for url in detected.fileURLs {
            let parsed = try parseChecked(browser: detected.browser, fileURL: url)
            guard parsed.count <= ImportSafety.maximumRecords - bookmarks.count else {
                throw ImportSafetyError.limitExceeded
            }
            bookmarks.append(contentsOf: parsed)
        }
        return bookmarks
    }

    private static func parse(browser: ImportableBrowser, fileURL: URL) -> [BrowserBookmark] {
        (try? parseChecked(browser: browser, fileURL: fileURL)) ?? []
    }

    private static func parseChecked(browser: ImportableBrowser, fileURL: URL) throws -> [BrowserBookmark] {
        let parsed: [BrowserBookmark]
        switch browser {
        case .safari: parsed = try parseSafari(fileURL)
        case .firefox: parsed = try parseFirefox(fileURL)
        case .arc: parsed = try parseArc(fileURL)
        default: parsed = try parseChromium(fileURL)
        }
        try ImportSafety.validateBookmarks(parsed)
        return parsed
    }

    // MARK: Chromium (Chrome/Brave/Edge/Vivaldi/Opera)

    private static func parseChromium(_ url: URL) throws -> [BrowserBookmark] {
        let data = try BoundedFileReader.read(url, maximumBytes: ImportSafety.maximumTextBytes)
        guard let json = try ImportSafety.jsonObject(data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { throw ImportSafetyError.invalidStructure }
        var out: [BrowserBookmark] = []
        for key in ["bookmark_bar", "other", "synced"] {
            if let node = roots[key] as? [String: Any] {
                // Los hijos directos de una raíz (barra de marcadores) van sin colección.
                walkChromium(node, folder: "", into: &out)
            }
        }
        return out
    }

    /// Recorre un nodo: cada URL hija se asigna a `folder`; cada subcarpeta recurre con
    /// su propio nombre como colección.
    private static func walkChromium(_ node: [String: Any], folder: String,
                                     into out: inout [BrowserBookmark]) {
        guard let children = node["children"] as? [[String: Any]] else { return }
        for child in children {
            switch child["type"] as? String {
            case "url":
                if let link = child["url"] as? String,
                   let validated = StacklumeAutomationPolicy.openableStoredURL(link) {
                    out.append(BrowserBookmark(url: validated.absoluteString,
                                               title: (child["name"] as? String) ?? "",
                                               folder: folder))
                }
            case "folder":
                walkChromium(child, folder: (child["name"] as? String) ?? folder, into: &out)
            default:
                break
            }
        }
    }

    // MARK: Safari (plist binario, requiere Acceso a Disco Completo)

    private static func parseSafari(_ url: URL) throws -> [BrowserBookmark] {
        let data = try BoundedFileReader.read(url, maximumBytes: ImportSafety.maximumTextBytes)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        try ImportSafety.validateObject(plist)
        guard let root = plist as? [String: Any] else { throw ImportSafetyError.invalidStructure }
        var out: [BrowserBookmark] = []
        walkSafari(root, folder: "", into: &out)
        return out
    }

    private static func walkSafari(_ node: [String: Any], folder: String,
                                   into out: inout [BrowserBookmark]) {
        switch node["WebBookmarkType"] as? String {
        case "WebBookmarkTypeLeaf":
            if let link = node["URLString"] as? String,
               let validated = StacklumeAutomationPolicy.openableStoredURL(link) {
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
                out.append(BrowserBookmark(url: validated.absoluteString, title: title, folder: folder))
            }
        default:
            guard let children = node["Children"] as? [[String: Any]] else { return }
            for child in children {
                // Una lista (carpeta) propaga su título como colección; «com.apple.…»
                // (Reading List, BookmarksBar) se ignoran como nombre de colección.
                if (child["WebBookmarkType"] as? String) == "WebBookmarkTypeList" {
                    let title = (child["Title"] as? String) ?? folder
                    let clean = title.hasPrefix("com.apple.") ? "" : title
                    walkSafari(child, folder: clean, into: &out)
                } else {
                    walkSafari(child, folder: folder, into: &out)
                }
            }
        }
    }

    // MARK: Firefox (places.sqlite — base SQLite)

    private static func parseFirefox(_ url: URL) throws -> [BrowserBookmark] {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size <= ImportSafety.maximumArchiveBytes else { throw ImportSafetyError.limitExceeded }
        var db: OpaquePointer?
        // `immutable=1`: permite leer aunque Firefox esté abierto (ignora el bloqueo WAL).
        let uri = "file:\(url.path)?immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(ImportSafety.maximumFieldBytes))
        // type=1 → marcador; f.title → nombre de la carpeta que lo contiene (las carpetas
        // raíz internas de Firefox tienen título NULL → colección vacía).
        let sql = """
        SELECT p.url, b.title, f.title
        FROM moz_bookmarks b
        JOIN moz_places p ON b.fk = p.id
        LEFT JOIN moz_bookmarks f ON b.parent = f.id
        WHERE b.type = 1 AND p.url LIKE 'http%'
        LIMIT 100001
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [BrowserBookmark] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            guard out.count < ImportSafety.maximumRecords,
                  (0...2).allSatisfy({ sqlite3_column_bytes(stmt, Int32($0)) <= ImportSafety.maximumShortFieldBytes }) else {
                throw ImportSafetyError.limitExceeded
            }
            defer { status = sqlite3_step(stmt) }
            guard let urlC = sqlite3_column_text(stmt, 0) else { continue }
            let link = String(cString: urlC)
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let folder = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            out.append(BrowserBookmark(url: link, title: title, folder: folder))
        }
        guard status == SQLITE_DONE else { throw ImportSafetyError.invalidStructure }
        return out
    }

    // MARK: Arc (StorableSidebar.json — formato propio)

    /// El JSON de Arc es complejo y no documentado, así que el parseo es DEFENSIVO:
    /// recorre toda la estructura buscando pestañas guardadas (`tab.savedURL` http) con su
    /// título, dedup dentro del propio archivo. No reconstruye la jerarquía de carpetas
    /// (sin colección). Si el formato no encaja, devuelve vacío (no rompe nada).
    private static func parseArc(_ url: URL) throws -> [BrowserBookmark] {
        let data = try BoundedFileReader.read(url, maximumBytes: ImportSafety.maximumTextBytes)
        let root = try ImportSafety.jsonObject(data)
        var out: [BrowserBookmark] = []
        var seen = Set<String>()
        scanArc(root, into: &out, seen: &seen)
        return out
    }

    private static func scanArc(_ node: Any, into out: inout [BrowserBookmark],
                                seen: inout Set<String>) {
        if let dict = node as? [String: Any] {
            if let tab = dict["tab"] as? [String: Any],
               let link = tab["savedURL"] as? String,
               let validated = StacklumeAutomationPolicy.openableStoredURL(link),
               seen.insert(validated.absoluteString).inserted {
                let title = (tab["savedTitle"] as? String) ?? (dict["title"] as? String) ?? ""
                out.append(BrowserBookmark(url: validated.absoluteString, title: title, folder: ""))
            }
            for value in dict.values { scanArc(value, into: &out, seen: &seen) }
        } else if let arr = node as? [Any] {
            for value in arr { scanArc(value, into: &out, seen: &seen) }
        }
    }
}
