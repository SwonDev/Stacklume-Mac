import Foundation
import SwiftData
import StacklumeMetadata

/// Coordina el enriquecido de metadatos en primer plano para que NO se lance por
/// duplicado: varias listas de la biblioteca disparan su `.task` al aparecer, así que
/// al navegar entre ellas se ejecutarían varias pasadas de red a la vez. Aquí se acota
/// a una pasada por ventana de tiempo.
///
/// Portado del iPhone (allí también vive en el app target, no en un paquete
/// compartido), porque solo `BatchEnricher` (enriquecido de metadatos de red SIN IA)
/// vive en el paquete compartido `StacklumeMetadata`; el coordinador que evita los
/// disparos duplicados es código de la app. No se duplica `BatchEnricher`.
@MainActor
enum EnrichCoordinator {
    private static var lastRun: Date?
    private static var running = false

    /// Ejecuta el enriquecido solo si no hay otro en curso y ha pasado `minInterval`
    /// desde el último. Pensado para los `.task` de aparición de vistas.
    static func runIfNeeded(in context: ModelContext, minInterval: TimeInterval = 120) async {
        if running { return }
        if let last = lastRun, Date().timeIntervalSince(last) < minInterval { return }
        running = true
        defer { running = false }
        // No empieces (ni hagas el fetch inicial O(n)) mientras el usuario interactúa, y cede el
        // paso entre enlaces: el enriquecido de red escribe en SwiftData e invalidaría la lista
        // en pleno scroll → entrecortes. Avanza en cuanto hay una pausa.
        await UserActivityMonitor.shared.waitUntilIdle()
        if Task.isCancelled { return }
        await MacBatchEnricher.enrich(
            in: context,
            pauseIfBusy: { await UserActivityMonitor.shared.waitUntilIdle() },
            // Libro mayor: no reprocesar en cada ronda los enlaces ya intentados (incompletos que
            // no mejoran) — eso re-`autoOrganize`ba y su escritura invalidaba el @Query → hitch.
            shouldSkip: { EnrichmentLedger.hasNetworkAttempt($0.id) },
            onProcessed: { EnrichmentLedger.markNetworkAttempt($0.id) })
        if !Task.isCancelled { lastRun = Date() }
    }
}
