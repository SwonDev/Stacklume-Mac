import Foundation
import Testing

@Suite("XML — declaraciones no confiables")
struct XMLInputSafetyTests {
    @Test("Detecta una DTD situada después de una cabecera grande")
    func detectsLateDeclaration() {
        let payload = Data((String(repeating: " ", count: 200_000)
            + "<!DOCTYPE html [<!ENTITY x \"boom\">]>").utf8)
        #expect(XMLInputSafety.containsForbiddenDeclaration(payload))
    }

    @Test("Detecta declaraciones UTF-16 y acepta XML ordinario")
    func detectsNullSeparatedDeclaration() {
        let utf16 = "<!ENTITY x \"boom\">".data(using: .utf16LittleEndian)!
        #expect(XMLInputSafety.containsForbiddenDeclaration(utf16))
        #expect(!XMLInputSafety.containsForbiddenDeclaration(Data("<rss><item/></rss>".utf8)))
    }
}
