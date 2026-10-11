import Testing
import Foundation

// `NetscapeHTMLImporter` se compila dentro del módulo de tests. Verifica el parseo del
// HTML de marcadores CON jerarquía de carpetas (lo que lo diferencia del parser plano del
// paquete): cada enlace debe quedar asignado a su carpeta → colección.

@Suite("NetscapeHTMLImporter — HTML de marcadores con carpetas")
struct NetscapeHTMLImporterTests {

    // Export Netscape representativo: enlace raíz (sin carpeta), una carpeta con dos
    // enlaces, una subcarpeta anidada, una entidad HTML y un enlace no-http a descartar.
    private let sample = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <DL><p>
        <DT><A HREF="https://root.example.com">Raíz</A>
        <DT><H3>Desarrollo</H3>
        <DL><p>
            <DT><A HREF="https://github.com/colinhacks/zod" ADD_DATE="1700000000">Zod &amp; co</A>
            <DT><H3>Docs</H3>
            <DL><p>
                <DT><A HREF="https://developer.apple.com/swift/">Swift</A>
            </DL><p>
            <DT><A HREF="https://www.swift.org">Swift.org</A>
        </DL><p>
        <DT><A HREF="javascript:void(0)">No es enlace</A>
    </DL><p>
    """

    @Test("Extrae solo los enlaces http y descarta el resto")
    func extractsOnlyHTTP() {
        let items = NetscapeHTMLImporter.parse(sample)
        #expect(items.count == 4)   // raíz + zod + swift + swift.org (javascript: descartado)
        #expect(items.allSatisfy { $0.url.hasPrefix("http") })
    }

    @Test("Asigna cada enlace a su carpeta (colección)")
    func assignsFolders() {
        let items = NetscapeHTMLImporter.parse(sample)
        func folder(of host: String) -> String? {
            items.first { $0.url.contains(host) }?.folder
        }
        #expect(folder(of: "root.example.com") == "")            // raíz, sin carpeta
        #expect(folder(of: "github.com") == "Desarrollo")
        #expect(folder(of: "developer.apple.com") == "Docs")     // subcarpeta anidada
        #expect(folder(of: "swift.org") == "Desarrollo")         // tras cerrar la subcarpeta
    }

    @Test("Decodifica entidades HTML del título")
    func decodesEntities() {
        let items = NetscapeHTMLImporter.parse(sample)
        #expect(items.first { $0.url.contains("github.com") }?.title == "Zod & co")
    }

    @Test("HTML vacío o sin enlaces ⇒ lista vacía (no rompe)")
    func emptyInput() {
        #expect(NetscapeHTMLImporter.parse("").isEmpty)
        #expect(NetscapeHTMLImporter.parse("<html><body>sin marcadores</body></html>").isEmpty)
    }
}
