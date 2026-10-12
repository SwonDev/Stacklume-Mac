import Foundation

/// Referencia verificable a un enlace obtenida por una herramienta del asistente.
/// Solo estas referencias —nunca una URL inventada dentro de la prosa del modelo—
/// pueden convertirse en tarjetas interactivas.
struct AssistantLinkReference: Codable, Equatable, Hashable, Sendable, Identifiable {
    enum Origin: String, Codable, Sendable {
        case library
        case web
    }

    let title: String
    let url: String
    let summary: String?
    let collection: String?
    let tags: [String]
    let origin: Origin

    var id: String { "\(origin.rawValue):\(url)" }
}

/// El texto recuperado nunca concede referencias ni permisos. Los productores
/// adjuntan las URL del registro estructurado que acaban de consultar.
struct AssistantToolResult: Sendable {
    let text: String
    let references: [AssistantLinkReference]
    let didReadWebSource: Bool
    let researchSources: [AssistantResearchSource]

    init(_ text: String, references: [AssistantLinkReference] = [], didReadWebSource: Bool = false,
         researchSources: [AssistantResearchSource] = []) {
        self.text = text
        self.references = AssistantResponsePresentation.sanitizedReferences(references)
        self.didReadWebSource = didReadWebSource && !self.references.isEmpty
        self.researchSources = Array(researchSources.prefix(AssistantResearchDossier.maximumSources))
    }
}

enum AssistantResponseBlockKind: String, Equatable, Sendable {
    case lead
    case heading
    case paragraph
    case bullets
    case numbered
    case quote
}

/// Bloque visual derivado de la respuesta. El parser admite un subconjunto seguro de
/// Markdown, sin enlaces ejecutables, HTML ni código interpretado.
struct AssistantResponseBlock: Equatable, Sendable {
    let kind: AssistantResponseBlockKind
    let text: String
    let items: [String]

    init(kind: AssistantResponseBlockKind, text: String = "", items: [String] = []) {
        self.kind = kind
        self.text = text
        self.items = items
    }
}

enum AssistantResponsePresentation {
    static let maximumReferences = 64
    static let maximumReferenceTitleCharacters = 240
    static let maximumReferenceSummaryCharacters = 700
    static let maximumReferenceTags = 8

    /// Convierte una respuesta en bloques legibles incluso si el modelo no respetó por
    /// completo el contrato de formato. No interpreta enlaces ni HTML.
    static func blocks(from rawText: String) -> [AssistantResponseBlock] {
        let text = sanitizedVisibleText(rawText)
        guard !text.isEmpty else { return [] }

        let lines = text.components(separatedBy: .newlines)
        var result: [AssistantResponseBlock] = []
        var paragraph: [String] = []
        var listItems: [String] = []
        var listKind: AssistantResponseBlockKind?

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll(keepingCapacity: true)
            guard !joined.isEmpty else { return }
            let kind: AssistantResponseBlockKind = result.isEmpty ? .lead : .paragraph
            result.append(.init(kind: kind, text: joined))
        }

        func flushList() {
            defer {
                listItems.removeAll(keepingCapacity: true)
                listKind = nil
            }
            guard let listKind, !listItems.isEmpty else { return }
            result.append(.init(kind: listKind, items: Array(listItems.prefix(24))))
        }

        for index in lines.indices {
            let rawLine = lines[index]
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                flushList()
                continue
            }

            if let heading = headingText(line) {
                flushParagraph()
                flushList()
                result.append(.init(kind: .heading, text: heading))
                continue
            }

            // Los modelos pequeños a veces compactan «Conclusión: … 1. … 2. …»
            // en una sola línea. Recupera la jerarquía visual sin alterar su significado.
            if let section = labeledSection(line) {
                flushParagraph()
                flushList()
                result.append(.init(kind: .heading, text: section.label))
                if let numbered = inlineNumberedContent(section.remainder) {
                    if let introduction = numbered.introduction, !introduction.isEmpty {
                        result.append(.init(kind: .paragraph, text: introduction))
                    }
                    result.append(.init(kind: .numbered, items: numbered.items))
                } else if !section.remainder.isEmpty {
                    result.append(.init(kind: .paragraph, text: section.remainder))
                }
                continue
            }

            if let item = bulletText(line) {
                flushParagraph()
                if listKind != nil, listKind != .bullets { flushList() }
                listKind = .bullets
                listItems.append(item)
                continue
            }

            if let item = numberedText(line) {
                flushParagraph()
                if listKind != nil, listKind != .numbered { flushList() }
                listKind = .numbered
                listItems.append(item)
                continue
            }

            if line.hasPrefix(">") {
                flushParagraph()
                flushList()
                let quote = cleanInline(String(line.dropFirst()))
                if !quote.isEmpty { result.append(.init(kind: .quote, text: quote)) }
                continue
            }

