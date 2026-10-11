import Foundation

enum ImportSafetyError: LocalizedError, Equatable {
    case limitExceeded
    case invalidStructure
    case duplicateIdentity
    case cyclicHierarchy

    var errorDescription: String? {
        switch self {
        case .limitExceeded: "La importación supera el límite seguro de registros, campos o profundidad."
        case .invalidStructure: "El archivo de importación tiene una estructura inválida."
        case .duplicateIdentity: "La importación contiene identificadores repetidos."
        case .cyclicHierarchy: "La importación contiene una jerarquía circular."
        }
    }
}

/// Preflight previo a los decodificadores y, sobre todo, a cualquier escritura en SwiftData.
enum ImportSafety {
    static let maximumArchiveBytes = 256 * 1_024 * 1_024
    static let maximumTextBytes = 64 * 1_024 * 1_024
    static let maximumRecords = 100_000
    static let maximumDepth = 64
    static let maximumFieldBytes = 2 * 1_024 * 1_024
    static let maximumShortFieldBytes = 16 * 1_024
    private static let maximumNodes = 4_000_000
    private static let binaryFields: Set<String> = ["data", "coverImageData", "modelCatalogFavoritesJSON"]
    private static let shortFields: Set<String> = ["url", "URLString", "savedURL", "imageURL", "imageUrl", "faviconURL", "faviconUrl", "name", "title", "savedTitle", "folder", "icon", "id", "parentID"]

    private struct Frame {
        let opening: UInt8
        let containerKey: String
        var key = ""
        var expectsKey: Bool
        var keys: Set<String> = []
        var separators = 0
    }

