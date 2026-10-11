import Foundation
import ZIPFoundation

struct EPUBChapter: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let text: String
}

struct EPUBBookMetadata: Sendable, Equatable {
    let title: String?
    let author: String?
}

struct EPUBPublication: Sendable, Equatable {
    let title: String?
    let author: String?
    let chapters: [EPUBChapter]
    let coverData: Data?
    let sourceChapterCount: Int
    let processedChapterCount: Int
    let wasTruncated: Bool
}

enum EPUBDocumentError: LocalizedError, Sendable, Equatable {
    case invalidArchive
    case invalidPackage
    case unsafeArchive
    case archiveTooLarge
    case unsupportedProtection
    case noReadableChapters

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            "El EPUB está dañado o no es un contenedor válido."
        case .invalidPackage:
            "El EPUB no contiene una estructura de libro válida."
        case .unsafeArchive:
            "El EPUB contiene rutas o entradas que no se pueden procesar con seguridad."
        case .archiveTooLarge:
            "El EPUB se expande por encima del límite seguro."
        case .unsupportedProtection:
            "El EPUB está cifrado o protegido y no se puede leer localmente."
        case .noReadableChapters:
            "El EPUB no contiene capítulos de texto legibles."
        }
    }
}

/// Lector EPUB totalmente local y acotado.
///
/// El original nunca se descomprime al sistema de archivos ni se representa en un `WKWebView`.
/// Solo se extraen en memoria las entradas declaradas por el paquete OPF y se convierten a
/// texto. Antes de extraer se comprueban rutas, symlinks, duplicados, tamaños y ratios de
/// compresión para frenar traversal y bombas ZIP.
enum EPUBDocumentReader {
    static let maximumEntryCount = 2_000
    static let maximumExpandedBytes: UInt64 = 256 * 1_024 * 1_024
    static let maximumEntryBytes: UInt64 = 32 * 1_024 * 1_024
    static let maximumChapterBytes: UInt64 = 8 * 1_024 * 1_024
    static let maximumChapterCount = 500
    static let maximumReaderCharacters = 4_000_000
    private static let maximumChapterCharacters = 300_000
    private static let maximumMetadataBytes: UInt64 = 2 * 1_024 * 1_024
    private static let maximumCoverBytes: UInt64 = 16 * 1_024 * 1_024
    private static let maximumCompressionRatio: UInt64 = 1_000

    static func validate(data: Data) throws {
        _ = try context(from: data)
    }

    static func metadata(data: Data) throws -> EPUBBookMetadata {
        let context = try context(from: data)
        return .init(title: context.package.title, author: context.package.author)
    }

    static func extract(data: Data) throws -> EPUBPublication {
        let context = try context(from: data)
        var chapters: [EPUBChapter] = []
        chapters.reserveCapacity(min(context.package.spine.count, 80))
        var characterCount = 0
        var processedCount = 0
        var wasTruncated = context.package.spine.count > maximumChapterCount

        for (index, itemID) in context.package.spine.prefix(maximumChapterCount).enumerated() {
            try Task.checkCancellation()
            guard let item = context.package.manifest[itemID], item.isReadableDocument else {
                continue
            }
            processedCount += 1
            guard let path = try? resolve(item.href, relativeTo: context.packagePath),
                  let entry = context.entries[path], entry.type == .file else {
                continue
            }
            guard entry.uncompressedSize <= maximumChapterBytes else {
                wasTruncated = true
                continue
            }

            let remaining = maximumReaderCharacters - characterCount
            guard remaining > 0 else {
                wasTruncated = true
                break
            }
            let data = try extract(entry, from: context.archive, maximumBytes: maximumChapterBytes)
            let parsed = EPUBChapterTextParser.parse(
                data: data,
                maximumCharacters: min(maximumChapterCharacters, remaining)
            )
            let sanitized = DocumentTextSanitizer.normalize(
                [parsed.text],
                maximumCharacters: min(maximumChapterCharacters, remaining)
            )
            guard !sanitized.text.isEmpty else { continue }

            let rawTitle = parsed.heading?.trimmingCharacters(in: .whitespacesAndNewlines)
            let chapterTitle = (rawTitle?.isEmpty == false ? rawTitle : nil) ?? "Capítulo \(index + 1)"
            chapters.append(.init(id: path, title: chapterTitle, text: sanitized.text))
            characterCount += sanitized.text.count
            wasTruncated = wasTruncated || parsed.wasTruncated || sanitized.wasTruncated
        }

        guard !chapters.isEmpty else { throw EPUBDocumentError.noReadableChapters }
        let coverData = try extractCover(from: context)
        return EPUBPublication(
            title: context.package.title,
            author: context.package.author,
            chapters: chapters,
            coverData: coverData,
            sourceChapterCount: context.package.spine.count,
            processedChapterCount: processedCount,
            wasTruncated: wasTruncated
        )
    }

