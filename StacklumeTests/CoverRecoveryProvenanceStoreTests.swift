import Foundation
import Testing

@Suite("Portadas — procedencia lateral privada")
@MainActor
struct CoverRecoveryProvenanceStoreTests {
    private func entry(reference: String = "http://example.com/original.png") -> CoverRecoveryProvenanceStore.Entry {
        .init(referenceURL: reference, pageURL: "https://example.com/article", recoveredImageURL: "https://example.com/new.png", recoveredAt: Date(timeIntervalSince1970: 100), coverJPEGDigest: String(repeating: "a", count: 64))
    }

    @Test("La procedencia conserva las URLs exactas y se recupera de disco")
    func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("provenance.json")
        let store = CoverRecoveryProvenanceStore(fileURL: path)
        let id = UUID()
        #expect(store.record(entry(), for: id))
        let restored = CoverRecoveryProvenanceStore(fileURL: path)
        #expect(restored.entry(for: id) == entry())
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test("Un archivo dañado se conserva y no acepta sobrescrituras")
    func corruptedFilePreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("provenance.json")
        let original = Data("contenido dañado que hay que conservar".utf8)
        try original.write(to: path)
        let store = CoverRecoveryProvenanceStore(fileURL: path)
        #expect(!store.record(entry(), for: UUID()))
        #expect(try Data(contentsOf: path) == original)
    }

    @Test("La purga elimina solo los UUID desaparecidos")
    func pruneOrphans() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CoverRecoveryProvenanceStore(fileURL: directory.appendingPathComponent("provenance.json"))
        let kept = UUID(), removed = UUID()
        #expect(store.record(entry(), for: kept))
        #expect(store.record(entry(), for: removed))
        #expect(store.prune(keeping: [kept]))
        #expect(store.entry(for: kept) != nil)
        #expect(store.entry(for: removed) == nil)
    }

    @Test("Una procedencia con destino privado no se importa")
    func unsafeProvenance() {
        let unsafe = CoverRecoveryProvenanceStore.Entry(referenceURL: "http://example.com/original.png", pageURL: "https://example.com/article", recoveredImageURL: "https://127.0.0.1/new.png", recoveredAt: Date(), coverJPEGDigest: String(repeating: "a", count: 64))
        #expect(!unsafe.isValid)
    }
}