            // «Hallazgos:» seguido por una lista se entiende como encabezado aunque el
            // modelo haya omitido ##. Mejora la jerarquía sin reescribir el contenido.
            if line.hasSuffix(":"), line.count <= 72,
               index + 1 < lines.count,
               bulletText(lines[index + 1].trimmingCharacters(in: .whitespaces)) != nil {
                flushParagraph()
                flushList()
                result.append(.init(kind: .heading, text: cleanInline(String(line.dropLast()))))
                continue
            }

            flushList()
            paragraph.append(cleanInline(line))
        }

        flushParagraph()
        flushList()
        return result
    }

    /// Extrae enlaces únicamente del resultado exacto devuelto por una herramienta.
    static func references(toolName: String, output: String) -> [AssistantLinkReference] {
        let name = toolName.lowercased()
        let candidates = name == "buscar_web" || name == "leer_web"
            ? webReferences(output)
            : libraryReferences(output)
        return sanitizedReferences(candidates)
    }

    static func sanitizedReferences(_ references: [AssistantLinkReference]) -> [AssistantLinkReference] {
        var indicesByURL: [String: Int] = [:]
        var result: [AssistantLinkReference] = []
        for reference in references {
            guard let safeURL = safeHTTPURL(reference.url) else { continue }
            let key = safeURL.lowercased()
            let title = bounded(cleanInline(reference.title), maximumReferenceTitleCharacters)
            guard !title.isEmpty else { continue }
            let summary = reference.summary
                .map { bounded(sanitizedVisibleText($0), maximumReferenceSummaryCharacters) }
                .flatMap { $0.isEmpty ? nil : $0 }
            let collection = reference.collection
                .map { bounded(cleanInline($0), 100) }
                .flatMap { $0.isEmpty ? nil : $0 }
            let tags = reference.tags
                .map { bounded(cleanInline($0), 60) }
                .filter { !$0.isEmpty }
                .prefix(maximumReferenceTags)
            let safeReference = AssistantLinkReference(
                title: title,
                url: safeURL,
                summary: summary,
                collection: collection,
                tags: Array(tags),
                origin: reference.origin
            )
            if let existingIndex = indicesByURL[key] {
                let existing = result[existingIndex]
                // `leer_web` llega después de `buscar_web`: conserva la misma tarjeta,
                // pero mejora su vista rápida con la evidencia más completa.
                if (safeReference.summary?.count ?? 0) > (existing.summary?.count ?? 0) {
                    result[existingIndex] = .init(
                        title: existing.title,
                        url: existing.url,
                        summary: safeReference.summary,
                        collection: existing.collection ?? safeReference.collection,
                        tags: existing.tags.isEmpty ? safeReference.tags : existing.tags,
                        origin: existing.origin
                    )
                }
                continue
            }
            indicesByURL[key] = result.count
            result.append(safeReference)
            if result.count >= maximumReferences { break }
        }
        return result
    }

    private static func webReferences(_ output: String) -> [AssistantLinkReference] {
        let lines = output.components(separatedBy: .newlines)
        var references: [AssistantLinkReference] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("• ") else { index += 1; continue }
            let title = String(line.dropFirst(2))
            guard index + 1 < lines.count else { break }
            let url = lines[index + 1].trimmingCharacters(in: .whitespaces)
            var summaryLines: [String] = []
            var cursor = index + 2
            while cursor < lines.count {
                let next = lines[cursor].trimmingCharacters(in: .whitespaces)
                if next.hasPrefix("• ") { break }
                if !next.isEmpty { summaryLines.append(next) }
                cursor += 1
            }
            references.append(.init(
                title: title,
                url: url,
                summary: summaryLines.isEmpty ? nil : summaryLines.joined(separator: " "),
                collection: nil,
                tags: [],
                origin: .web
            ))
            index = max(cursor, index + 1)
        }
        return references
    }

    private static func libraryReferences(_ output: String) -> [AssistantLinkReference] {
        let lines = output.components(separatedBy: .newlines)
        var references: [AssistantLinkReference] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- "),
                  let urlMarker = trimmed.range(of: " | http") else {
                // Las búsquedas semánticas colocan el resumen en la línea siguiente.
                if line.hasPrefix("  "), !trimmed.hasPrefix("http"),
                   let last = references.indices.last {
                    let hasLabel = trimmed.hasPrefix("resumen:") || trimmed.hasPrefix("summary:")
                    let summary = hasLabel
                        ? trimmed.split(separator: ":", maxSplits: 1)
                            .dropFirst().first.map(String.init)?.trimmingCharacters(in: .whitespaces)
                        : trimmed
                    if let summary, !summary.isEmpty {
                        let old = references[last]
                        references[last] = .init(
                            title: old.title, url: old.url, summary: summary,
                            collection: old.collection, tags: old.tags, origin: old.origin
                        )
                    }
                }
                continue
            }

            let titleStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
            let title = String(trimmed[titleStart..<urlMarker.lowerBound])
            let urlStart = trimmed.index(urlMarker.lowerBound, offsetBy: 3)
            let remainder = String(trimmed[urlStart...])
            let fields = remainder.components(separatedBy: " | ")
            guard let url = fields.first else { continue }
            var collection: String?
            var tags: [String] = []
            for field in fields.dropFirst() {
                let lower = field.lowercased()
                if lower.hasPrefix("cat:") || lower.hasPrefix("colección:") || lower.hasPrefix("collection:") {
                    collection = field.split(separator: ":", maxSplits: 1)
                        .dropFirst().first.map(String.init)?.trimmingCharacters(in: .whitespaces)
                } else if lower.hasPrefix("tags:") || lower.hasPrefix("etiquetas:") {
                    let values = field.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                    tags = values.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                }
            }
            references.append(.init(
                title: title,
                url: url,
                summary: nil,
                collection: collection,
                tags: tags,
                origin: .library
            ))
        }
        return references
    }

    private static func headingText(_ line: String) -> String? {
        guard line.hasPrefix("#") else { return nil }
        let value = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        let cleaned = cleanInline(value)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func bulletText(_ line: String) -> String? {
        guard let prefix = listPrefix(in: line), !prefix.numbered else { return nil }
        let marker = prefix.completed ? "Completado: " : ""
        let value = cleanInline(String(line.dropFirst(prefix.count)))
        return value.isEmpty ? nil : marker + value
    }

    private static func numberedText(_ line: String) -> String? {
        guard let prefix = listPrefix(in: line), prefix.numbered else { return nil }
        let value = cleanInline(String(line.dropFirst(prefix.count)))
        return value.isEmpty ? nil : value
    }

    /// Comparte la gramática de listas sin limpiar ni reescribir el contenido de la propuesta.
    static func listItemContent(_ text: String) -> String? {
        let line = text.trimmingCharacters(in: .whitespaces)
        guard let prefix = listPrefix(in: line) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    private static func listPrefix(in line: String) -> (count: Int, numbered: Bool, completed: Bool)? {
        let prefixes = ["- [ ] ", "- [x] ", "- [X] ", "- ", "• ", "* "]
        if let prefix = prefixes.first(where: { line.hasPrefix($0) }) {
            return (prefix.count, false, prefix.lowercased() == "- [x] ")
        }
        guard let range = line.range(of: #"^\d{1,2}[\.)]\s+"#, options: .regularExpression) else { return nil }
        return (line.distance(from: line.startIndex, to: range.upperBound), true, false)
    }

    private static func labeledSection(_ line: String) -> (label: String, remainder: String)? {
        let knownLabels = [
            "conclusión", "resumen", "hallazgos", "diferencias", "comparativa",
            "recomendación", "siguiente paso", "qué encontré",
            "conclusion", "summary", "findings", "differences", "comparison",
            "recommendation", "next step", "what i found"
        ]
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let rawLabel = cleanInline(String(line[..<colon]))
        guard knownLabels.contains(rawLabel.lowercased()) else { return nil }
        let remainderStart = line.index(after: colon)
        let remainder = cleanInline(String(line[remainderStart...]))
        return (rawLabel, remainder)
    }

    private static func inlineNumberedContent(
        _ text: String
    ) -> (introduction: String?, items: [String])? {
        guard let expression = try? NSRegularExpression(pattern: #"(?<!\w)\d{1,2}[\.)]\s+"#) else {
            return nil
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: fullRange)
        guard matches.count >= 2 else { return nil }

        let introduction: String? = Range(matches[0].range, in: text).map { marker in
            cleanInline(String(text[..<marker.lowerBound]))
                .trimmingCharacters(in: CharacterSet(charactersIn: " :–—-"))
        }
        var items: [String] = []
        for index in matches.indices {
            guard let marker = Range(matches[index].range, in: text) else { continue }
            let upperBound: String.Index
            if index + 1 < matches.count,
               let next = Range(matches[index + 1].range, in: text) {
                upperBound = next.lowerBound
            } else {
                upperBound = text.endIndex
            }
            let item = cleanInline(String(text[marker.upperBound..<upperBound]))
                .trimmingCharacters(in: CharacterSet(charactersIn: " :–—-"))
            if !item.isEmpty { items.append(item) }
        }
        guard items.count >= 2 else { return nil }
        return (introduction.flatMap { $0.isEmpty ? nil : $0 }, Array(items.prefix(24)))
    }

    private static func sanitizedVisibleText(_ text: String) -> String {
        let hiddenDirectionScalars: Set<UInt32> = [
            0x061C, 0x200E, 0x200F,
            0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
            0x2066, 0x2067, 0x2068, 0x2069
        ]
        let sanitized = text.unicodeScalars.filter { scalar in
            guard !hiddenDirectionScalars.contains(scalar.value) else { return false }
            return !CharacterSet.controlCharacters.contains(scalar) || scalar == "\n" || scalar == "\t"
        }
        return String(String.UnicodeScalarView(sanitized))
            .replacingOccurrences(of: #"<[^>]{0,200}>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanInline(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func safeHTTPURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 4_096,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else { return nil }
        return components.url?.absoluteString
    }

    private static func bounded(_ value: String, _ maximum: Int) -> String {
        String(value.prefix(maximum))
    }
}
