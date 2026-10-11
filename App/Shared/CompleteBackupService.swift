import Foundation
import CryptoKit
import SwiftData
import StacklumeCore
import StacklumePersistence

/// Export/import COMPLETO de la biblioteca. El `BackupService` del paquete cubre
/// categorías/etiquetas/enlaces/reglas, pero NO los datos LATERALES que se perderían en un
/// export→reimport: recordatorios, resaltados + sus notas, progreso de lectura, portadas
/// personalizadas y búsquedas guardadas. Aquí se añaden bajo la clave `extras` del JSON; el
/// import del paquete IGNORA esa clave (retrocompatible) y aquí se restauran. No duplica el
/// formato base: lo envuelve.
@MainActor
enum CompleteBackupService {
    private static let maximumArchiveBytes = 256 * 1_024 * 1_024
    private static let maximumAttachmentBytes = 128 * 1_024 * 1_024
    private static let maximumCoverBytes = 24 * 1_024 * 1_024
    private static let maximumBinaryPayloadBytes = 240 * 1_024 * 1_024
    private static let maximumAttachments = 2_000
    private static let maximumHighlights = 200_000
    private static let maximumSidecarEntries = 100_000

    struct Extras: Codable {
        var reminders: [String: Date] = [:]        // linkID → reminderAt
        var highlights: [HighlightBackup] = []
        var readingProgress: [String: Double] = [:]
        var customCovers: [String: Data] = [:]     // linkID → JPEG
        var coverRecoveryProvenance: [String: CoverRecoveryProvenanceStore.Entry]?
        var savedSearchesJSON: String = ""
        var waybackArchived: [String: String] = [:] // clave canónica de URL → fecha ISO
        var videoProgress: [String: Double] = [:]  // clave canónica de URL → segundos
        /// Opcional para que los backups anteriores sigan decodificando sin migración.
        var attachments: [String: AttachmentBackup]?
        var xPostDrafts: [String: XPostDraft]?
        var modelCatalogFavoritesJSON: Data?
    }

    /// Copia autocontenida de un adjunto. `BackupService` no serializa `fileData` y
    /// deduplica por URL; como los archivos locales usan URL vacía, dos documentos
    /// colisionarían. Este bloque permite restaurarlos de forma inequívoca y recrear los
    /// que la fusión base haya omitido.
    struct AttachmentBackup: Codable {
        var data: Data
        var kind: String
        var offlineText: String?
        var title: String
        var details: String?
        var imageURL: String?
        var faviconURL: String?
        var siteName: String?
        var isFavorite: Bool
        var isRead: Bool
        var isArchived: Bool
        var notes: String?
        var readingStatus: String
        var platform: String
        var contentType: String
        var platformColor: String?
        var source: String?
        var author: String?
        var publishedAt: Date?
        var lastCheckedAt: Date?
        var healthStatus: String?
        var installCommands: [String]
        var summary: String?
        var semanticTags: [String]
        var command: String?
        var highlightColorHex: String?
        var reviewAt: Date?
        var order: Int
        var createdAt: Date
        var updatedAt: Date
        var categoryName: String?
        var tagNames: [String]
    }

    struct RestoreResult: Sendable {
        let restoredAttachments: Int
        let createdLinks: Int
    }

    struct HighlightBackup: Codable {
        var id: UUID
        var linkID: UUID
        var text: String
        var colorHex: String
        var note: String
        var createdAt: Date
    }

    // MARK: - Export

    /// JSON completo: base del paquete + `extras`.
    static func export(from context: ModelContext) throws -> Data {
        let baseData = try BackupService.exportData(from: context)
        var json = (try? JSONSerialization.jsonObject(with: baseData) as? [String: Any]) ?? [:]
        let extrasData = try JSONEncoder().encode(buildExtras(in: context))
        json["extras"] = try JSONSerialization.jsonObject(with: extrasData)
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }

