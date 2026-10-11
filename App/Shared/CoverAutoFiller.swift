import Foundation
import CryptoKit
import SwiftData
import StacklumeCore

/// Adquisición AUTOMÁTICA de portadas en segundo plano (opt-out, ACTIVADO por defecto).
///
/// Algunos enlaces se quedaban sin imagen y había que pulsar «Obtener imagen» a mano: las
/// importaciones masivas (estrellas de GitHub, marcadores del navegador) llegan «completas»
/// —con su carpeta ya como colección—, así que el enriquecido por IA las SALTA (solo procesa
/// las que necesitan IA) y nunca pasaban por `CoverEnsurer`.
///
/// Este barrido recorre UNA VEZ POR SESIÓN los enlaces SIN portada y les asegura una con
/// `CoverEnsurer` (og:image/`<img>` hero → captura del hero renderizado), el MISMO punto único
/// que el alta. Reutiliza esa infraestructura; no la duplica. Serializado, acotado por sesión
/// y cancelable para no saturar; 100 % local, sin LLM. El usuario puede desactivarlo en
/// Ajustes › Datos. Se cuelga de la VENTANA (lifecycle estable), no de la lista, para que
/// navegar entre secciones no aborte el barrido a medias (igual criterio que [[OfflineAutoSaver]]).
@MainActor
enum CoverAutoFiller {
    /// Clave del ajuste (opt-out). Sin valor guardado ⇒ `true` (activado).
    static let defaultsKey = "stacklume.autoCover"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }

    private static var ranThisSession = false
    /// Tope por sesión: el resto se cubre en sesiones siguientes (no de golpe), para no abrir
    /// muchas capturas seguidas en bibliotecas grandes.
    private static let maxPerSession = 80
    private static let recoveryKey = "stacklume.coverReferenceRecovery.v2"

    private static func referenceDigest(_ reference: String) -> String {
        SHA256.hash(data: Data(reference.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Asegura portada para los enlaces activos que aún no la tienen. Una sola vez por sesión;
    /// idempotente y sin coste si está desactivado o ya corrió. Cancelable.
    static func runIfNeeded(in context: ModelContext) async {
        guard isEnabled, !ranThisSession else { return }
        ranThisSession = true
        // No compitas con la interacción: ni el fetch inicial ni las capturas (WKWebView/red).
        await UserActivityMonitor.shared.waitUntilIdle()
        if Task.isCancelled { ranThisSession = false; return }
        let descriptor = FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.deletedAt == nil && !$0.isArchived },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        guard let active = try? context.fetch(descriptor), !active.isEmpty else { return }
        // Conserva marcas de archivados y papelera; purga solo UUID que desaparecieron.
        guard let allLinks = try? context.fetch(FetchDescriptor<Bookmark>()) else { return }
        let liveIDs = Set(allLinks.map(\.id))
        let alive = Set(liveIDs.map(\.uuidString))
        CoverRecoveryProvenanceStore.shared.prune(keeping: liveIDs)
        var recovered = (UserDefaults.standard.dictionary(forKey: recoveryKey) as? [String: String] ?? [:])
            .filter { alive.contains($0.key) }
        UserDefaults.standard.set(recovered, forKey: recoveryKey)
        var attempted = 0
        var added = 0
        for link in active {
            if Task.isCancelled || attempted >= maxPerSession { break }
            await UserActivityMonitor.shared.waitUntilIdle()   // cede mientras el usuario interactúa
            if Task.isCancelled { break }
            guard link.modelContext != nil, link.deletedAt == nil, link.fileKind == nil,
                  !CustomCoverStore.shared.has(link.id) else { continue }
            if let reference = link.imageURL,
               !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let page = link.url
                let owner = link.modelContext
                let digest = referenceDigest(reference)
                guard recovered[link.id.uuidString] != digest else { continue }
                // La recuperación es una pasada por referencia: también respeta el fallo.
                // Una cancelación no consume el intento; el botón manual puede reintentar.
                attempted += 1
                let result = await CoverEnsurer.recoverReference(for: link)
                if result == .cancelled || Task.isCancelled { break }
                guard link.modelContext === owner, link.deletedAt == nil, link.fileKind == nil,
                      link.url == page, link.imageURL == reference,
                      !CustomCoverStore.shared.has(link.id) else { continue }
                var acquired = result == .acquired
                if result == .unavailable {
                    acquired = await CoverEnsurer.recoverFromPage(for: link, in: context)
                }
                if Task.isCancelled { break }
                if link.modelContext === owner, link.deletedAt == nil,
                   link.url == page, link.imageURL == reference {
                    recovered[link.id.uuidString] = digest
                    UserDefaults.standard.set(recovered, forKey: recoveryKey)
                }
                if result == .stored { attempted -= 1 }
                if acquired { added += 1 }
                try? await Task.sleep(for: .milliseconds(120))
                continue
            }
            // Salta los que YA se intentaron sin éxito en otra sesión
            // ([[EnrichmentLedger]]): un enlace sin portada obtenible no debe reintentarse (red +
            // captura WKWebView) cada vez que se abre la app. El redo es manual («Obtener imagen»).
            guard link.modelContext != nil, link.deletedAt == nil, !CoverEnsurer.hasCover(link),
                  !EnrichmentLedger.hasCoverAttempt(link.id) else { continue }
            let page = link.url
            let reference = link.imageURL
            let owner = link.modelContext
            guard let publicURL = StacklumeAutomationPolicy.openableStoredURL(link.url),
                  StacklumeAutomationPolicy.allowsAutomaticNetworkURL(publicURL),
                  let host = publicURL.host(),
                  await Task.detached(priority: .utility, operation: {
                      AssistantHostResolver.hasOnlyPublicAddresses(host)
                  }).value else {
                if Task.isCancelled { break }
                if link.modelContext === owner, link.deletedAt == nil, link.url == page, link.imageURL == reference {
                    EnrichmentLedger.markCoverAttempt(link.id)
                }
                continue
            }
            if Task.isCancelled { break }
            guard link.modelContext === owner, link.deletedAt == nil, link.url == page,
                  link.imageURL == reference, !CustomCoverStore.shared.has(link.id) else { continue }
            attempted += 1
            if await CoverEnsurer.ensure(for: link, in: context) { added += 1 }
            if Task.isCancelled { break }
            // Queda marcado como ya intentado (la encontrara o no), para no repetirlo en sesiones
            // futuras. (Si la encontró, `hasCover` ya lo excluiría; marcar siempre es inocuo.)
            if link.modelContext === owner, link.deletedAt == nil, link.url == page { EnrichmentLedger.markCoverAttempt(link.id) }
            // Cede entre enlaces: la captura del hero abre un WKWebView (CoverEnsurer ya las
            // serializa internamente); este respiro evita encadenarlas sin pausa.
            try? await Task.sleep(for: .milliseconds(120))
        }
        if Task.isCancelled { ranThisSession = false }
        if added > 0 { WidgetReloader.reload() }
    }
}
