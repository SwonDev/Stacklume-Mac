import Foundation
import Testing

@Suite("Red — espera de proveedor sin reintentos masivos")
struct HTTPRateLimitStateTests {
    private let now = Date(timeIntervalSince1970: 100)

    @Test("Retry-After en segundos y fecha HTTP")
    func formats() {
        #expect(HTTPRateLimitState.waitDuration(retryAfter: "120", now: now) == 120)
        #expect(HTTPRateLimitState.waitDuration(retryAfter: "Thu, 01 Jan 1970 00:03:40 GMT", now: now) == 120)
    }

    @Test("No se mantiene un 429 al alcanzar la fecha límite")
    func exactDeadline() {
        var state = HTTPRateLimitState()
        state.record(host: "example.com", retryAfter: "5", now: now)
        let beforeDeadline = state.isCoolingDown(host: "example.com", now: now.addingTimeInterval(4.999))
        let atDeadline = state.isCoolingDown(host: "example.com", now: now.addingTimeInterval(5))
        #expect(beforeDeadline)
        #expect(!atDeadline)
        #expect(state.deadlines.isEmpty)
    }

    @Test("Cada host mantiene su espera y los resultados concurrentes no la acortan")
    func independentHosts() {
        var state = HTTPRateLimitState()
        state.record(host: "EXAMPLE.com", retryAfter: "120", now: now)
        state.record(host: "example.com", retryAfter: "1", now: now)
        let firstHost = state.isCoolingDown(host: "example.com", now: now.addingTimeInterval(60))
        let otherHost = state.isCoolingDown(host: "another.example", now: now)
        #expect(firstHost)
        #expect(!otherHost)
    }

    @Test("Cabeceras inválidas tienen espera acotada y una fecha pasada no bloquea")
    func invalidHeaders() {
        #expect(HTTPRateLimitState.waitDuration(retryAfter: nil, now: now) == 60)
        #expect(HTTPRateLimitState.waitDuration(retryAfter: "infinito", now: now) == 60)
        #expect(HTTPRateLimitState.waitDuration(retryAfter: "-1", now: now) == 60)
        #expect(HTTPRateLimitState.waitDuration(retryAfter: "1e3", now: now) == 60)
        #expect(HTTPRateLimitState.waitDuration(retryAfter: "9999999999", now: now) == 86_400)
        #expect(HTTPRateLimitState.waitDuration(retryAfter: "Thu, 01 Jan 1970 00:00:00 GMT", now: now) == 0)
    }

    @Test("El cliente real respeta cancelación antes de resolver DNS o adquirir")
    func cancelledClient() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await ExternalHTTPClient.shared.data(for: URLRequest(url: URL(string: "https://example.com/cover.png")!), maximumBytes: 100)
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }
        #expect(await task.value)
    }

    @Test("El estado de espera está acotado y purga fechas vencidas")
    func boundedState() {
        var state = HTTPRateLimitState()
        for i in 0...HTTPRateLimitState.maximumHosts {
            state.record(host: "\(i).example.com", retryAfter: "5", now: now)
        }
        #expect(state.deadlines.count == HTTPRateLimitState.maximumHosts)
        state.record(host: "current.example.com", retryAfter: "10", now: now.addingTimeInterval(6))
        #expect(state.deadlines.count == 1)
    }
}
