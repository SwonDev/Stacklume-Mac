import SwiftData
import SwiftUI
import StacklumeCore
import StacklumeDesignSystem
import StacklumePersistence

/// Bandeja de capturas pendientes. Es una vista enfocada del estado `.inbox` que ya
/// forma parte del modelo compartido; no crea una segunda fuente de verdad.
struct InboxView: View {
    @Binding var selectedLinks: Set<Bookmark.ID>

    @Environment(\.themePalette) private var palette
    @Query(filter: #Predicate<Bookmark> { $0.deletedAt == nil && !$0.isArchived },
           sort: \Bookmark.createdAt)
    private var activeLinks: [Bookmark]

    @State private var triageRequest: TriageRequest?

    private struct TriageRequest: Identifiable {
        let id = UUID()
        let linkIDs: [Bookmark.ID]
        let totalPendingAtStart: Int
    }

    private static let triageSessionLimit = 25

    private var pendingLinks: [Bookmark] {
        activeLinks.filter { $0.readingStatus == .inbox }
    }

    private var inboxFilter: LinkFilter {
        var filter = LinkFilter()
        filter.readingStatus = .inbox
        return filter
    }

    var body: some View {
        LibraryListView(
            title: "Bandeja",
            icon: "tray.full",
            emptyMessage: "No tienes capturas pendientes. Todo lo guardado ya tiene un siguiente paso.",
            baseFilter: inboxFilter,
            headerAction: pendingLinks.isEmpty ? nil : LibraryHeaderAction(
                title: "Revisar bandeja",
                systemImage: "checklist"
            ) {
                triageRequest = TriageRequest(
                    linkIDs: pendingLinks.prefix(Self.triageSessionLimit).map(\.id),
                    totalPendingAtStart: pendingLinks.count
                )
            },
            viewScope: NavTarget.inbox.key,
            selection: $selectedLinks
        )
        .sheet(item: $triageRequest) { request in
            InboxTriageView(linkIDs: request.linkIDs,
                            totalPendingAtStart: request.totalPendingAtStart)
                .themedSheet(palette)
        }
    }
}
