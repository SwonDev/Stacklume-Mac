import Testing
import Foundation
import StacklumePersistence

@Suite("PDFExporter cross-platform")
struct PDFExporterTests {
    @Test("genera datos PDF válidos con cabecera %PDF")
    func producesValidPDFHeader() {
        let pdf = PDFExporter.makePDF(from: [])
        #expect(pdf.count > 0)
        let header = String(decoding: pdf.prefix(4), as: UTF8.self)
        #expect(header == "%PDF")
    }
}
