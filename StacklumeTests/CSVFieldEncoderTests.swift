import Foundation
import Testing

@Suite("CSV — exportación segura")
struct CSVFieldEncoderTests {
    @Test("Neutraliza fórmulas incluso tras espacios")
    func neutralizesSpreadsheetFormulas() {
        #expect(CSVFieldEncoder.encode("=1+1") == "'=1+1")
        #expect(CSVFieldEncoder.encode("  @SUM(A1:A2)") == "'  @SUM(A1:A2)")
        #expect(CSVFieldEncoder.encode("-2+3") == "'-2+3")
        #expect(CSVFieldEncoder.encode("texto normal") == "texto normal")
    }

    @Test("Conserva el escapado RFC 4180")
    func quotesSpecialCharacters() {
        #expect(CSVFieldEncoder.encode("uno,dos") == "\"uno,dos\"")
        #expect(CSVFieldEncoder.encode("dice \"hola\"") == "\"dice \"\"hola\"\"\"")
        #expect(CSVFieldEncoder.encode("=SUM(A1,A2)") == "\"'=SUM(A1,A2)\"")
    }
}
