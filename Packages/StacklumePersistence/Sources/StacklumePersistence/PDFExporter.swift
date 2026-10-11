import Foundation
import CoreGraphics
import CoreText
import StacklumeCore

/// Genera un PDF con la biblioteca de enlaces agrupada por categoría.
/// Implementación multiplataforma (Core Graphics + Core Text), sin UIKit/AppKit.
public enum PDFExporter {

    public static func makePDF(from links: [Bookmark]) -> Data {
        let pageWidth: CGFloat = 595   // A4 a 72 dpi
        let pageHeight: CGFloat = 842
        let margin: CGFloat = 40
        let contentWidth = pageWidth - margin * 2
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        let active = links.filter { $0.deletedAt == nil }
        let grouped = Dictionary(grouping: active) { $0.category?.name ?? "Sin categoría" }
        let sections = grouped.keys.sorted()

        // Fuentes Core Text (cross-platform; no dependen de UIFont/NSFont).
        let titleFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 24, nil)
        let headerFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 16, nil)
        let linkTitleFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 12, nil)
        let urlFont = CTFontCreateWithName("Helvetica" as CFString, 10, nil)

        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        let blue = CGColor(red: 0, green: 0.48, blue: 1, alpha: 1)
        let gray = CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)

        // `y` se mide desde ARRIBA; al dibujar se convierte al sistema del PDF
        // (origen abajo-izquierda) con `pageHeight - y`.
        var yFromTop: CGFloat = margin

        func draw(_ text: String, font: CTFont, color: CGColor, x: CGFloat, yTop: CGFloat) {
            let attrs: [NSAttributedString.Key: Any] = [
                .init(rawValue: kCTFontAttributeName as String): font,
                .init(rawValue: kCTForegroundColorAttributeName as String): color
            ]
            let attributed = NSAttributedString(string: text, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attributed)
            ctx.textPosition = CGPoint(x: x, y: pageHeight - yTop)
            CTLineDraw(line, ctx)
        }

        ctx.beginPDFPage(nil)

        func newPageIfNeeded(_ needed: CGFloat) {
            if yFromTop + needed > pageHeight - margin {
                ctx.endPDFPage()
                ctx.beginPDFPage(nil)
                yFromTop = margin
            }
        }

        // Título
        draw("Stacklume", font: titleFont, color: black, x: margin, yTop: yFromTop + 20)
        yFromTop += 36

        for section in sections {
            newPageIfNeeded(40)
            draw(section, font: headerFont, color: blue, x: margin, yTop: yFromTop + 14)
            yFromTop += 24

            for link in (grouped[section] ?? []).sorted(by: { $0.createdAt > $1.createdAt }) {
                newPageIfNeeded(38)
                let title = link.title.isEmpty ? link.url : link.title
                draw(title, font: linkTitleFont, color: black, x: margin, yTop: yFromTop + 11)
                yFromTop += 15
                draw(link.url, font: urlFont, color: gray, x: margin, yTop: yFromTop + 10)
                yFromTop += 20
            }
            yFromTop += 8
        }

        ctx.endPDFPage()
        ctx.closePDF()
        _ = contentWidth   // reservado para futuro recorte de texto largo
        return data as Data
    }
}
