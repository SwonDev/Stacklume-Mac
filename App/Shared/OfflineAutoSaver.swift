import Foundation
import SwiftData
import StacklumeCore
import StacklumeMetadata

/// Guardado de la COPIA SIN CONEXIÓN en automático (opcional, DESACTIVADO por defecto).
///
/// Cuando el usuario activa el ajuste `stacklume.autoOffline`, descarga en segundo plano
/// la copia legible de los enlaces que aún no la tienen, de pocos en pocos, para no
/// saturar la red ni llenar el disco de golpe. Reutiliza `OfflineCopyService` (el MISMO
/// extractor que el guardado manual del detalle); no se duplica esa infraestructura.
///
/// El RITMO lo marca quien lo llama: un bucle en la ventana (lifecycle estable) lo invoca
/// cada minuto. Se cuelga de la VENTANA y no de la lista a propósito: el `.task` de la
/// lista se cancela al navegar entre secciones y abortaba las descargas a medias.
///
/// Por defecto está apagado porque guardar la copia de toda la biblioteca puede ocupar
/// bastante disco: lo decide el usuario.
@MainActor
enum OfflineAutoSaver {
    /// Clave del ajuste (opt-in). Sin valor guardado ⇒ `false` (desactivado).
    static let defaultsKey = "stacklume.autoOffline"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    private static var running = false
    /// Copias por pasada: el resto se va guardando en pasadas sucesivas (no de golpe).
    private static let perPass = 6
    /// Enlaces ya tratados en ESTA sesión (con copia, recién guardada o sin copia útil):
    /// se saltan en pasadas posteriores sin volver a materializar su copia (que es de
    /// almacenamiento externo). Evita un re-escaneo O(n²) al barrer la biblioteca.
    private static var handled: Set<UUID> = []

    /// Si la opción está activa y no hay otra pasada en curso, guarda la copia de unos
    /// cuantos enlaces sin ella. Idempotente y barato cuando está desactivado (return).
    static func runIfNeeded(in context: ModelContext) async {
        guard isEnabled, !running else { return }
        running = true
        defer { running = false }
        await saveMissing(in: context)
    }

    /// Descarga la copia de hasta `perPass` enlaces activos SIN copia (más recientes
    /// primero). `offlineHTML` es de almacenamiento externo, así que NO se puede filtrar
    /// con `#Predicate`: se recorren los activos y se descartan en memoria los que ya la
    /// tienen (con el cursor `handled` para no recargar la copia en pasadas sucesivas).
    /// Errores de red se ignoran: ese enlace, ya marcado, se reintentará en otra SESIÓN
    /// (al reiniciar se vacía el cursor), evitando reintentos infinitos de URLs sin copia.
    private static func saveMissing(in context: ModelContext) async {
        await UserActivityMonitor.shared.waitUntilIdle()
        if Task.isCancelled { return }
        let descriptor = FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        guard let active = try? context.fetch(descriptor), !active.isEmpty else { return }
        var saved = 0
        for link in active {
            if Task.isCancelled || saved >= perPass { break }
            await UserActivityMonitor.shared.waitUntilIdle()   // cede mientras el usuario interactúa
            if Task.isCancelled { break }
            let id = link.id
            if handled.contains(id) { continue }
            guard link.modelContext != nil else { continue }
            // Ya tiene copia: márcalo tratado y sigue (no se vuelve a materializar).
            if let existing = link.offlineHTML, !existing.isEmpty { handled.insert(id); continue }
            let url = link.url
            handled.insert(id)
            guard let publicURL = StacklumeAutomationPolicy.openableStoredURL(url),
                  StacklumeAutomationPolicy.allowsAutomaticNetworkURL(publicURL),
                  let host = publicURL.host(),
                  await Task.detached(priority: .utility, operation: {
                      AssistantHostResolver.hasOnlyPublicAddresses(host)
                  }).value else { continue }
            guard let html = await MacOfflineCopyService.fetchReadable(url: url), !html.isEmpty else { continue }
            link.offlineHTML = html
            link.offlineText = OfflineCopyService.plainText(from: html)
            link.updatedAt = Date()
            saved += 1
        }
        if saved > 0 { context.saveLogging() }
    }
}