    private static func buildExtras(in context: ModelContext) -> Extras {
        var e = Extras()
        let links = ((try? context.fetch(FetchDescriptor<Bookmark>())) ?? [])
            .filter { $0.deletedAt == nil }
        for link in links {
            if let draft = XPostDraftStore.load(link.id) {
                if e.xPostDrafts == nil { e.xPostDrafts = [:] }
                e.xPostDrafts?[link.id.uuidString] = draft
            }
            if let r = link.reminderAt { e.reminders[link.id.uuidString] = r }
            if let data = CustomCoverStore.shared.coverData(for: link.id) {
                e.customCovers[link.id.uuidString] = data
                if let entry = CoverRecoveryProvenanceStore.shared.entry(for: link.id),
                   entry.coverJPEGDigest == coverDigest(data) {
                    if e.coverRecoveryProvenance == nil { e.coverRecoveryProvenance = [:] }
                    e.coverRecoveryProvenance?[link.id.uuidString] = entry
                }
            }
            for h in link.highlights {
                e.highlights.append(HighlightBackup(
                    id: h.id, linkID: link.id, text: h.text, colorHex: h.colorHex,
                    note: HighlightNoteStore.note(for: h.id), createdAt: h.createdAt))
            }
            // Comprueba primero el tipo para no materializar el almacenamiento externo
            // de `fileData` en los enlaces web, que constituyen casi toda la biblioteca.
            if let kind = link.fileKind, let data = link.fileData {
                if e.attachments == nil { e.attachments = [:] }
                e.attachments?[link.id.uuidString] = AttachmentBackup(
                    data: data,
                    kind: kind,
                    offlineText: link.offlineText,
                    title: link.title,
                    details: link.details,
                    imageURL: link.imageURL,
                    faviconURL: link.faviconURL,
                    siteName: link.siteName,
                    isFavorite: link.isFavorite,
                    isRead: link.isRead,
                    isArchived: link.isArchived,
                    notes: link.notes,
                    readingStatus: link.readingStatus.rawValue,
                    platform: link.platform.rawValue,
                    contentType: link.contentType.rawValue,
                    platformColor: link.platformColor,
                    source: link.source,
                    author: link.author,
                    publishedAt: link.publishedAt,
                    lastCheckedAt: link.lastCheckedAt,
                    healthStatus: link.healthStatus?.rawValue,
                    installCommands: link.installCommands,
                    summary: link.summary,
                    semanticTags: link.semanticTags,
                    command: link.command,
                    highlightColorHex: link.highlightColorHex,
                    reviewAt: link.reviewAt,
                    order: link.order,
                    createdAt: link.createdAt,
                    updatedAt: link.updatedAt,
                    categoryName: link.category?.name,
                    tagNames: link.tags.map(\.name)
                )
            }
        }
        e.readingProgress = ReadingProgressStore.allEntries()
        e.savedSearchesJSON = UserDefaults.standard.string(forKey: "stacklume.savedSearches") ?? ""
        e.waybackArchived = WaybackStore.allEntries()
        e.videoProgress = VideoProgressStore.allEntries()
        e.modelCatalogFavoritesJSON = ModelCatalogFavorites.exportJSON()
        return e
    }

    // MARK: - Restauración (tras importar la base con BackupService.merge)

