import Foundation
import SwiftData
import StacklumeCore

/// Mutaciones de un enlace, centralizadas para fila, ficha y menús.
enum BookmarkActions {
    static func toggleFavorite(_ link: Bookmark, in context: ModelContext) {
        link.isFavorite.toggle(); link.updatedAt = Date(); context.saveLogging()
    }
    static func toggleArchive(_ link: Bookmark, in context: ModelContext) {
        link.isArchived.toggle(); link.updatedAt = Date(); context.saveLogging()
    }
    /// Alterna el indicador «leído» (campo `isRead`, independiente de `readingStatus`).
    static func toggleRead(_ link: Bookmark, in context: ModelContext) {
        link.isRead.toggle(); link.updatedAt = Date(); context.saveLogging()
    }
    /// Fija el estado de la cola de lectura (pendiente/leyendo/leído). `isRead`
    /// se mantiene como campo independiente (igual que el iPhone: el editor solo
    /// toca `readingStatus`; marcar como leído se hace al abrir el enlace).
    static func setReadingStatus(_ status: ReadingStatus, for link: Bookmark, in context: ModelContext) {
        guard link.readingStatus != status else { return }
        link.readingStatus = status; link.updatedAt = Date(); context.saveLogging()
    }
    /// Completa el flujo de lectura de forma coherente: el estado Kanban y el indicador
    /// binario quedan marcados como leídos en un único guardado.
    static func markReadingDone(_ link: Bookmark, in context: ModelContext) {
        guard link.readingStatus != .done || !link.isRead else { return }
        link.readingStatus = .done
        link.isRead = true
        link.updatedAt = Date()
        context.saveLogging()
        WidgetReloader.reload()
    }
    /// Programa (o quita, con `nil`) la fecha de REPASO: cuándo debe RESURGIR el enlace para que lo
    /// revises. Usa el campo `reviewAt` (que existía sin usar). Es el «resurfacing» del segundo
    /// cerebro: a diferencia del recordatorio (`reminderAt`, con notificación), esto solo lo hace
    /// reaparecer en «Para repasar» de Estadísticas, sin avisar.
    static func setReviewDate(_ date: Date?, for link: Bookmark, in context: ModelContext) {
        link.reviewAt = date; link.updatedAt = Date(); context.saveLogging()
    }
    /// Crea un resaltado (cita) en un enlace a partir de texto —p. ej. el seleccionado
    /// en el lector—. Centraliza la inserción del modelo compartido `Highlight` para no
    /// duplicar la lógica de creación (editor manual, extracción con IA, selección en el
    /// lector). Evita insertar dos veces el MISMO fragmento (doble clic/selección repetida).
    @MainActor
    @discardableResult
    static func addHighlight(text: String, colorHex: String, to link: Bookmark, in context: ModelContext) -> Highlight? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if link.highlights.contains(where: { $0.text == clean }) { return nil }
        let highlight = Highlight(text: clean, colorHex: colorHex, bookmark: link)
        context.insert(highlight)
        link.updatedAt = Date()
        context.saveLogging()
        return highlight
    }

    /// Papelera: borrado lógico recuperable.
    @MainActor
    static func moveToTrash(_ link: Bookmark, in context: ModelContext) {
        link.deletedAt = Date(); context.saveLogging()
        SpotlightIndexer.remove(id: link.id)
    }
    @MainActor
    static func restore(_ link: Bookmark, in context: ModelContext) {
        link.deletedAt = nil; context.saveLogging()
        SpotlightIndexer.index(link)
    }
    /// Eliminación definitiva.
    @MainActor
    static func deleteForever(_ link: Bookmark, in context: ModelContext) {
        deleteForever([link], in: context)
    }

    /// Eliminación definitiva en lote: limpia todos los side-stores y guarda SwiftData una vez.
    @MainActor
    static func deleteForever(_ links: [Bookmark], in context: ModelContext) {
        let live = links.filter { $0.modelContext != nil }
        guard !live.isEmpty else { return }
        let ids = live.map(\.id)
        let urls = live.map(\.url)
        let highlightIDs = live.flatMap { $0.highlights.map(\.id) }

        for link in live {
            ReminderService.cancel(id: link.id)
            SpotlightIndexer.remove(id: link.id)
            CustomCoverStore.shared.remove(for: link.id)
            XPostDraftStore.remove(link.id)
        }
        HighlightNoteStore.remove(highlightIDs)
        ReadingProgressStore.remove(forURLs: urls)
        VideoProgressStore.remove(forURLs: urls)
        EnrichmentLedger.remove(ids)
        UserEditLedger.remove(ids)
        for link in live { context.delete(link) }
        context.saveLogging()
        WidgetReloader.reload()
    }

    // MARK: - Acciones en lote (multiselección)

    /// Acciones masivas sobre un conjunto de enlaces (resueltos por id). Reutilizan la
    /// misma semántica que las individuales pero guardan UNA sola vez al final (eficaz
    /// con muchas filas) y reconcilian Spotlight + widgets. Paridad con el iPhone
    /// (`bulkFavorite`/`bulkSetCategory`/`bulkAddTag`/`bulkDelete`).

    /// Marca o desmarca como favorito todos los enlaces. Si TODOS ya son favoritos, los
    /// quita; si no, los marca (toggle coherente del grupo, como el iPhone).
    @MainActor
    static func bulkSetFavorite(_ links: [Bookmark], in context: ModelContext) {
        guard !links.isEmpty else { return }
        let allFavorite = links.allSatisfy(\.isFavorite)
        let now = Date()
        for link in links { link.isFavorite = !allFavorite; link.updatedAt = now }
        context.saveLogging()
        WidgetReloader.reload()
    }

    /// Marca como leídos o no leídos todos los enlaces. Si TODOS ya están leídos, los
    /// marca como NO leídos; si no, los marca como leídos (toggle coherente del grupo,
    /// igual semántica que `toggleRead` individual).
    @MainActor
    static func bulkSetRead(_ links: [Bookmark], in context: ModelContext) {
        guard !links.isEmpty else { return }
        let allRead = links.allSatisfy(\.isRead)
        let now = Date()
        for link in links { link.isRead = !allRead; link.updatedAt = now }
        context.saveLogging()
        WidgetReloader.reload()
    }

    /// Fija el estado de lectura de un lote con un único guardado. Se usa al vaciar
    /// la Bandeja: varios pendientes pueden pasar juntos a «Leyendo» sin I/O por fila.
    @MainActor
    static func bulkSetReadingStatus(_ status: ReadingStatus, for links: [Bookmark],
                                     in context: ModelContext) {
        let changed = links.filter { $0.readingStatus != status }
        guard !changed.isEmpty else { return }
        let now = Date()
        for link in changed {
            link.readingStatus = status
            link.updatedAt = now
        }
        context.saveLogging()
        WidgetReloader.reload()
    }

    /// Archiva o desarchiva todos los enlaces. Si TODOS ya están archivados, los
    /// desarchiva; si no, los archiva (toggle coherente del grupo).
    @MainActor
    static func bulkSetArchive(_ links: [Bookmark], in context: ModelContext) {
        guard !links.isEmpty else { return }
        let allArchived = links.allSatisfy(\.isArchived)
        let now = Date()
        for link in links { link.isArchived = !allArchived; link.updatedAt = now }
        context.saveLogging()
        WidgetReloader.reload()
    }

    /// Mueve todos los enlaces a una colección (`category`); `nil` = quitar de toda
    /// colección («Sin clasificar»).
    @MainActor
    static func bulkSetCategory(_ category: BookmarkCategory?, for links: [Bookmark], in context: ModelContext) {
        guard !links.isEmpty else { return }
        let now = Date()
        for link in links {
            link.category = category; link.updatedAt = now
            LinkIngest.userChangedOrganization(link.id)
        }
        context.saveLogging()
        WidgetReloader.reload()
    }

    /// Añade una etiqueta a todos los enlaces sin duplicarla (si un enlace ya la tiene,
    /// se omite).
    @MainActor
    static func bulkAddTag(_ tag: Tag, to links: [Bookmark], in context: ModelContext) {
        guard !links.isEmpty else { return }
        let now = Date()
        for link in links where !link.tags.contains(where: { $0.id == tag.id }) {
            link.tags.append(tag)
            LinkIngest.userChangedOrganization(link.id)
            link.updatedAt = now
        }
        context.saveLogging()
    }

    /// Quita una etiqueta de todos los enlaces que la tengan (reorganización en lote).
    @MainActor
    static func bulkRemoveTag(_ tag: Tag, from links: [Bookmark], in context: ModelContext) {
        guard !links.isEmpty else { return }
        let now = Date()
        for link in links where link.tags.contains(where: { $0.id == tag.id }) {
            link.tags.removeAll { $0.id == tag.id }
            LinkIngest.userChangedOrganization(link.id)
            link.updatedAt = now
        }
        context.saveLogging()
    }

    /// Envía todos los enlaces a la papelera (borrado lógico) y los retira de Spotlight.
    @MainActor
    static func bulkMoveToTrash(_ links: [Bookmark], in context: ModelContext) {
        guard !links.isEmpty else { return }
        let now = Date()
        for link in links { link.deletedAt = now }
        context.saveLogging()
        for link in links { SpotlightIndexer.remove(id: link.id) }
        WidgetReloader.reload()
    }
}
