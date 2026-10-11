import Foundation
import SwiftData
import StacklumeCore

// MARK: - DTOs (formato de copia de seguridad JSON)

public struct BackupData: Codable, Sendable {
    public var version: String
    public var exportedAt: Date
    public var categories: [CategoryDTO]
    public var tags: [TagDTO]
    public var links: [LinkDTO]
    public var rules: [RuleDTO]
}

public struct CategoryDTO: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var details: String?
    public var icon: String
    public var colorHex: String
    public var order: Int
    /// Padre en la jerarquía de colecciones (opcional → retrocompatible).
    public var parentID: UUID?
    /// Portada personalizada de la colección (opcional → retrocompatible).
    public var coverImageData: Data?
}

public struct TagDTO: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var colorHex: String
    public var order: Int
    /// Padre en la jerarquía de etiquetas (opcional → retrocompatible).
    public var parentID: UUID?
}

public struct LinkDTO: Codable, Sendable {
    public var id: UUID
    public var url: String
    public var title: String
    public var details: String?
    public var imageURL: String?
    public var faviconURL: String?
    public var siteName: String?
    public var isFavorite: Bool
    public var notes: String?
    public var readingStatus: String
    public var platform: String
    public var contentType: String
    public var platformColor: String?
    public var order: Int
    public var categoryID: UUID?
    public var tagIDs: [UUID]
    public var createdAt: Date
    /// Comando de instalación guardado (opcional → retrocompatible).
    public var command: String?
}

public struct RuleDTO: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var conditionType: String
    public var conditionValue: String
    public var actionType: String
    public var actionValue: String
    public var order: Int
    public var isActive: Bool
}

// MARK: - Servicio

/// Exporta e importa la biblioteca completa en formato JSON.
@MainActor
public enum BackupService {

    public static let formatVersion = "1.0.0"

