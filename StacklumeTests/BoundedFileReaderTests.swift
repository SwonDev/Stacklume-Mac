import Foundation
import Testing

@Suite("BoundedFileReader — lectura incremental")
struct BoundedFileReaderTests {
    @Test("Lee hasta el límite exacto")
    func readsAtExactLimit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacklume-bounded-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("seguro".utf8).write(to: url)

        #expect(try BoundedFileReader.read(url, maximumBytes: 6) == Data("seguro".utf8))
    }

    @Test("Rechaza al detectar un byte por encima de la cota")
    func rejectsOversizedFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacklume-bounded-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("demasiado".utf8).write(to: url)

        #expect(throws: BoundedFileReadError.tooLarge(maximumBytes: 4)) {
            try BoundedFileReader.read(url, maximumBytes: 4)
        }
    }
}
