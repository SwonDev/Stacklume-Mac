import Foundation
import SwiftData
import StacklumeCore

/// Restablecimiento total de la biblioteca: borra DEFINITIVAMENTE todo el contenido
/// del usuario para empezar de cero, conservando solo las preferencias (`AppSettings`:
/// tema, idioma, ajustes). Pensado para reutilizar la app desde cero, sin enlaces,
/// colecciones, etiquetas ni nada.
@MainActor
enum LibraryReset {
    /// Borra todos los modelos de contenido y limpia los índices/derivados:
    /// enlaces, colecciones, etiquetas, proyectos, sesiones, reglas de clasificación,
    /// resaltados, stickers, widgets del panel y apps seguidas. NO toca `AppSettings`.
    /// Limpia el índice de Spotlight y recarga los widgets. Devuelve cuántos enlaces
    /// se borraron.
    ///
    /// Usa fetch + `delete(_:)` por objeto + `save()` (NO `delete(model:)` por lotes):
    /// el borrado por lotes va directo al store y NO refresca los `@Query` en memoria
    /// hasta reiniciar; este patrón sí actualiza la UI al instante (igual que
    /// `MaintenanceSettingsView.emptyTrash`).
    @discardableResult
    static func wipeEverything(in context: ModelContext) throws -> Int {
        try LiquidConversation.discardAllForLibraryReset()
        return try LibraryResetIntent.performingReset {
        // Enlaces primero: su relación en cascada arrastra los resaltados asociados.
        let bookmarks = try context.fetch(FetchDescriptor<Bookmark>())
        let deletedCount = bookmarks.count
        for bookmark in bookmarks {
            ReminderService.cancel(id: bookmark.id)
            context.delete(bookmark)
        }

        try wipe(BookmarkCategory.self, in: context)
        try wipe(Tag.self, in: context)
        try wipe(Project.self, in: context)
        try wipe(LinkSession.self, in: context)
        try wipe(ClassificationRule.self, in: context)
        try wipe(DashboardWidget.self, in: context)
        try wipe(PlacedSticker.self, in: context)
        try wipe(Highlight.self, in: context)
        try wipe(TrackedApp.self, in: context)

        try context.save()

        // Retira también las claves heredadas para impedir una nueva migración.
        UserDefaults.standard.removeObject(forKey: "stacklume.liquidChat.sessions")
        UserDefaults.standard.removeObject(forKey: "stacklume.liquidChat.transcript")
        // Stores LATERALES (UserDefaults/disco, fuera de SwiftData): sin esto, «empezar de
        // cero» dejaría huérfanos notas de resaltados, progreso de lectura, portadas,
        // búsquedas guardadas, proyectos e insight de IA.
        HighlightNoteStore.removeAll()
        ReadingProgressStore.removeAll()
        VideoProgressStore.removeAll()
        WaybackStore.removeAll()
        CustomCoverStore.shared.removeAll()
        EnrichmentLedger.removeAll()
        UserEditLedger.removeAll()
        ConversationMemory.shared.removeAll()
        EntityGraph.shared.removeAll()
        UserDefaults.standard.removeObject(forKey: "stacklume.savedSearches")
        UserDefaults.standard.removeObject(forKey: ProjectWorkspaceStore.storageKey)
        UserDefaults.standard.removeObject(forKey: "stacklume.libraryInsight")
        UserDefaults.standard.removeObject(forKey: "stacklume.weeklyDigest")
        UserDefaults.standard.removeObject(forKey: "stacklume.recentSearches")
        StacklumeAutomationAuditLog.clear()

        // Derivados fuera de SwiftData: índice de búsqueda del sistema y widgets.
        SpotlightIndexer.clearAll()
        WidgetReloader.reload()

        return deletedCount
        }
    }

    /// Borra todas las instancias de un modelo, una a una (refresca los `@Query`).
    private static func wipe<T: PersistentModel>(_ type: T.Type, in context: ModelContext) throws {
        let objects = try context.fetch(FetchDescriptor<T>())
        for object in objects { context.delete(object) }
    }
}
