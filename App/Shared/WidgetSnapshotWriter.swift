import Foundation
import SwiftData
import StacklumeCore
import WidgetKit

/// Escribe el snapshot de favoritos para el widget de escritorio.
/// La app lo llama tras arrancar y tras cualquier cambio en favoritos.
@MainActor
enum WidgetSnapshotWriter {
    static func write(from context: ModelContext) {
        var descriptor = FetchDescriptor<Bookmark>(
            predicate: #Predicate {
                $0.deletedAt == nil && $0.isFavorite && !$0.isArchived
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 8
        let links = (try? context.fetch(descriptor)) ?? []

        let items = links.map { link in
            WidgetSnapshot.Item(
                id: link.id.uuidString,
                title: link.title.isEmpty
                    ? (URL(string: link.url)?.host() ?? link.url)
                    : link.title,
                host: URL(string: link.url)?.host()?
                    .replacingOccurrences(of: "www.", with: "") ?? "",
                colorHex: link.platformColor ?? link.platform.brandColorHex)
        }

        WidgetSnapshot(favorites: items, generatedAt: Date()).save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
