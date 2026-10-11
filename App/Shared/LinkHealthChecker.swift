import Foundation
import SwiftData
import StacklumeCore
import StacklumeMetadata

/// Planificador de fondo del comprobador de enlaces rotos (autodetectable). NO duplica el
/// sondeo —eso vive en `HealthChecker` (StacklumeMetadata), que ya hace HEAD/GET y es
/// conservador (401/403/5xx = vivo; 404/410 = roto)—. Aquí solo se decide QUÉ comprobar y
/// CUÁNDO: de forma incremental (los menos recientemente comprobados primero, así a lo largo
/// de varios arranques cubre toda la biblioteca y luego re-chequea cada semana) y SIN actuar
/// si el dispositivo está sin conexión (para no marcar nada por error).
@MainActor
enum LinkHealthMonitor {
    private static var running = false

    /// Comprueba un lote de los enlaces más «caducados». Devuelve cuántos se comprobaron.
    @discardableResult
    static func runIfNeeded(in context: ModelContext,
                            batchSize: Int = 25,
                            recheckAfter: TimeInterval = 7 * 24 * 3600) async -> Int {
        guard !running else { return 0 }
        running = true
        defer { running = false }

        let now = Date()
        let due = ((try? context.fetch(FetchDescriptor<Bookmark>())) ?? [])
            .filter {
                $0.deletedAt == nil
                    && !$0.isArchived
                    && StacklumeAutomationPolicy.openableStoredURL($0.url)
                        .map(StacklumeAutomationPolicy.allowsAutomaticNetworkURL) == true
            }
            .filter { ($0.lastCheckedAt.map { now.timeIntervalSince($0) >= recheckAfter }) ?? true }
            .sorted { ($0.lastCheckedAt ?? .distantPast) < ($1.lastCheckedAt ?? .distantPast) }
        let batch = Array(due.prefix(batchSize))
        guard !batch.isEmpty, await isOnline() else { return 0 }

        for link in batch {
            if Task.isCancelled { break }
            await UserActivityMonitor.shared.waitUntilIdle()   // cede mientras el usuario interactúa
            if Task.isCancelled { break }
            guard link.modelContext != nil else { continue }
            guard let url = StacklumeAutomationPolicy.openableStoredURL(link.url),
                  StacklumeAutomationPolicy.allowsAutomaticNetworkURL(url),
                  let host = url.host(),
                  await Task.detached(priority: .utility, operation: {
                      AssistantHostResolver.hasOnlyPublicAddresses(host)
                  }).value else { continue }
            await MacHealthChecker.check(link)   // reutiliza el sondeo del paquete
        }
        context.saveLogging()
        return batch.count
    }

    /// ¿Hay conexión? Petición de control a un endpoint estable; si falla por «sin red», se
    /// omite el barrido (evita falsos «rotos»/«timeouts» masivos por estar offline).
    nonisolated private static func isOnline() async -> Bool {
        guard let url = URL(string: "https://captive.apple.com/hotspot-detect.html") else { return true }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 8
        return (try? await ExternalHTTPClient.shared.response(
            for: req,
            acceptedStatusCodes: 100...599
        )) != nil
    }
}