    /// Acota el grafo antes de JSONSerialization/JSONDecoder; las cadenas escapadas no
    /// confunden la profundidad y las claves repetidas no se pierden durante el parseo.
    static func preflightJSON(_ data: Data) throws {
        guard !data.isEmpty, data.count <= maximumArchiveBytes else { throw ImportSafetyError.limitExceeded }
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var frames: [Frame] = []
            var stringStart: Int?
            var escaped = false
            var nodes = 0
            for index in bytes.indices {
                let byte = bytes[index]
                if let start = stringStart {
                    let binary = frames.last.map { binaryFields.contains($0.key) || $0.containerKey == "customCovers" } ?? false
                    let limit = binary ? 180 * 1_024 * 1_024 : 12 * 1_024 * 1_024
                    guard index - start <= limit else { throw ImportSafetyError.limitExceeded }
                    if escaped { escaped = false; continue }
                    if byte == 92 { escaped = true; continue }
                    if byte != 34 {
                        continue
                    }
                    if let last = frames.indices.last, frames[last].expectsKey {
                        guard index - start <= 3_072 else { throw ImportSafetyError.limitExceeded }
                        let token = Data(bytes[start...index])
                        let key = try JSONDecoder().decode(String.self, from: token)
                        guard frames[last].keys.insert(key).inserted else { throw ImportSafetyError.invalidStructure }
                        frames[last].key = key
                        frames[last].expectsKey = false
                    }
                    stringStart = nil
                    continue
                }
                switch byte {
                case 34:
                    stringStart = index
                    nodes += 1
                case 123, 91:
                    guard frames.count < maximumDepth else { throw ImportSafetyError.limitExceeded }
                    frames.append(Frame(opening: byte, containerKey: frames.last?.key ?? "", expectsKey: byte == 123))
                    nodes += 1
                case 125, 93:
                    guard let frame = frames.popLast(), frame.opening == (byte == 125 ? 123 : 91) else {
                        throw ImportSafetyError.invalidStructure
                    }
                case 44:
                    guard let last = frames.indices.last else { throw ImportSafetyError.invalidStructure }
                    frames[last].separators += 1
                    let limit = frames[last].opening == 91 ? 200_000 : 100_000
                    guard frames[last].separators < limit else { throw ImportSafetyError.limitExceeded }
                    frames[last].expectsKey = frames[last].opening == 123
                    if frames[last].opening == 91 { nodes += 1 }
                default: break
                }
                guard nodes <= maximumNodes else { throw ImportSafetyError.limitExceeded }
            }
            guard stringStart == nil, frames.isEmpty else { throw ImportSafetyError.invalidStructure }
        }
    }

    static func jsonObject(_ data: Data) throws -> Any {
        try preflightJSON(data)
        let value = try JSONSerialization.jsonObject(with: data)
        try validateObject(value)
        return value
    }

    static func validateObject(_ value: Any) throws {
        var nodes = 0
        func visit(_ value: Any, key: String, containerKey: String, depth: Int) throws {
            nodes += 1
            guard nodes <= maximumNodes, depth <= maximumDepth else { throw ImportSafetyError.limitExceeded }
            if let text = value as? String {
                let binary = binaryFields.contains(key) || containerKey == "customCovers"
                let content = key == "offlineText" || key == "offlineHTML"
                let limit = binary ? 180 * 1_024 * 1_024 : content ? 8 * 1_024 * 1_024 : key == "savedSearchesJSON" ? 4 * 1_024 * 1_024 : shortFields.contains(key) ? maximumShortFieldBytes : maximumFieldBytes
                guard text.utf8.count <= limit else { throw ImportSafetyError.limitExceeded }
            } else if let array = value as? [Any] {
                let limit = ["tagIDs", "tagNames", "semanticTags", "installCommands"].contains(key) ? 256 : 200_000
                guard array.count <= limit else { throw ImportSafetyError.limitExceeded }
                for child in array { try visit(child, key: key, containerKey: containerKey, depth: depth + 1) }
            } else if let dictionary = value as? [String: Any] {
                guard dictionary.count <= maximumRecords else { throw ImportSafetyError.limitExceeded }
                for (childKey, child) in dictionary {
                    guard childKey.utf8.count <= 512 else { throw ImportSafetyError.limitExceeded }
                    try visit(child, key: childKey, containerKey: key, depth: depth + 1)
                }
            }
        }
        try visit(value, key: "", containerKey: "", depth: 0)
    }

    static func validateBackup(_ data: Data) throws {
        guard let root = try jsonObject(data) as? [String: Any] else { throw ImportSafetyError.invalidStructure }
        for key in ["links", "categories", "tags", "rules"] {
            guard let records = root[key] as? [[String: Any]], records.count <= maximumRecords else {
                throw ImportSafetyError.invalidStructure
            }
            var ids: Set<String> = []
            for record in records {
                guard let raw = record["id"] as? String, let id = UUID(uuidString: raw) else {
                    throw ImportSafetyError.invalidStructure
                }
                guard ids.insert(id.uuidString).inserted else { throw ImportSafetyError.duplicateIdentity }
            }
            if key == "categories" || key == "tags" {
                var parents: [String: String] = [:]
                for record in records {
                    guard let raw = record["id"] as? String, let id = UUID(uuidString: raw) else { continue }
                    if let rawParent = record["parentID"] as? String {
                        guard let parent = UUID(uuidString: rawParent) else { throw ImportSafetyError.invalidStructure }
                        parents[id.uuidString] = parent.uuidString
                    }
                }
                try validateParents(parents)
            }
        }
    }

    static func validateParents(_ parents: [String: String]) throws {
        var depths: [String: Int] = [:]
        for start in parents.keys where depths[start] == nil {
            var path: [String] = []
            var visiting: Set<String> = []
            var current = start
            while let parent = parents[current], depths[current] == nil {
                guard visiting.insert(current).inserted else { throw ImportSafetyError.cyclicHierarchy }
                path.append(current)
                guard path.count <= maximumDepth else { throw ImportSafetyError.limitExceeded }
                current = parent
            }
            var depth = depths[current] ?? 0
            for id in path.reversed() {
                depth += 1
                guard depth <= maximumDepth else { throw ImportSafetyError.limitExceeded }
                depths[id] = depth
            }
        }
    }

    static func validateBookmarks(_ bookmarks: [BrowserBookmark]) throws {
        guard bookmarks.count <= maximumRecords else { throw ImportSafetyError.limitExceeded }
        for bookmark in bookmarks {
            guard bookmark.url.utf8.count <= maximumShortFieldBytes,
                  bookmark.title.utf8.count <= maximumShortFieldBytes,
                  bookmark.folder.utf8.count <= maximumShortFieldBytes,
                  (bookmark.detail?.utf8.count ?? 0) <= maximumFieldBytes else { throw ImportSafetyError.limitExceeded }
        }
    }
}

enum BoundedCSVImporter {
    static func parse(_ text: String) throws -> [[String]] {
        guard text.utf8.count <= ImportSafety.maximumTextBytes else { throw ImportSafetyError.limitExceeded }
        var rows: [[String]] = [], row: [String] = [], field = ""
        var fieldBytes = 0
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character?
        func next() -> Character? { if let value = pending { pending = nil; return value }; return iterator.next() }
        func append(_ character: Character) throws {
            fieldBytes += character.utf8.count
            guard fieldBytes <= ImportSafety.maximumFieldBytes else { throw ImportSafetyError.limitExceeded }
            field.append(character)
        }
        func finishField() throws {
            guard row.count < 256 else { throw ImportSafetyError.limitExceeded }
            row.append(field); field = ""; fieldBytes = 0
        }
        func finishRow() throws {
            try finishField()
            guard rows.count <= ImportSafety.maximumRecords else { throw ImportSafetyError.limitExceeded }
            rows.append(row); row = []
        }
        while let character = next() {
            if quoted {
                if character == "\"" {
                    if let following = next() {
                        if following == "\"" { try append("\"") } else { quoted = false; pending = following }
                    } else { quoted = false }
                } else { try append(character) }
            } else {
                switch character {
                case "\"": quoted = true
                case ",": try finishField()
                case "\n", "\r\n": try finishRow()
                case "\r": break
                default: try append(character)
                }
            }
        }
        guard !quoted else { throw ImportSafetyError.invalidStructure }
        if !field.isEmpty || !row.isEmpty { try finishRow() }
        return rows
    }
}
