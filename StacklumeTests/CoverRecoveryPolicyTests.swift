import Foundation
import Testing

@Suite("Portadas — adquisición de referencias conservadas")
@MainActor
struct CoverRecoveryPolicyTests {
    @Test("Una URL presente sin bytes se adquiere")
    func missingBytes() async {
        var acquired: [URL] = []
        let url = URL(string: "https://example.com/cover.png")!
        let result = await CoverRecoveryPolicy.recover(reference: url.absoluteString, stored: { _ in false }, acquire: {
            acquired.append($0)
            return true
        })
        #expect(result == .acquired)
        #expect(acquired == [url])
    }

    @Test("El original local se reutiliza antes de pedir la variante HD")
    func allLocalVariantsFirst() async {
        let original = "https://i.ytimg.com/vi/abc/hqdefault.jpg"
        var networkCalls = 0
        var localCalls: [String] = []
        let result = await CoverRecoveryPolicy.recover(reference: original, stored: {
            localCalls.append($0.absoluteString)
            return $0.absoluteString == original
        }, acquire: { _ in networkCalls += 1; return true })
        #expect(result == .stored)
        #expect(networkCalls == 0)
        #expect(localCalls.count == 2)
    }

    @Test("Un candidato HD fallido conserva la caída al original")
    func originalFallback() async {
        let original = "https://i.ytimg.com/vi/abc/hqdefault.jpg"
        var networkCalls: [String] = []
        let result = await CoverRecoveryPolicy.recover(reference: original, stored: { _ in false }, acquire: {
            networkCalls.append($0.absoluteString)
            return $0.absoluteString == original
        })
        #expect(result == .acquired)
        #expect(networkCalls == ["https://i.ytimg.com/vi/abc/maxresdefault.jpg", original])
    }

    @Test("HTTP sin bytes queda bloqueado, sin elevar ni reemplazar su referencia")
    func httpBlocked() async {
        let reference = "http://example.com/original.png"
        var networkCalls = 0
        let result = await CoverRecoveryPolicy.recover(reference: reference, stored: { _ in false }, acquire: { _ in
            networkCalls += 1
            return true
        })
        #expect(result == .unavailable)
        #expect(networkCalls == 0)
    }

    @Test("HTTP ya adquirido permanece disponible sin red")
    func legacyHTTPStored() async {
        let result = await CoverRecoveryPolicy.recover(reference: "http://example.com/original.png", stored: { _ in true }, acquire: { _ in
            Issue.record("La imagen local no requiere red")
            return false
        })
        #expect(result == .stored)
    }

    @Test("Un destino privado nunca llega a adquisición")
    func privateDestination() async {
        var calls = 0
        let result = await CoverRecoveryPolicy.recover(reference: "https://127.0.0.1/cover.png", stored: { _ in false }, acquire: { _ in calls += 1; return true })
        #expect(result == .unavailable)
        #expect(calls == 0)
    }

    @Test("La cancelación detiene la cascada antes del original")
    func cancellation() async {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await CoverRecoveryPolicy.recover(reference: "https://example.com/cover.png", stored: { _ in
                Issue.record("No se debe leer tras cancelar")
                return false
            }, acquire: { _ in
                Issue.record("No se debe adquirir tras cancelar")
                return false
            })
        }
        #expect(await task.value == .cancelled)
    }

    @Test("Referencias vacías no generan solicitudes")
    func absentReference() async {
        let result = await CoverRecoveryPolicy.recover(reference: nil, stored: { _ in true }, acquire: { _ in true })
        #expect(result == .unavailable)
    }
}