    // MARK: - Contenedor

    private struct Context {
        let archive: Archive
        let entries: [String: Entry]
        let packagePath: String
        let package: Package
    }

    fileprivate struct ManifestItem: Sendable {
        let href: String
        let mediaType: String
        let properties: Set<String>

        var isReadableDocument: Bool {
            mediaType.caseInsensitiveCompare("application/xhtml+xml") == .orderedSame
                || mediaType.caseInsensitiveCompare("text/html") == .orderedSame
        }
    }

    fileprivate struct Package: Sendable {
        let title: String?
        let author: String?
        let manifest: [String: ManifestItem]
        let spine: [String]
        let legacyCoverID: String?
    }

    private static func context(from data: Data) throws -> Context {
        guard !data.isEmpty else { throw EPUBDocumentError.invalidArchive }
        let archive: Archive
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw EPUBDocumentError.invalidArchive
        }

        var entries: [String: Entry] = [:]
        var expandedBytes: UInt64 = 0
        var count = 0
        for entry in archive {
            count += 1
            guard count <= maximumEntryCount else { throw EPUBDocumentError.archiveTooLarge }
            guard entry.type != .symlink else { throw EPUBDocumentError.unsafeArchive }
            let path = try validatedEntryPath(entry.path)
            guard entries.updateValue(entry, forKey: path) == nil else {
                throw EPUBDocumentError.unsafeArchive
            }
            guard entry.uncompressedSize <= maximumEntryBytes,
                  entry.uncompressedSize <= maximumExpandedBytes - min(expandedBytes, maximumExpandedBytes)
            else { throw EPUBDocumentError.archiveTooLarge }
            expandedBytes += entry.uncompressedSize

            if entry.uncompressedSize > 1_024 * 1_024 {
                guard entry.compressedSize > 0,
                      entry.uncompressedSize / entry.compressedSize <= maximumCompressionRatio
                else { throw EPUBDocumentError.archiveTooLarge }
            }
        }
        guard !entries.isEmpty else { throw EPUBDocumentError.invalidArchive }

        guard let mimetypeEntry = entries["mimetype"], mimetypeEntry.type == .file else {
            throw EPUBDocumentError.invalidPackage
        }
        let mimetypeData = try extract(mimetypeEntry, from: archive, maximumBytes: 256)
        let mimetype = String(decoding: mimetypeData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard mimetype == "application/epub+zip" else { throw EPUBDocumentError.invalidPackage }

        guard let containerEntry = entries["META-INF/container.xml"], containerEntry.type == .file else {
            throw EPUBDocumentError.invalidPackage
        }
        let containerData = try extract(
            containerEntry,
            from: archive,
            maximumBytes: maximumMetadataBytes
        )
        guard !containsUnsafeXMLDeclaration(containerData),
              let packagePathRaw = EPUBContainerXMLParser.parse(containerData) else {
            throw EPUBDocumentError.invalidPackage
        }
        let packagePath = try validatedEntryPath(packagePathRaw)
        guard let packageEntry = entries[packagePath], packageEntry.type == .file else {
            throw EPUBDocumentError.invalidPackage
        }
        let packageData = try extract(packageEntry, from: archive, maximumBytes: maximumMetadataBytes)
        guard !containsUnsafeXMLDeclaration(packageData),
              let package = EPUBPackageXMLParser.parse(packageData),
              !package.manifest.isEmpty,
              package.spine.contains(where: { package.manifest[$0]?.isReadableDocument == true }) else {
            throw EPUBDocumentError.invalidPackage
        }

        // Si los capítulos del spine figuran como entradas cifradas ZIPFoundation no los
        // expone. Se informa como protección no compatible, sin intentar ningún bypass.
        let readablePaths = package.spine.compactMap { id -> String? in
            guard let item = package.manifest[id], item.isReadableDocument else { return nil }
            return try? resolve(item.href, relativeTo: packagePath)
        }
        guard readablePaths.contains(where: { entries[$0]?.type == .file }) else {
            throw EPUBDocumentError.unsupportedProtection
        }
        return Context(archive: archive, entries: entries, packagePath: packagePath, package: package)
    }

