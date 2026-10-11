import Foundation
import Testing

@Suite("DocumentTextSanitizer — texto OCR seguro")
struct DocumentTextSanitizerTests {
    @Test("Normaliza espacios, controles y separa páginas")
    func normalizesFragments() {
        let result = DocumentTextSanitizer.normalize([
            "  Primera\t\t página\r\n\r\n\r\nTexto  ",
            "\u{200B}Segunda\u{00A0}página\u{0007}",
        ])

        #expect(result.text == "Primera página\n\nTexto\n\nSegunda página")
        #expect(result.wasTruncated == false)
    }

    @Test("Respeta la cota sin cortar fuera del límite")
    func truncatesAtLimit() {
        let result = DocumentTextSanitizer.normalize(
            ["12345", "67890"],
            maximumCharacters: 8
        )

        #expect(result.text == "12345\n\n6")
        #expect(result.text.count == 8)
        #expect(result.wasTruncated)
    }

    @Test("Una cota nula produce texto vacío y marca truncado")
    func zeroLimit() {
        let result = DocumentTextSanitizer.normalize(["contenido"], maximumCharacters: 0)
        #expect(result.text.isEmpty)
        #expect(result.wasTruncated)
    }

    @Test("Acota la entrada antes de ejecutar normalizaciones")
    func boundsRawInputBeforeNormalization() {
        let hostile = String(repeating: " ", count: 10_000) + "contenido tardío"
        let result = DocumentTextSanitizer.normalize([hostile], maximumCharacters: 20)

        #expect(result.text.isEmpty)
        #expect(result.wasTruncated)
    }
}
