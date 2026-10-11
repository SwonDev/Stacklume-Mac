import Foundation
import Testing

@Suite("Metadatos Mac — frontera de adquisición automática")
struct MacMetadataBoundaryTests {
    @Test("Una URL privada conserva el fallback sin descargar contenido ni copia offline")
    func privateURL() async {
        let metadata = await MacMetadataService().fetchMetadata(for: "http://127.0.0.1:8080/articulo")
        #expect(metadata.title != nil)
        #expect(metadata.details == nil)
        #expect(await MacOfflineCopyService.fetchReadable(url: "http://127.0.0.1:8080/articulo") == nil)
    }

    @Test("El lector reutiliza el texto plano público del paquete")
    func offlineTextCompatibility() {
        #expect(MacOfflineCopyService.plainText(from: "<p>Texto &amp; lectura</p>") == "Texto & lectura")
    }
}
