import Foundation
import Testing
import ZIPFoundation

@Suite("EPUBDocumentReader — libros locales seguros")
struct EPUBDocumentReaderTests {
    @Test("Extrae metadatos y capítulos en el orden del spine")
    func extractsMetadataAndSpineOrder() throws {
        let data = try makeEPUB()

        let metadata = try EPUBDocumentReader.metadata(data: data)
        let publication = try EPUBDocumentReader.extract(data: data)

        #expect(metadata.title == "La biblioteca privada")
        #expect(metadata.author == "Ada Local")
        #expect(publication.chapters.map(\.title) == ["Primero", "Segundo"])
        #expect(publication.chapters[0].text.contains("contenido inicial"))
        #expect(publication.chapters[0].text.contains("nunca debe aparecer") == false)
        #expect(publication.sourceChapterCount == 2)
        #expect(publication.wasTruncated == false)
    }

    @Test("Integra el EPUB en el índice de documentos locales")
    func integratesWithDocumentTextExtractor() async throws {
        let result = try await DocumentTextExtractor.extract(data: makeEPUB(), kind: "epub")

        #expect(result.text.contains("contenido inicial"))
        #expect(result.text.contains("contenido final"))
        #expect(result.totalPageCount == 2)
        #expect(result.recognizedPageCount == 2)
        #expect(result.usedOCR == false)
    }

    @Test("Rechaza rutas traversal aunque no se extraigan al disco")
    func rejectsPathTraversal() throws {
        let data = try makeEPUB(extraEntries: ["../escape.xhtml": "contenido hostil"])

        #expect(throws: EPUBDocumentError.unsafeArchive) {
            try EPUBDocumentReader.validate(data: data)
        }
    }

    @Test("Rechaza un ZIP renombrado a EPUB")
    func rejectsWrongMimetype() throws {
        let data = try makeEPUB(mimetype: "application/zip")

        #expect(throws: EPUBDocumentError.invalidPackage) {
            try EPUBDocumentReader.validate(data: data)
        }
    }

    @Test("Rechaza declaraciones XML con entidades")
    func rejectsUnsafeXMLDeclarations() throws {
        let data = try makeEPUB(packagePrefix: "<!DOCTYPE package [<!ENTITY x \"expansión\">]>")

        #expect(throws: EPUBDocumentError.invalidPackage) {
            try EPUBDocumentReader.validate(data: data)
        }
    }

    @Test("No expande entidades declaradas dentro de un capítulo")
    func doesNotExpandChapterEntities() throws {
        let chapter = """
        <!DOCTYPE html [<!ENTITY repeat "contenido expandido">]>
        <html><body><h1>Seguro</h1><p>&repeat;&repeat;&repeat;</p></body></html>
        """
        let publication = try EPUBDocumentReader.extract(data: makeEPUB(firstChapter: chapter))

        #expect(publication.chapters[0].text.contains("contenido expandido") == false)
        #expect(publication.chapters[0].text.count < 1_000)
    }

    private func makeEPUB(
        mimetype: String = "application/epub+zip",
        packagePrefix: String = "",
        firstChapter: String? = nil,
        extraEntries: [String: String] = [:]
    ) throws -> Data {
        let archive = try Archive(accessMode: .create)
        try add(mimetype, at: "mimetype", to: archive, compression: .none)
        try add(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """,
            at: "META-INF/container.xml",
            to: archive
        )
        try add(
            """
            \(packagePrefix)
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>La biblioteca privada</dc:title>
                <dc:creator>Ada Local</dc:creator>
              </metadata>
              <manifest>
                <item id="c2" href="Text/segundo.xhtml" media-type="application/xhtml+xml"/>
                <item id="c1" href="Text/primero.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine>
                <itemref idref="c1"/>
                <itemref idref="c2"/>
              </spine>
            </package>
            """,
            at: "OEBPS/content.opf",
            to: archive
        )
        try add(
            firstChapter ?? """
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Ignorado</title></head>
            <body><h1>Primero</h1><p>Este es el contenido inicial.</p>
            <script>Este texto nunca debe aparecer.</script></body></html>
            """,
            at: "OEBPS/Text/primero.xhtml",
            to: archive
        )
        try add(
            """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
            <h2>Segundo</h2><p>Este es el contenido final.</p></body></html>
            """,
            at: "OEBPS/Text/segundo.xhtml",
            to: archive
        )
        for (path, contents) in extraEntries {
            try add(contents, at: path, to: archive)
        }
        guard let data = archive.data else { throw EPUBDocumentError.invalidArchive }
        return data
    }

    private func add(
        _ string: String,
        at path: String,
        to archive: Archive,
        compression: CompressionMethod = .deflate
    ) throws {
        let data = Data(string.utf8)
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: compression
        ) { position, size in
            let start = Int(position)
            return data.subdata(in: start..<min(data.count, start + size))
        }
    }
}