    private static func extractCover(from context: Context) throws -> Data? {
        let item: ManifestItem? = context.package.manifest.values.first {
            $0.properties.contains("cover-image") && $0.mediaType.lowercased().hasPrefix("image/")
        } ?? context.package.legacyCoverID.flatMap { context.package.manifest[$0] }
        guard let item,
              item.mediaType.lowercased().hasPrefix("image/"),
              let path = try? resolve(item.href, relativeTo: context.packagePath),
              let entry = context.entries[path], entry.type == .file,
              entry.uncompressedSize <= maximumCoverBytes else { return nil }
        return try extract(entry, from: context.archive, maximumBytes: maximumCoverBytes)
    }

    private static func extract(
        _ entry: Entry,
        from archive: Archive,
        maximumBytes: UInt64
    ) throws -> Data {
        guard entry.type == .file, entry.uncompressedSize <= maximumBytes else {
            throw EPUBDocumentError.archiveTooLarge
        }
        var result = Data()
        result.reserveCapacity(Int(min(entry.uncompressedSize, UInt64(Int.max))))
        do {
            _ = try archive.extract(entry, bufferSize: 64 * 1_024) { chunk in
                guard UInt64(result.count) <= maximumBytes - min(UInt64(chunk.count), maximumBytes),
                      UInt64(result.count + chunk.count) <= maximumBytes else {
                    throw EPUBDocumentError.archiveTooLarge
                }
                result.append(chunk)
            }
        } catch let error as EPUBDocumentError {
            throw error
        } catch {
            throw EPUBDocumentError.invalidArchive
        }
        return result
    }

    /// Valida los nombres tal como están almacenados en el ZIP. Como nunca se extraen al
    /// disco, esta comprobación es defensa en profundidad y también elimina ambigüedades.
    private static func validatedEntryPath(_ raw: String) throws -> String {
        guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.hasPrefix("~"),
              !raw.contains("\\"), !raw.unicodeScalars.contains(UnicodeScalar(0)) else {
            throw EPUBDocumentError.unsafeArchive
        }
        let trimmed = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw EPUBDocumentError.unsafeArchive
        }
        return components.joined(separator: "/")
    }

    private static func resolve(_ href: String, relativeTo packagePath: String) throws -> String {
        let resource = href.split(whereSeparator: { $0 == "#" || $0 == "?" }).first.map(String.init) ?? ""
        let decoded = resource.removingPercentEncoding ?? resource
        guard !decoded.isEmpty, !decoded.hasPrefix("/"), !decoded.contains("\\"),
              URLComponents(string: decoded)?.scheme == nil else {
            throw EPUBDocumentError.unsafeArchive
        }

        var components = packagePath.split(separator: "/").dropLast().map(String.init)
        for part in decoded.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            switch part {
            case "", ".":
                continue
            case "..":
                guard !components.isEmpty else { throw EPUBDocumentError.unsafeArchive }
                components.removeLast()
            default:
                components.append(part)
            }
        }
        return try validatedEntryPath(components.joined(separator: "/"))
    }

    private static func containsUnsafeXMLDeclaration(_ data: Data) -> Bool {
        let prefixData = Data(data.prefix(Int(maximumMetadataBytes)))
        let candidates: [String] = [
            String(decoding: prefixData, as: UTF8.self),
            String(data: prefixData, encoding: .utf16),
            String(data: prefixData, encoding: .utf16LittleEndian),
            String(data: prefixData, encoding: .utf16BigEndian),
        ].compactMap { $0?.lowercased() }
        // El barrido sin NUL cubre también UTF-32 ASCII-compatible sin pedir al parser
        // que interprete el documento potencialmente hostil.
        let nullStripped = String(
            decoding: prefixData.filter { $0 != 0 },
            as: UTF8.self
        ).lowercased()
        return (candidates + [nullStripped]).contains {
            $0.contains("<!doctype") || $0.contains("<!entity")
        }
    }
}

