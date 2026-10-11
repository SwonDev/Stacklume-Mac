import Foundation
import CoreGraphics
import CoreText
import Testing

@Suite("DocumentTextExtractor — documentos locales")
struct DocumentTextExtractorTests {
    @Test("Extrae la capa de texto de un PDF sin recurrir a OCR")
    func extractsNativePDFText() async throws {
        let pdf = try makeSearchablePDF(
            text: "Stacklume encuentra este documento local mediante su índice de contenido."
        )

        let result = try await DocumentTextExtractor.extract(data: pdf, kind: "pdf")

        #expect(result.text.contains("Stacklume encuentra este documento local"))
        #expect(result.totalPageCount == 1)
        #expect(result.recognizedPageCount == 1)
        #expect(result.usedOCR == false)
        #expect(result.wasTruncated == false)
    }

    @Test("Rechaza contenido que finge ser una imagen")
    func rejectsInvalidImagePayload() {
        #expect(throws: DocumentTextExtractionError.self) {
            try DocumentTextExtractor.validate(
                data: Data("no es una imagen".utf8),
                kind: "image"
            )
        }
    }

    @Test("Rechaza tipos no admitidos")
    func rejectsUnsupportedKinds() {
        #expect(throws: DocumentTextExtractionError.self) {
            try DocumentTextExtractor.validate(data: Data([0x01]), kind: "video")
        }
    }

    private func makeSearchablePDF(text: String) throws -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else {
            throw DocumentTextExtractionError.invalidDocument
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw DocumentTextExtractionError.invalidDocument
        }

        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 48, y: 620, width: 516, height: 100), transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            path,
            nil
        )
        CTFrameDraw(frame, context)
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }
}
