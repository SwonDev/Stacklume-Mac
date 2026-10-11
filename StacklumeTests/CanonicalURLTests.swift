import Testing
import Foundation

// `CanonicalURL` se compila dentro de este módulo de tests (añadido como fuente en
// project.yml). Verifica que se fusionan los enlaces que SON la misma página (esquema,
// www, barra final y parámetros de seguimiento) y NO los que apuntan a recursos distintos.

@Suite("CanonicalURL — clave de duplicados")
struct CanonicalURLTests {

    @Test("Civitai RED conserva la identidad de modelos y muestras")
    func civitaiRedResourceIdentity() {
        for path in ["models/1817671/wan-video?modelVersionId=2031179", "images/145055795"] {
            #expect(CanonicalURL.key("https://civitai.red/\(path)")
                    == CanonicalURL.key("https://civitai.com/\(path)"))
        }
        #expect(CanonicalURL.key("https://civitai.red/models/1817671?modelVersionId=1")
                != CanonicalURL.key("https://civitai.com/models/1817671?modelVersionId=2"))
        for path in ["", "models", "models/example", "collections/42", "user/autor"] {
            #expect(CanonicalURL.key("https://civitai.red/\(path)")
                    != CanonicalURL.key("https://civitai.com/\(path)"))
        }
        #expect(CanonicalURL.key("https://otro.civitai.red/models/1817671")
                != CanonicalURL.key("https://civitai.com/models/1817671"))
        #expect(CanonicalURL.key("https://civitai.com/models/1817671/wan-video?modelVersionId=2031179")
                == CanonicalURL.key("https://civitai.red/models/1817671?modelVersionId=2031179"))
        #expect(CanonicalURL.key("https://civitai.red/models/1817671/wan-video")
                == CanonicalURL.key("https://civitai.com/models/1817671"))
        #expect(CanonicalURL.key("https://civitai.com/models/1817671/otro-titulo")
                == CanonicalURL.key("https://civitai.com/models/1817671"))
        #expect(CanonicalURL.key("https://civitai.com/models/1817671/ruta/extra")
                != CanonicalURL.key("https://civitai.com/models/1817671"))
    }

    @Test("La deduplicación web excluye adjuntos y URLs vacías")
    func excludesLocalAttachments() {
        for kind in ["image", "pdf", "audio", "video", "epub"] {
            #expect(CanonicalURL.webBookmarkKey("", fileKind: kind) == nil)
            #expect(CanonicalURL.webBookmarkKey("https://example.com/file", fileKind: kind) == nil)
        }
        for invalid in ["", "  \n", "file:///tmp/a.pdf", "contenido local", "https://"] {
            #expect(CanonicalURL.webBookmarkKey(invalid, fileKind: nil) == nil)
        }
        #expect(CanonicalURL.webBookmarkKey("http://www.example.com/p/?utm_source=test", fileKind: nil)
                == CanonicalURL.key("https://example.com/p"))
        #expect(CanonicalURL.webBookmarkKey("https://example.com/p?id=1", fileKind: nil)
                != CanonicalURL.webBookmarkKey("https://example.com/p?id=2", fileKind: nil))
    }

    @Test("Pone esquema y host en minúsculas y conserva el path tal cual")
    func lowercasesSchemeAndHost() {
        #expect(CanonicalURL.key("HTTPS://GitHub.com/Owner/Repo") == "https://github.com/Owner/Repo")
    }

    @Test("Quita una única barra final del path")
    func dropsTrailingSlash() {
        #expect(CanonicalURL.key("https://x.com/a/") == "https://x.com/a")
    }

    @Test("Unifica http y https (mismo recurso)")
    func schemeUnified() {
        #expect(CanonicalURL.key("http://example.com/p") == CanonicalURL.key("https://example.com/p"))
    }

    @Test("Quita el prefijo www (mismo recurso)")
    func wwwStripped() {
        #expect(CanonicalURL.key("https://www.example.com/p") == CanonicalURL.key("https://example.com/p"))
    }

    @Test("Elimina parámetros de seguimiento (utm_*, fbclid…) → misma clave")
    func stripsTracking() {
        let clean = CanonicalURL.key("https://example.com/articulo")
        #expect(CanonicalURL.key("https://example.com/articulo?utm_source=newsletter&utm_medium=email") == clean)
        #expect(CanonicalURL.key("https://example.com/articulo?fbclid=ABC123") == clean)
        #expect(CanonicalURL.key("https://example.com/articulo?gclid=XYZ&utm_campaign=x") == clean)
    }

    @Test("En x.com/twitter, ?s= y ?t= (firmas del compartir) se ignoran")
    func stripsTwitterShareParams() {
        #expect(CanonicalURL.key("https://x.com/user/status/123?s=20") == CanonicalURL.key("https://x.com/user/status/123"))
        #expect(CanonicalURL.key("https://twitter.com/user/status/123?t=abc&s=09") == CanonicalURL.key("https://twitter.com/user/status/123"))
    }

    @Test("Conserva los parámetros de CONTENIDO (no fusiona páginas distintas)")
    func keepsContentParams() {
        // El id/q/v identifican el recurso: NO se deben fusionar.
        #expect(CanonicalURL.key("https://example.com/p?id=1") != CanonicalURL.key("https://example.com/p?id=2"))
        #expect(CanonicalURL.key("https://youtube.com/watch?v=aaa") != CanonicalURL.key("https://youtube.com/watch?v=bbb"))
        // `?s=` en un sitio que NO es Twitter es búsqueda/contenido → se conserva.
        #expect(CanonicalURL.key("https://blog.com/?s=swift") != CanonicalURL.key("https://blog.com/?s=kotlin"))
    }

    @Test("Conserva el fragmento (puede ser una ruta de SPA)")
    func keepsFragment() {
        #expect(CanonicalURL.key("https://app.com/#/ruta") != CanonicalURL.key("https://app.com/#/otra"))
    }
}
