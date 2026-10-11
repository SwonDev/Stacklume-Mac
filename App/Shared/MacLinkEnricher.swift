import Foundation
import SwiftData
import StacklumeCore
import StacklumeMetadata

/// Mantiene el mapeo y la organización del paquete; solo cambia su frontera de red.
@MainActor
enum MacLinkEnricher {
    static func enrichFromNetwork(
        _ bookmark: Bookmark, in context: ModelContext, overwriteTitle: Bool = false
    ) async {
        guard bookmark.modelContext != nil, !Task.isCancelled else { return }
        let metadata = await MacMetadataService().fetchMetadata(for: bookmark.url)
        guard bookmark.modelContext != nil, !Task.isCancelled else { return }
        LinkEnricher.applyMetadata(metadata, to: bookmark, overwriteTitle: overwriteTitle)
        await MacPlatformEnricher.enrich(bookmark)
        guard bookmark.modelContext != nil, !Task.isCancelled else { return }
        LinkEnricher.autoOrganize(bookmark, in: context)
        context.saveLogging()
    }
}