// MARK: - XML mínimo de container.xml y OPF

private final class EPUBContainerXMLParser: NSObject, XMLParserDelegate {
    private(set) var packagePath: String?

    static func parse(_ data: Data) -> String? {
        let delegate = EPUBContainerXMLParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.packagePath
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        guard localName(elementName, qName) == "rootfile", packagePath == nil else { return }
        packagePath = attribute(attributeDict, named: "full-path")
    }
}

private final class EPUBPackageXMLParser: NSObject, XMLParserDelegate {
    private var titleBuffer = ""
    private var authorBuffer = ""
    private var activeMetadataElement: String?
    private var manifest: [String: EPUBDocumentReader.ManifestItem] = [:]
    private var spine: [String] = []
    private var legacyCoverID: String?

    static func parse(_ data: Data) -> EPUBDocumentReader.Package? {
        let delegate = EPUBPackageXMLParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return EPUBDocumentReader.Package(
            title: cleaned(delegate.titleBuffer),
            author: cleaned(delegate.authorBuffer),
            manifest: delegate.manifest,
            spine: delegate.spine,
            legacyCoverID: delegate.legacyCoverID
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        switch localName(elementName, qName) {
        case "title", "creator":
            activeMetadataElement = localName(elementName, qName)
        case "item":
            guard let id = attribute(attributeDict, named: "id"), !id.isEmpty,
                  let href = attribute(attributeDict, named: "href"), !href.isEmpty,
                  let mediaType = attribute(attributeDict, named: "media-type") else { return }
            let properties = Set((attribute(attributeDict, named: "properties") ?? "")
                .split(whereSeparator: \.isWhitespace).map { $0.lowercased() })
            manifest[id] = .init(href: href, mediaType: mediaType, properties: properties)
        case "itemref":
            guard attribute(attributeDict, named: "linear")?.lowercased() != "no",
                  let idref = attribute(attributeDict, named: "idref"), !idref.isEmpty else { return }
            spine.append(idref)
        case "meta":
            if attribute(attributeDict, named: "name")?.lowercased() == "cover" {
                legacyCoverID = attribute(attributeDict, named: "content")
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch activeMetadataElement {
        case "title" where titleBuffer.count < 2_000:
            titleBuffer += string
        case "creator" where authorBuffer.count < 2_000:
            authorBuffer += string
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(elementName, qName)
        if name == activeMetadataElement { activeMetadataElement = nil }
    }

    private static func cleaned(_ value: String) -> String? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

private func localName(_ elementName: String, _ qualifiedName: String?) -> String {
    let raw = qualifiedName ?? elementName
    return raw.split(separator: ":").last.map { $0.lowercased() } ?? raw.lowercased()
}

private func attribute(_ attributes: [String: String], named target: String) -> String? {
    attributes.first { key, _ in
        key.split(separator: ":").last?.lowercased() == target.lowercased()
    }?.value
}

// MARK: - XHTML a texto sin ejecutar contenido

private struct EPUBParsedChapter {
    let heading: String?
    let text: String
    let wasTruncated: Bool
}

private final class EPUBChapterTextParser: NSObject, XMLParserDelegate {
    private static let blockElements: Set<String> = [
        "address", "article", "aside", "blockquote", "br", "div", "figcaption", "figure",
        "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main",
        "ol", "p", "pre", "section", "table", "td", "th", "tr", "ul"
    ]
    private static let suppressedElements: Set<String> = [
        "head", "nav", "noscript", "script", "style", "svg"
    ]

    private let maximumCharacters: Int
    private var text = ""
    private var heading = ""
    private var headingDepth = 0
    private var suppressedDepth = 0
    private(set) var wasTruncated = false

    private init(maximumCharacters: Int) {
        self.maximumCharacters = max(1, maximumCharacters)
    }

    static func parse(data: Data, maximumCharacters: Int) -> EPUBParsedChapter {
        // Un XHTML con DTD/entidades internas podría expandirse antes de llegar al delegate.
        // Se inspecciona TODO el capítulo ya acotado, no solo una cabecera fácil de evadir.
        if XMLInputSafety.containsForbiddenDeclaration(data) {
            return fallback(data: data, maximumCharacters: maximumCharacters)
        }
        let delegate = EPUBChapterTextParser(maximumCharacters: maximumCharacters)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let parsed = parser.parse()
        if parsed || delegate.wasTruncated {
            return .init(
                heading: cleanedHeading(delegate.heading),
                text: delegate.text,
                wasTruncated: delegate.wasTruncated
            )
        }
        return fallback(data: data, maximumCharacters: maximumCharacters)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let name = localName(elementName, qName)
        if suppressedDepth > 0 {
            suppressedDepth += 1
            return
        }
        if Self.suppressedElements.contains(name) {
            suppressedDepth = 1
            return
        }
        if name == "h1" || name == "h2" { headingDepth += 1 }
        if Self.blockElements.contains(name) { append("\n") }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard suppressedDepth == 0 else { return }
        append(string)
        if headingDepth > 0, heading.count < 500 { heading += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(elementName, qName)
        if suppressedDepth > 0 {
            suppressedDepth -= 1
            return
        }
        if (name == "h1" || name == "h2"), headingDepth > 0 { headingDepth -= 1 }
        if Self.blockElements.contains(name) { append("\n") }
    }

    private func append(_ fragment: String) {
        guard !wasTruncated else { return }
        let remaining = maximumCharacters - text.count
        guard remaining > 0 else {
            wasTruncated = true
            return
        }
        if fragment.count > remaining {
            text += String(fragment.prefix(remaining))
            wasTruncated = true
        } else {
            text += fragment
        }
    }

    private static func cleanedHeading(_ value: String) -> String? {
        let cleaned = value
            .replacing(#/\s+/#, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(180))
    }

    /// EPUB 2 antiguo puede traer HTML tolerante en vez de XHTML bien formado. El fallback
    /// elimina etiquetas con un autómata simple; nunca evalúa entidades externas ni scripts.
    private static func fallback(data: Data, maximumCharacters: Int) -> EPUBParsedChapter {
        let source = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        var output = ""
        output.reserveCapacity(min(source.count, maximumCharacters))
        var insideTag = false
        var tagBuffer = ""
        var suppressedTag: String?
        var truncated = false

        for character in source {
            if output.count >= maximumCharacters {
                truncated = true
                break
            }
            if character == "<" {
                insideTag = true
                tagBuffer = ""
                continue
            }
            if insideTag {
                if character == ">" {
                    insideTag = false
                    let raw = tagBuffer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let closing = raw.hasPrefix("/")
                    let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        .split(whereSeparator: { $0.isWhitespace || $0 == "/" }).first.map(String.init) ?? ""
                    if closing, suppressedTag == name { suppressedTag = nil }
                    if !closing, ["script", "style", "nav", "svg"].contains(name) { suppressedTag = name }
                    if blockElements.contains(name), suppressedTag == nil { output.append("\n") }
                } else if tagBuffer.count < 4_096 {
                    tagBuffer.append(character)
                }
                continue
            }
            if suppressedTag == nil { output.append(character) }
        }
        return .init(heading: nil, text: decodeBasicEntities(output), wasTruncated: truncated)
    }

    private static func decodeBasicEntities(_ value: String) -> String {
        var result = value
        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'", "&#39;": "'"
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result.replacing(#/&#(?:x([0-9A-Fa-f]{1,6})|([0-9]{1,7}));/#) { match in
            let raw = match.1.map(String.init) ?? match.2.map(String.init) ?? ""
            let radix = match.1 == nil ? 10 : 16
            guard let value = UInt32(raw, radix: radix), let scalar = UnicodeScalar(value) else {
                return String(match.0)
            }
            return String(Character(scalar))
        }
    }
}
