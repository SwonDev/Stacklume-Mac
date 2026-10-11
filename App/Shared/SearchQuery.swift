import Foundation
import StacklumeCore

/// Parser de la barra de búsqueda con operadores estilo Raindrop. Separa el TEXTO
/// LIBRE (que sigue alimentando la búsqueda full-text/semántica del almacén) de los
/// OPERADORES estructurales, que se aplican como post-filtro en la capa de app sin
/// tocar `StacklumePersistence` (read-only).
///
/// Operadores soportados (AND implícito; exclusión anteponiendo `-`):
/// - `title:` (`titulo:`/`título:`) — el título contiene el valor
/// - `tag:` (`etiqueta:`) o `#valor` — alguna etiqueta contiene el valor
/// - `type:` (`tipo:`) — el tipo de contenido coincide (acepta rawValue inglés o
///   nombre en español: `type:video`, `tipo:artículo`)
/// - `domain:` (`site:`/`dominio:`/`host:`) — el dominio contiene el valor
/// - `url:` (`enlace:`) — la URL contiene el valor
/// - `created:` (`creado:`/`fecha:`) — por PREFIJO (`created:2026`, `created:2026-06`,
///   `created:2026-06-19`) o por RANGO (`created:2026-01..2026-06`, `created:..2026-06`,
///   `created:2026-01..`)
///
/// Una palabra suelta es texto libre; con `-` delante excluye los enlaces cuyo texto
/// la contenga.
struct SearchQuery {
    /// Texto libre (sin operadores) para la búsqueda full-text / semántica.
    let freeText: String
    /// Predicados de operador (AND), cada uno ya con su negación incorporada.
    private let predicates: [(Bookmark) -> Bool]

    init(freeText: String, predicates: [(Bookmark) -> Bool]) {
        self.freeText = freeText
        self.predicates = predicates
    }

    /// `true` si hay al menos un operador (para saber si merece post-filtrar).
    var hasOperators: Bool { !predicates.isEmpty }

    /// `true` si el enlace satisface TODOS los operadores (AND).
    func matches(_ link: Bookmark) -> Bool {
        for predicate in predicates where !predicate(link) { return false }
        return true
    }

    /// Coincidencia LÉXICA completa para la búsqueda de la biblioteca: cumple TODOS los
    /// operadores Y cada palabra libre POSITIVA aparece en el texto buscable del enlace
    /// (título, URL, descripción, resumen, notas, COLECCIÓN y ETIQUETAS). Es la búsqueda
    /// «inteligente» que SÍ mira etiquetas y contexto: «3D assets» encuentra un enlace cuya
    /// única coincidencia es la etiqueta «3d assets». También consulta `offlineText`, donde
    /// viven las copias web y el texto extraído por OCR de PDFs/imágenes. Insensible a tildes
    /// y mayúsculas; AND entre términos (todas las palabras deben aparecer, en cualquier campo).
    func lexicalMatches(_ link: Bookmark) -> Bool {
        for predicate in predicates where !predicate(link) { return false }
        let terms = freeText.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map { Self.fold(String($0)) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return true }
        // Camino rápido: la inmensa mayoría coincide por metadatos. Solo materializa el
        // contenido externo `offlineText` si alguna palabra no está ya en ellos.
        let metadata = Self.fold(Self.metadataText(link))
        if terms.allSatisfy({ metadata.contains($0) }) { return true }
        guard let offline = link.offlineText, !offline.isEmpty else { return false }
        let fullText = metadata + " " + Self.fold(offline)
        return terms.allSatisfy { fullText.contains($0) }
    }