    public static func exportData(from context: ModelContext) throws -> Data {
        let categories = (try? context.fetch(FetchDescriptor<BookmarkCategory>())) ?? []
        let tags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        let links = (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        let rules = (try? context.fetch(FetchDescriptor<ClassificationRule>())) ?? []

        let backup = BackupData(
            version: formatVersion,
            exportedAt: Date(),
            categories: categories.filter { $0.deletedAt == nil }.map {
                CategoryDTO(id: $0.id, name: $0.name, details: $0.details,
                            icon: $0.icon, colorHex: $0.colorHex, order: $0.order,
                            parentID: $0.parent?.id, coverImageData: $0.coverImageData)
            },
            tags: tags.filter { $0.deletedAt == nil }.map {
                TagDTO(id: $0.id, name: $0.name, colorHex: $0.colorHex, order: $0.order,
                       parentID: $0.parent?.id)
            },
            links: links.filter { $0.deletedAt == nil }.map { link in
                LinkDTO(id: link.id, url: link.url, title: link.title, details: link.details,
                        imageURL: link.imageURL, faviconURL: link.faviconURL, siteName: link.siteName,
                        isFavorite: link.isFavorite, notes: link.notes,
                        readingStatus: link.readingStatus.rawValue,
                        platform: link.platform.rawValue, contentType: link.contentType.rawValue,
                        platformColor: link.platformColor, order: link.order,
                        categoryID: link.category?.id, tagIDs: link.tags.map(\.id),
                        createdAt: link.createdAt, command: link.command)
            },
            rules: rules.map {
                RuleDTO(id: $0.id, name: $0.name, conditionType: $0.conditionType.rawValue,
                        conditionValue: $0.conditionValue, actionType: $0.actionType.rawValue,
                        actionValue: $0.actionValue, order: $0.order, isActive: $0.isActive)
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    /// Exporta UNA colección concreta (sus enlaces activos + las etiquetas que usan)
    /// como archivo de biblioteca, para compartirla. El receptor la fusiona como el
    /// resto. La colección se exporta sin padre (parentID = nil).
    public static func exportCollection(_ categoryID: UUID, from context: ModelContext) throws -> Data {
        let allCategories = (try? context.fetch(FetchDescriptor<BookmarkCategory>())) ?? []
        guard let category = allCategories.first(where: { $0.id == categoryID && $0.deletedAt == nil }) else {
            throw NSError(domain: "Stacklume", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Colección no encontrada"])
        }
        let links = category.links.filter { $0.deletedAt == nil }
        let usedTagIDs = Set(links.flatMap { $0.tags.map(\.id) })
        let allTags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        let tags = allTags.filter { usedTagIDs.contains($0.id) && $0.deletedAt == nil }

        let backup = BackupData(
            version: formatVersion,
            exportedAt: Date(),
            categories: [CategoryDTO(id: category.id, name: category.name, details: category.details,
                                     icon: category.icon, colorHex: category.colorHex, order: category.order,
                                     parentID: nil, coverImageData: category.coverImageData)],
            tags: tags.map { TagDTO(id: $0.id, name: $0.name, colorHex: $0.colorHex, order: $0.order,
                                    parentID: $0.parent?.id) },
            links: links.map { link in
                LinkDTO(id: link.id, url: link.url, title: link.title, details: link.details,
                        imageURL: link.imageURL, faviconURL: link.faviconURL, siteName: link.siteName,
                        isFavorite: link.isFavorite, notes: link.notes,
                        readingStatus: link.readingStatus.rawValue,
                        platform: link.platform.rawValue, contentType: link.contentType.rawValue,
                        platformColor: link.platformColor, order: link.order,
                        categoryID: category.id, tagIDs: link.tags.map(\.id),
                        createdAt: link.createdAt, command: link.command)
            },
            rules: [])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    /// Importa una copia. Si `replace` es `true`, elimina el contenido actual antes.
    @discardableResult
    public static func importData(_ data: Data, into context: ModelContext, replace: Bool) throws -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(BackupData.self, from: data)

        if replace {
            for link in (try? context.fetch(FetchDescriptor<Bookmark>())) ?? [] { context.delete(link) }
            for category in (try? context.fetch(FetchDescriptor<BookmarkCategory>())) ?? [] { context.delete(category) }
            for tag in (try? context.fetch(FetchDescriptor<Tag>())) ?? [] { context.delete(tag) }
            for rule in (try? context.fetch(FetchDescriptor<ClassificationRule>())) ?? [] { context.delete(rule) }
        }

        var categoryMap: [UUID: BookmarkCategory] = [:]
        for dto in backup.categories {
            let category = BookmarkCategory(id: dto.id, name: dto.name, details: dto.details,
                                            icon: dto.icon, colorHex: dto.colorHex, order: dto.order)
            category.coverImageData = dto.coverImageData
            context.insert(category)
            categoryMap[dto.id] = category
        }
        // Segunda pasada: reconstruye la jerarquía padre→hijo.
        for dto in backup.categories {
            if let parentID = dto.parentID, let child = categoryMap[dto.id] {
                child.parent = categoryMap[parentID]
            }
        }

        var tagMap: [UUID: Tag] = [:]
        for dto in backup.tags {
            let tag = Tag(id: dto.id, name: dto.name, colorHex: dto.colorHex, order: dto.order)
            context.insert(tag)
            tagMap[dto.id] = tag
        }
        // Segunda pasada: jerarquía de etiquetas.
        for dto in backup.tags {
            if let parentID = dto.parentID, let child = tagMap[dto.id] {
                child.parent = tagMap[parentID]
            }
        }

        for dto in backup.links {
            let link = Bookmark(id: dto.id, url: dto.url, title: dto.title, details: dto.details,
                                category: dto.categoryID.flatMap { categoryMap[$0] },
                                tags: dto.tagIDs.compactMap { tagMap[$0] },
                                isFavorite: dto.isFavorite, notes: dto.notes,
                                readingStatus: ReadingStatus(rawValue: dto.readingStatus) ?? .inbox,
                                platform: Platform(rawValue: dto.platform) ?? .generic,
                                contentType: ContentType(rawValue: dto.contentType) ?? .website,
                                order: dto.order)
            link.imageURL = dto.imageURL
            link.faviconURL = dto.faviconURL
            link.siteName = dto.siteName
            link.platformColor = dto.platformColor
            link.command = dto.command
            context.insert(link)
        }

        for dto in backup.rules {
            let rule = ClassificationRule(
                id: dto.id, name: dto.name,
                conditionType: RuleConditionType(rawValue: dto.conditionType) ?? .domain,
                conditionValue: dto.conditionValue,
                actionType: RuleActionType(rawValue: dto.actionType) ?? .addTag,
                actionValue: dto.actionValue, order: dto.order, isActive: dto.isActive)
            context.insert(rule)
        }

        try context.save()
        return backup.links.count
    }

    // MARK: - Compartir entre usuarios (fusión aditiva)

    /// Resumen de una biblioteca recibida, para previsualizar antes de fusionar.
    public struct ShareSummary: Sendable {
        public let links: Int
        public let categories: Int
        public let tags: Int
        public let exportedAt: Date
    }

    /// Resultado de una fusión: cuántos elementos nuevos se han añadido.
    public struct MergeResult: Sendable {
        public let addedLinks: Int
        public let addedCategories: Int
        public let addedTags: Int
        public let skippedLinks: Int
    }

    /// Lee un archivo de biblioteca y devuelve su resumen sin modificar nada.
    public static func summary(of data: Data) throws -> ShareSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(BackupData.self, from: data)
        return ShareSummary(links: backup.links.count, categories: backup.categories.count,
                            tags: backup.tags.count, exportedAt: backup.exportedAt)
    }

    /// Fusiona una biblioteca recibida en la del usuario SIN reemplazar nada:
    /// reutiliza colecciones/etiquetas existentes por nombre (sin distinguir
    /// mayúsculas) y omite los enlaces cuya URL ya existe. Preserva la jerarquía
    /// de colecciones y las relaciones enlace↔colección/etiqueta.
    @discardableResult
    public static func merge(_ data: Data, into context: ModelContext) throws -> MergeResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(BackupData.self, from: data)

        let existingCategories = (try? context.fetch(FetchDescriptor<BookmarkCategory>()))?
            .filter { $0.deletedAt == nil } ?? []
        let existingTags = (try? context.fetch(FetchDescriptor<Tag>()))?
            .filter { $0.deletedAt == nil } ?? []
        let existingLinks = (try? context.fetch(FetchDescriptor<Bookmark>()))?
            .filter { $0.deletedAt == nil } ?? []

        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        var existingURLs = Set(existingLinks.map { norm($0.url) })

        // Colecciones: reutiliza por nombre o crea nuevas (con id nuevo).
        var addedCategories = 0
        var categoryMap: [UUID: BookmarkCategory] = [:]   // id del remitente → local
        for dto in backup.categories {
            if let match = existingCategories.first(where: { norm($0.name) == norm(dto.name) }) {
                categoryMap[dto.id] = match
            } else {
                let category = BookmarkCategory(name: dto.name, details: dto.details,
                                                icon: dto.icon, colorHex: dto.colorHex,
                                                order: dto.order)
                category.coverImageData = dto.coverImageData
                context.insert(category)
                categoryMap[dto.id] = category
                addedCategories += 1
            }
        }
        // Jerarquía: solo para las colecciones recién creadas.
        for dto in backup.categories {
            guard let parentID = dto.parentID,
                  let child = categoryMap[dto.id],
                  child.parent == nil,
                  !existingCategories.contains(where: { $0.id == child.id }) else { continue }
            child.parent = categoryMap[parentID]
        }

        // Etiquetas: reutiliza por nombre o crea nuevas.
        var addedTags = 0
        var tagMap: [UUID: Tag] = [:]
        for dto in backup.tags {
            if let match = existingTags.first(where: { norm($0.name) == norm(dto.name) }) {
                tagMap[dto.id] = match
            } else {
                let tag = Tag(name: dto.name, colorHex: dto.colorHex, order: dto.order)
                context.insert(tag)
                tagMap[dto.id] = tag
                addedTags += 1
            }
        }
        // Jerarquía: solo para etiquetas recién creadas (sin re-anidar las existentes).
        for dto in backup.tags {
            guard let parentID = dto.parentID,
                  let child = tagMap[dto.id], child.parent == nil,
                  !existingTags.contains(where: { $0.id == child.id }) else { continue }
            child.parent = tagMap[parentID]
        }

        // Enlaces: omite los que ya existen (misma URL); crea el resto.
        var addedLinks = 0
        var skippedLinks = 0
        for dto in backup.links {
            if existingURLs.contains(norm(dto.url)) { skippedLinks += 1; continue }
            let link = Bookmark(url: dto.url, title: dto.title, details: dto.details,
                                category: dto.categoryID.flatMap { categoryMap[$0] },
                                tags: dto.tagIDs.compactMap { tagMap[$0] },
                                isFavorite: dto.isFavorite, notes: dto.notes,
                                readingStatus: ReadingStatus(rawValue: dto.readingStatus) ?? .inbox,
                                platform: Platform(rawValue: dto.platform) ?? .generic,
                                contentType: ContentType(rawValue: dto.contentType) ?? .website,
                                order: dto.order)
            link.imageURL = dto.imageURL
            link.faviconURL = dto.faviconURL
            link.siteName = dto.siteName
            link.platformColor = dto.platformColor
            link.command = dto.command
            context.insert(link)
            existingURLs.insert(norm(dto.url))
            addedLinks += 1
        }

        try context.save()
        return MergeResult(addedLinks: addedLinks, addedCategories: addedCategories,
                           addedTags: addedTags, skippedLinks: skippedLinks)
    }
}