    /// Impide que una base se importe antes de descubrir que sus datos laterales son inválidos.
    static func validateForImport(_ data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportSafetyError.invalidStructure
        }
        guard let object = json["extras"] else { return }
        let extrasData = try JSONSerialization.data(withJSONObject: object)
        let extras = try JSONDecoder().decode(Extras.self, from: extrasData)
        guard validatesStructure(of: extras) else { throw ImportSafetyError.limitExceeded }
    }

    /// Restaura los `extras` de forma ADITIVA (no pisa lo que ya hay). Best-effort.
    @discardableResult
    static func restoreExtras(from data: Data, in context: ModelContext) -> RestoreResult {
        guard data.count <= maximumArchiveBytes,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let extrasObj = json["extras"],
              let extrasData = try? JSONSerialization.data(withJSONObject: extrasObj),
              extrasData.count <= maximumArchiveBytes,
              let extras = try? JSONDecoder().decode(Extras.self, from: extrasData),
              validatesStructure(of: extras) else {
            return RestoreResult(restoredAttachments: 0, createdLinks: 0)
        }

        var links = (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        var byID = Dictionary(links.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var localIDs = BackupArchiveInspector.localIDMap(
            from: data,
            localLinks: links.map { BackupLinkIdentity(id: $0.id, url: $0.url) })

        var restoredAttachments = 0
        var createdLinks = 0
        var claimedPlaceholders: Set<UUID> = []
        var claimedAttachments: Set<UUID> = []

        func apply(_ backup: AttachmentBackup, to link: Bookmark, overwriteMetadata: Bool) {
            link.fileData = backup.data
            link.fileKind = backup.kind
            if link.offlineText == nil { link.offlineText = backup.offlineText }
            guard overwriteMetadata else { return }

            link.url = ""
            link.title = backup.title
            link.details = backup.details
            link.imageURL = backup.imageURL
            link.faviconURL = backup.faviconURL
            link.siteName = backup.siteName
            link.isFavorite = backup.isFavorite
            link.isRead = backup.isRead
            link.isArchived = backup.isArchived
            link.notes = backup.notes
            link.readingStatus = ReadingStatus(rawValue: backup.readingStatus) ?? .inbox
            link.platform = Platform(rawValue: backup.platform) ?? .generic
            link.contentType = ContentType(rawValue: backup.contentType) ?? .document
            link.platformColor = backup.platformColor
            link.source = backup.source
            link.author = backup.author
            link.publishedAt = backup.publishedAt
            link.lastCheckedAt = backup.lastCheckedAt
            link.healthStatus = backup.healthStatus.flatMap(HealthStatus.init(rawValue:))
            link.installCommands = backup.installCommands
            link.summary = backup.summary
            link.semanticTags = backup.semanticTags
            link.command = backup.command
            link.highlightColorHex = backup.highlightColorHex
            link.reviewAt = backup.reviewAt
            link.order = backup.order
            link.createdAt = backup.createdAt
            link.updatedAt = backup.updatedAt
            if let name = backup.categoryName {
                link.category = EntityResolver.category(name, in: context)
            }
            var tagCache: [String: Tag] = [:]
            link.tags = backup.tagNames.compactMap {
                EntityResolver.tag($0, in: context, cache: &tagCache)
            }
        }

        // Restaurar adjuntos ANTES que el resto de extras para completar el mapa remoto→local.
        // 1) dedup exacto por bytes; 2) placeholder creado por la fusión base; 3) recreación.
        for (idString, backup) in extras.attachments ?? [:] {
            guard let backupID = UUID(uuidString: idString),
                  backup.data.count <= maximumAttachmentBytes else { continue }
            let exact = links.first {
                !claimedAttachments.contains($0.id)
                    && $0.fileKind == backup.kind
                    && $0.fileData == backup.data
            }
            let placeholder = links.first {
                !claimedPlaceholders.contains($0.id)
                    && $0.url.isEmpty
                    && $0.fileData == nil
                    && $0.contentType == .document
                    && $0.title == backup.title
            }

            let local: Bookmark
            if let exact {
                local = exact
                apply(backup, to: local, overwriteMetadata: false)
            } else if let placeholder {
                local = placeholder
                claimedPlaceholders.insert(placeholder.id)
                apply(backup, to: local, overwriteMetadata: true)
            } else {
                local = Bookmark(
                    url: "",
                    title: backup.title,
                    details: backup.details,
                    isFavorite: backup.isFavorite,
                    notes: backup.notes,
                    readingStatus: ReadingStatus(rawValue: backup.readingStatus) ?? .inbox,
                    platform: Platform(rawValue: backup.platform) ?? .generic,
                    contentType: ContentType(rawValue: backup.contentType) ?? .document,
                    order: backup.order
                )
                context.insert(local)
                apply(backup, to: local, overwriteMetadata: true)
                links.append(local)
                byID[local.id] = local
                createdLinks += 1
            }
            claimedAttachments.insert(local.id)
            localIDs[backupID] = local.id
            restoredAttachments += 1
        }

        func localLink(for backupID: UUID) -> Bookmark? {
            guard let localID = localIDs[backupID] else { return nil }
            return byID[localID]
        }

        for (idStr, date) in extras.reminders {
            if let backupID = UUID(uuidString: idStr),
               let link = localLink(for: backupID), link.reminderAt == nil {
                link.reminderAt = date
            }
        }
        for hb in extras.highlights {
            guard let link = localLink(for: hb.linkID),
                  hb.text.count <= 20_000,
                  hb.note.count <= 100_000,
                  !link.highlights.contains(where: { $0.text == hb.text }) else { continue }
            let h = Highlight(id: hb.id, text: hb.text, colorHex: hb.colorHex, bookmark: link)
            h.createdAt = hb.createdAt
            context.insert(h)
            if !hb.note.isEmpty { HighlightNoteStore.setNote(hb.note, for: h.id) }
        }
        for (idStr, coverData) in extras.customCovers {
            if let backupID = UUID(uuidString: idStr),
               let localID = localIDs[backupID],
               !CustomCoverStore.shared.has(localID) {
                if CustomCoverStore.shared.restore(coverData, for: localID),
                   let entry = extras.coverRecoveryProvenance?[idStr], entry.isValid,
                   entry.coverJPEGDigest == coverDigest(coverData),
                   let link = byID[localID],
                   CanonicalURL.key(entry.pageURL) == CanonicalURL.key(link.url),
                   let restored = CustomCoverStore.shared.coverData(for: localID) {
                    // La restauración valida y vuelve a codificar el JPEG; se vincula a sus bytes reales.
                    let restoredEntry = CoverRecoveryProvenanceStore.Entry(
                        referenceURL: entry.referenceURL, pageURL: entry.pageURL,
                        recoveredImageURL: entry.recoveredImageURL, recoveredAt: entry.recoveredAt,
                        coverJPEGDigest: coverDigest(restored))
                    CoverRecoveryProvenanceStore.shared.record(restoredEntry, for: localID)
                }
            }
        }
        for (idStr, draft) in extras.xPostDrafts ?? [:] {
            if let backupID = UUID(uuidString: idStr), let localID = localIDs[backupID],
               XPostDraftStore.load(localID) == nil {
                do { try XPostDraftStore.save(draft, id: localID) }
                catch { PersistenceLog.logger.error("No se pudo restaurar un borrador de X: \(error.localizedDescription, privacy: .public)") }
            }
        }
        for (key, pct) in extras.readingProgress where ReadingProgressStore.progress(forKey: key) == 0 {
            ReadingProgressStore.setProgress(pct, forKey: key)
        }
        for (urlKey, date) in extras.waybackArchived {
            WaybackStore.restore(urlKey: urlKey, date: date)
        }
        for (urlKey, seconds) in extras.videoProgress where VideoProgressStore.progress(for: urlKey) == 0 {
            VideoProgressStore.save(seconds, for: urlKey)
        }
        // Búsquedas guardadas: fusiona por id (añade las que no estén).
        if !extras.savedSearchesJSON.isEmpty {
            mergeSavedSearches(extras.savedSearchesJSON)
        }
        if let data = extras.modelCatalogFavoritesJSON {
            do { try ModelCatalogFavorites.mergeJSON(data) }
            catch { PersistenceLog.logger.error("No se pudieron restaurar los favoritos de los catálogos: \(error.localizedDescription, privacy: .public)") }
        }
        context.saveLogging()
        return RestoreResult(
            restoredAttachments: restoredAttachments,
            createdLinks: createdLinks
        )
    }

    private static func validatesStructure(of extras: Extras) -> Bool {
        guard (extras.attachments?.count ?? 0) <= maximumAttachments,
              (extras.xPostDrafts?.count ?? 0) <= maximumSidecarEntries,
              extras.highlights.count <= maximumHighlights,
              extras.reminders.count <= maximumSidecarEntries,
              extras.readingProgress.count <= maximumSidecarEntries,
              extras.customCovers.count <= maximumSidecarEntries,
              (extras.coverRecoveryProvenance?.count ?? 0) <= maximumSidecarEntries,
              (extras.coverRecoveryProvenance ?? [:]).allSatisfy({ UUID(uuidString: $0.key) != nil && $0.value.isValid }),
              extras.waybackArchived.count <= maximumSidecarEntries,
              extras.videoProgress.count <= maximumSidecarEntries,
              extras.savedSearchesJSON.utf8.count <= 4 * 1_024 * 1_024
        else { return false }

        var total = 0
        if let data = extras.modelCatalogFavoritesJSON {
            guard (try? ModelCatalogFavorites.decode(data)) != nil,
                  add(data.count, to: &total) else { return false }
        }
        for draft in (extras.xPostDrafts ?? [:]).values {
            guard draft.text.utf8.count <= 24_000, draft.audience.utf8.count <= 4_000,
                  draft.angle.utf8.count <= 100, draft.language.utf8.count <= 20,
                  add(draft.text.utf8.count + draft.audience.utf8.count, to: &total) else { return false }
        }
        for attachment in (extras.attachments ?? [:]).values {
            guard attachment.data.count <= maximumAttachmentBytes,
                  add(attachment.data.count, to: &total) else { return false }
        }
        for cover in extras.customCovers.values {
            guard cover.count <= maximumCoverBytes,
                  add(cover.count, to: &total) else { return false }
        }
        return total <= maximumBinaryPayloadBytes
    }

    private static func coverDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func add(_ value: Int, to total: inout Int) -> Bool {
        let (sum, overflow) = total.addingReportingOverflow(value)
        guard !overflow, sum <= maximumBinaryPayloadBytes else { return false }
        total = sum
        return true
    }

    /// Fusiona las búsquedas guardadas del backup con las actuales (por id), sin duplicar.
    private static func mergeSavedSearches(_ incomingJSON: String) {
        let current = SavedSearchStore.decode(UserDefaults.standard.string(forKey: "stacklume.savedSearches") ?? "")
        let incoming = SavedSearchStore.decode(incomingJSON)
        let existingIDs = Set(current.map(\.id))
        let merged = current + incoming.filter { !existingIDs.contains($0.id) }
        UserDefaults.standard.set(SavedSearchStore.encode(merged), forKey: "stacklume.savedSearches")
    }
}