    /// Fallback del asistente: conserva el scope del parser y ordena coincidencias
    /// léxicas acotadas antes del merge existente. La búsqueda AND de la UI no cambia.
    func researchRankedMatches(_ links: [Bookmark], limit: Int = 200) throws -> [Bookmark] {
        let topic = AssistantResearchPlan.lexicalTopic(for: freeText)
        guard !topic.isEmpty else { return [] }
        var exact: [Bookmark] = []
        var partial: [(link: Bookmark, score: Int)] = []
        var used: Set<UUID> = []
        for (index, link) in links.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            guard link.deletedAt == nil, matches(link), used.insert(link.id).inserted else { continue }
            let metadata = Self.fold(Self.metadataText(link))
            var score = topic.score(in: metadata)
            if score != topic.terms.count {
                try Task.checkCancellation()
                if let offline = link.offlineText, !offline.isEmpty {
                    score = topic.score(in: metadata + " " + Self.fold(offline))
                }
            }
            guard let score else { continue }
            if lexicalMatches(link) { exact.append(link) }
            else { partial.append((link, score)) }
        }
        try Task.checkCancellation()
        let candidates: [Bookmark]
        if !exact.isEmpty { candidates = exact.sorted { $0.id.uuidString < $1.id.uuidString } }
        else {
            candidates = partial.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.link.id.uuidString < $1.link.id.uuidString
            }.map(\.link)
        }
        let allowed = Set(candidates.map(\.id))
        let ids = MultimodalSearchRanking.merge(literal: candidates.map(\.id), semantic: [],
                                                allowed: allowed, limit: min(max(limit, 0), 200))
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    // MARK: - Parseo

    static func parse(_ raw: String) -> SearchQuery {
        let tokens = raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        var freeWords: [String] = []
        var preds: [(Bookmark) -> Bool] = []

        for token in tokens {
            var t = token
            var negated = false
            if t.hasPrefix("-"), t.count > 1 { negated = true; t.removeFirst() }

            // #etiqueta
            if t.hasPrefix("#"), t.count > 1 {
                let value = fold(String(t.dropFirst()))
                preds.append(wrap(negated) { link in link.tags.contains { fold($0.name).contains(value) } })
                continue
            }

            // clave:valor
            if let colon = t.firstIndex(of: ":") {
                let key = String(t[t.startIndex..<colon]).lowercased()
                let value = String(t[t.index(after: colon)...])
                if !value.isEmpty, let pred = operatorPredicate(key: key, value: value, negated: negated) {
                    preds.append(pred)
                    continue
                }
                // clave desconocida o valor vacío → cae a texto libre
            }

            // Texto libre: positivo → full-text; negativo → exclusión.
            if negated {
                let value = fold(t)
                preds.append { link in !fold(searchableText(link)).contains(value) }
            } else {
                freeWords.append(t)
            }
        }

        return SearchQuery(freeText: freeWords.joined(separator: " "), predicates: preds)
    }

    // MARK: - Operadores

    private static func operatorPredicate(key: String, value: String,
                                          negated: Bool) -> ((Bookmark) -> Bool)? {
        let v = fold(value)
        switch key {
        case "title", "name", "titulo", "título":
            return wrap(negated) { fold($0.title).contains(v) }
        case "tag", "etiqueta", "etiquetas":
            return wrap(negated) { link in link.tags.contains { fold($0.name).contains(v) } }
        case "domain", "site", "dominio", "host":
            return wrap(negated) { fold(host(of: $0.url)).contains(v) }
        case "url", "link", "enlace":
            return wrap(negated) { fold($0.url).contains(v) }
        case "type", "tipo", "kind":
            let types = resolveTypes(value)
            guard !types.isEmpty else { return wrap(negated) { _ in false } }
            return wrap(negated) { types.contains($0.contentType) }
        case "created", "creado", "fecha", "date":
            return wrap(negated, dateMatcher(value))
        default:
            return nil
        }
    }

    /// Resuelve un valor de `type:` al conjunto de `ContentType` que coinciden por
    /// rawValue inglés o por nombre en español (insensible a tildes y mayúsculas).
    private static func resolveTypes(_ value: String) -> Set<ContentType> {
        let v = fold(value)
        return Set(ContentType.allCases.filter {
            fold($0.rawValue).contains(v) || fold($0.displayName).contains(v)
        })
    }

    // MARK: - Utilidades

    /// Envuelve un predicado base aplicando la negación si procede.
    private static func wrap(_ negated: Bool,
                             _ base: @escaping (Bookmark) -> Bool) -> (Bookmark) -> Bool {
        negated ? { !base($0) } : base
    }

    /// Normaliza para comparar: sin tildes y sin distinción de mayúsculas.
    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
    }

    /// Texto agregado del enlace para la búsqueda léxica y la exclusión por palabra libre
    /// (`-palabra`). Reúne TODO lo relevante para que la búsqueda sea inteligente: título,
    /// URL, descripción, resumen de IA, notas, nombre del sitio, COLECCIÓN, ETIQUETAS y
    /// contenido offline/OCR. Se usa para exclusiones (`-palabra`), que deben comprobar
    /// todo el documento y no solo sus metadatos.
    private static func searchableText(_ link: Bookmark) -> String {
        var text = metadataText(link)
        if let offline = link.offlineText, !offline.isEmpty { text += " " + offline }
        return text
    }

    /// Metadatos baratos: evita tocar `offlineText` (external storage) durante el camino
    /// normal de una búsqueda que ya coincide por título, etiquetas o descripción.
    private static func metadataText(_ link: Bookmark) -> String {
        var parts = [link.title, link.url]
        if let d = link.details { parts.append(d) }
        if let s = link.summary { parts.append(s) }
        if let n = link.notes { parts.append(n) }
        if let site = link.siteName { parts.append(site) }
        if let cat = link.category?.name { parts.append(cat) }
        parts.append(contentsOf: link.tags.map(\.name))
        return parts.joined(separator: " ")
    }

    /// Sello `YYYY-MM-DD` de una fecha para el prefijo de `created:`.
    private static func dateStamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Matcher de `created:`: admite PREFIJO (`2026`, `2026-06`, `2026-06-19`) y RANGO
    /// (`2026-01..2026-06`, `..2026-06`, `2026-01..`). El rango compara el sello
    /// `YYYY-MM-DD` lexicográficamente (ordena fechas correctamente al estar relleno con
    /// ceros), completando los valores parciales al inicio/fin de su periodo.
    private static func dateMatcher(_ value: String) -> (Bookmark) -> Bool {
        let v = value.lowercased()
        if let r = v.range(of: "..") {
            let lo = String(v[v.startIndex..<r.lowerBound])
            let hi = String(v[r.upperBound...])
            let loStamp = lo.isEmpty ? "" : expandDate(lo, high: false)
            let hiStamp = hi.isEmpty ? "9999-99-99" : expandDate(hi, high: true)
            return { link in
                let s = dateStamp(link.createdAt)
                return (loStamp.isEmpty || s >= loStamp) && s <= hiStamp
            }
        }
        return { dateStamp($0.createdAt).hasPrefix(v) }
    }

    /// Completa un valor parcial (`2026`, `2026-06`) al sello del INICIO (`high == false`)
    /// o el FIN (`high == true`) de su periodo, para los extremos de un rango.
    private static func expandDate(_ partial: String, high: Bool) -> String {
        let parts = partial.split(separator: "-").map(String.init)
        let year = parts.count > 0 ? pad(parts[0], 4, high ? "9" : "0") : (high ? "9999" : "0000")
        let month = parts.count > 1 ? pad(parts[1], 2, "0") : (high ? "12" : "01")
        let day = parts.count > 2 ? pad(parts[2], 2, "0") : (high ? "31" : "01")
        return "\(year)-\(month)-\(day)"
    }

    private static func pad(_ s: String, _ n: Int, _ fill: String) -> String {
        s.count >= n ? String(s.prefix(n)) : String(repeating: fill, count: n - s.count) + s
    }

    /// Dominio del enlace sin `www.` (autónomo: sin depender de helpers de la app, para
    /// que este parser sea testable en el bundle de lógica).
    private static func host(of urlString: String) -> String {
        guard let host = URL(string: urlString)?.host() else { return urlString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
