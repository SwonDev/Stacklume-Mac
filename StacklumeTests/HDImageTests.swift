import Testing
import Foundation

// `HDImage.upgraded` sube una URL de portada a su variante de mayor resolución cuando
// reconoce el patrón (YouTube, sufijos de CDN, parámetros de reducción). Lógica pura.

@Suite("HDImage — mejora de resolución de portadas")
struct HDImageTests {

    @Test("YouTube: hqdefault → maxresdefault")
    func youtube() {
        #expect(HDImage.upgraded("https://i.ytimg.com/vi/abc/hqdefault.jpg")
                == "https://i.ytimg.com/vi/abc/maxresdefault.jpg")
    }

    @Test("CDN: sufijo =s400 / =w400-h300 → =s2048")
    func cdnSuffix() {
        #expect(HDImage.upgraded("https://lh3.googleusercontent.com/abc=s400")
                == "https://lh3.googleusercontent.com/abc=s2048")
        #expect(HDImage.upgraded("https://lh3.googleusercontent.com/abc=w400-h300")
                == "https://lh3.googleusercontent.com/abc=s2048")
    }

    @Test("Parámetros de reducción de tamaño se eliminan")
    func dropResizeParams() {
        #expect(HDImage.upgraded("https://cdn.example.com/img.jpg?w=400&h=300&id=5")
                == "https://cdn.example.com/img.jpg?id=5")
    }

    @Test("URL sin patrón reconocible → nil")
    func noPattern() {
        #expect(HDImage.upgraded("https://example.com/image.png") == nil)
    }

    @Test("candidates: HD primero, luego original, sin duplicar")
    func candidates() {
        let c = HDImage.candidates("https://i.ytimg.com/vi/abc/hqdefault.jpg")
        #expect(c.count == 2)
        #expect(c.first == "https://i.ytimg.com/vi/abc/maxresdefault.jpg")
    }

    @Test("candidates vacío si no hay URL")
    func emptyCandidates() {
        #expect(HDImage.candidates(nil).isEmpty)
        #expect(HDImage.candidates("").isEmpty)
    }
}
