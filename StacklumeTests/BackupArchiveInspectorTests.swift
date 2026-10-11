import Foundation
import Testing

@Suite("BackupArchiveInspector — recuperación segura")
struct BackupArchiveInspectorTests {
    @Test("Distingue una copia válida vacía de un JSON corrupto")
    func validatesArchive() {
        #expect(BackupArchiveInspector.linkCount(in: Data(#"{"links":[]}"#.utf8)) == 0)
        #expect(BackupArchiveInspector.linkCount(in: Data("no es JSON".utf8)) == nil)
        #expect(BackupArchiveInspector.linkCount(in: Data(#"{"otraClave":[]}"#.utf8)) == nil)
    }

    @Test("Mapea el UUID remoto al UUID nuevo creado durante la fusión")
    func mapsNewLocalIdentifier() {
        let remoteID = UUID()
        let localID = UUID()
        let data = archive(id: remoteID, url: "https://example.com/articulo")

        let map = BackupArchiveInspector.localIDMap(
            from: data,
            localLinks: [BackupLinkIdentity(id: localID, url: "https://example.com/articulo")])

        #expect(map[remoteID] == localID)
    }

    @Test("Encuentra un enlace preexistente aunque esquema, www y tracking difieran")
    func mapsCanonicalPreexistingLink() {
        let remoteID = UUID()
        let existingID = UUID()
        let data = archive(
            id: remoteID,
            url: "http://www.example.com/articulo?utm_source=backup")

        let map = BackupArchiveInspector.localIDMap(
            from: data,
            localLinks: [BackupLinkIdentity(id: existingID, url: "https://example.com/articulo")])

        #expect(map[remoteID] == existingID)
    }

    @Test("Un archivo inválido no produce asociaciones espurias")
    func invalidArchiveMapsNothing() {
        let map = BackupArchiveInspector.localIDMap(
            from: Data("{}".utf8),
            localLinks: [BackupLinkIdentity(id: UUID(), url: "https://example.com")])
        #expect(map.isEmpty)
    }

    @Test("No mezcla varios adjuntos que comparten URL vacía")
    func doesNotMapEmptyAttachmentURLs() {
        let firstRemote = UUID()
        let secondRemote = UUID()
        let data = Data(#"{"links":[{"id":"\#(firstRemote.uuidString)","url":""},{"id":"\#(secondRemote.uuidString)","url":""}]}"#.utf8)

        let map = BackupArchiveInspector.localIDMap(
            from: data,
            localLinks: [BackupLinkIdentity(id: UUID(), url: "")]
        )

        #expect(map.isEmpty)
    }

    private func archive(id: UUID, url: String) -> Data {
        Data(#"{"links":[{"id":"\#(id.uuidString)","url":"\#(url)"}]}"#.utf8)
    }
}
