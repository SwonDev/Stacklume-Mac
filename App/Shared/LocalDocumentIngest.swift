import Foundation
import SwiftData
import StacklumeCore

/// Persistencia de adjuntos locales preparados por `DroppedContentImporter`.
/// Mantiene todos los `Bookmark` dentro del `MainActor` y guarda el lote una sola vez.
@MainActor
enum LocalDocumentIngest {
    struct Result {
        let added: [Bookmark]
        let skippedCount: Int
    }

    static func ingest(
        _ documents: [PreparedDroppedDocument],
        in context: ModelContext
    ) -> Result {
        guard !documents.isEmpty else { return Result(added: [], skippedCount: 0) }

        var knownAttachments = ((try? context.fetch(FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.deletedAt == nil }
        ))) ?? []).filter { $0.fileKind != nil && $0.fileData != nil }
        let rules = (try? context.fetch(FetchDescriptor<ClassificationRule>())) ?? []
        let categories = (try? context.fetch(FetchDescriptor<BookmarkCategory>())) ?? []
        let tags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        var added: [Bookmark] = []
        var skippedCount = 0

        for document in documents {
            if knownAttachments.contains(where: {
                $0.fileKind == document.kind && $0.fileData?.count == document.data.count
                    && $0.fileData == document.data
            }) {
                skippedCount += 1
                continue
            }

            let link = Bookmark(
                url: "",
                title: document.title,
                readingStatus: .inbox,
                platform: .local,
                contentType: document.kind == "video" ? .video : document.kind == "audio" ? .music : .document
            )
            link.siteName = switch document.kind {
            case "pdf": "PDF"
            case "epub": "EPUB"
            case "audio": "Audio"
            case "video": "Vídeo"
            default: "Imagen"
            }
            link.platformColor = Platform.local.brandColorHex
            link.source = "Finder"
            link.author = document.author
            link.fileData = document.data
            link.fileKind = document.kind
            context.insert(link)
            if !rules.isEmpty {
                ClassificationEngine.apply(
                    to: link,
                    rules: rules,
                    categories: categories,
                    tags: tags
                )
            }
            knownAttachments.append(link)
            added.append(link)
        }

        context.saveLogging("importar documentos desde Finder")
        for link in added { SpotlightIndexer.index(link) }

        // OCR/PDFKit/EPUB continúa aunque la animación del drop desaparezca. Se procesa en
        // serie y cede mientras hay interacción para no competir con el scroll.
        if !added.isEmpty {
            Task { @MainActor in
                for link in added where link.modelContext != nil && link.fileKind != "audio" && link.fileKind != "video" {
                    _ = try? await DocumentTextCoordinator.indexIfNeeded(
                        link,
                        in: context,
                        waitForIdle: true
                    )
                }
            }
        }
        return Result(added: added, skippedCount: skippedCount)
    }
}
