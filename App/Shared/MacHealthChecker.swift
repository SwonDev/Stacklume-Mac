import Foundation
import SwiftData
import StacklumeCore
import StacklumeMetadata

/// Comprueba la salud de los enlaces (si responden o están rotos).
@MainActor
enum MacHealthChecker {

    static func check(_ link: Bookmark) async {
        link.lastCheckedAt = Date()
        let raw = link.url.contains("://") ? link.url : "https://" + link.url
        guard let url = URL(string: raw) else {
            link.healthStatus = .broken
            return
        }

        // 1) Intento con HEAD (ligero). Muchos servidores bloquean HEAD o responden
        //    403/401/429 a peticiones automáticas, así que NO lo tratamos como roto.
        if let status = await statusCode(for: url, method: "HEAD") {
            let verdict = Self.verdict(for: status)
            // Si HEAD sugiere "roto" pero no es un 404/410 claro, confirmamos con GET
            // (el servidor podría no admitir HEAD o estar bloqueando el método).
            if verdict == .broken, status != 404, status != 410 {
                if let getStatus = await statusCode(for: url, method: "GET") {
                    link.healthStatus = Self.verdict(for: getStatus)
                } else {
                    link.healthStatus = .ok
                }
            } else {
                link.healthStatus = verdict
            }
            return
        }

        // 2) HEAD no concluyó (rechazado o error de red): reintentamos con GET.
        if let getStatus = await statusCode(for: url, method: "GET") {
            link.healthStatus = Self.verdict(for: getStatus)
        } else {
            link.healthStatus = .timeout
        }
    }

    /// Veredicto conservador: SOLO "no encontrado / eliminado" cuenta como roto.
    /// 401/403/405/429 y 5xx significan que el recurso existe pero está restringido
    /// o el servidor falla temporalmente, no que el enlace esté roto.
    private static func verdict(for status: Int) -> HealthStatus {
        switch status {
        case 200...299: .ok
        case 300...399: .redirect
        case 404, 410:  .broken
        default:        .ok
        }
    }

    /// Devuelve el código de estado para una petición, o `nil` si falla la red.
    private static func statusCode(for url: URL, method: String) async -> Int? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 12
        // User-Agent de Safari real: evita bloqueos anti-bot que falseaban "roto".
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent")

        do {
            return try await ExternalHTTPClient.shared.response(
                for: request, acceptedStatusCodes: 100...599
            ).statusCode
        } catch ExternalHTTPError.unacceptableStatus(let status) {
            return status
        } catch {
            return nil
        }
    }

    @discardableResult
    static func checkAll(
        in context: ModelContext,
        limit: Int = 300,
        onProgress: @MainActor (Int, Int) -> Void = { _, _ in }
    ) async -> Int {
        let all = (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        let active = Array(all.filter { $0.deletedAt == nil }.prefix(limit))
        var done = 0
        for link in active {
            await check(link)
            done += 1
            onProgress(done, active.count)
        }
        try? context.save()
        return done
    }
}
