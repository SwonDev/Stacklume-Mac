import Foundation
import SwiftData
import StacklumeCore

/// Punto único para escribir el resultado en SwiftData sin carreras ni trabajos duplicados.
@MainActor
enum DocumentTextCoordinator {
    private static var activeIDs: Set<UUID> = []

    static func indexIfNeeded(
        _ link: Bookmark,
        in context: ModelContext,
        waitForIdle: Bool
    ) async throws -> DocumentTextExtractionResult? {
        guard link.offlineText == nil else { return nil }
        return try await index(link, in: context, force: false, waitForIdle: waitForIdle)
    }

    static func reindex(
        _ link: Bookmark,
        in context: ModelContext
    ) async throws -> DocumentTextExtractionResult? {
        try await index(link, in: context, force: true, waitForIdle: false)
    }

    private static func index(
        _ link: Bookmark,
        in context: ModelContext,
        force: Bool,
        waitForIdle: Bool
    ) async throws -> DocumentTextExtractionResult? {
        guard link.modelContext != nil,
              let data = link.fileData,
              let kind = link.fileKind,
              force || link.offlineText == nil,
              activeIDs.insert(link.id).inserted else { return nil }
        defer { activeIDs.remove(link.id) }

        if waitForIdle {
            await UserActivityMonitor.shared.waitUntilIdle()
            try Task.checkCancellation()
        }
        let result = try await DocumentTextExtractor.extract(data: data, kind: kind)
        try Task.checkCancellation()
        guard link.modelContext != nil else { return result }

        // La cadena vacía es un resultado válido: evita reintentar automáticamente en
        // cada apertura cuando un documento realmente no contiene texto.
        link.offlineText = result.text
        link.updatedAt = Date()
        context.saveLogging()
        SpotlightIndexer.index(link)
        return result
    }
}
