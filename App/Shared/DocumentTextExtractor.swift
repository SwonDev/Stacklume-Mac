import Foundation
import AppKit
import CoreGraphics
import ImageIO
import PDFKit
import Vision

struct DocumentTextExtractionResult: Sendable, Equatable {
    let text: String
    let totalPageCount: Int
    let processedPageCount: Int
    let recognizedPageCount: Int
    let usedOCR: Bool
    let wasTruncated: Bool
}

enum DocumentTextExtractionError: LocalizedError, Sendable {
    case unsupportedKind
    case invalidDocument
    case fileTooLarge(maximumMegabytes: Int)
    case imageTooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedKind:
            "El tipo de archivo no admite extracción de texto."
        case .invalidDocument:
            "El archivo está dañado o no se puede leer."
        case .fileTooLarge(let maximumMegabytes):
            "El archivo supera el límite seguro de \(maximumMegabytes) MB."
        case .imageTooLarge:
            "La imagen tiene unas dimensiones demasiado grandes para analizarla con seguridad."
        }
    }
}

/// Extrae texto de PDFs, imágenes y EPUB completamente on-device.
///
/// - PDF con capa de texto: usa PDFKit sin OCR.
/// - PDF escaneado o imagen: usa Vision con detección automática de idioma.
/// - EPUB: valida el contenedor y recorre su spine, sin ejecutar HTML ni cargar recursos.
/// - Todo el trabajo pesado ocurre en una tarea detached y está acotado por bytes,
///   páginas, píxeles y caracteres para no bloquear ni agotar la memoria.
enum DocumentTextExtractor {
    static let maximumInputBytes = 64 * 1_024 * 1_024
    static let maximumInputMegabytes = 64
    private static let maximumPDFPages = 500
    private static let maximumOCRPages = 80
    static let maximumImagePixels = 120_000_000
    private static let maximumRenderedDimension = 2_200

    static func extract(data: Data, kind: String) async throws -> DocumentTextExtractionResult {
        try validate(data: data, kind: kind)

        let extractionTask = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            if kind == "pdf" {
                return try await extractPDF(data)
            }
            if kind == "image" {
                return try await extractImage(data)
            }
            return try extractEPUB(data)
        }
        return try await withTaskCancellationHandler {
            try await extractionTask.value
        } onCancel: {
            extractionTask.cancel()
        }
    }

    /// Valida contenido, no solo la extensión elegida en el panel. Es deliberadamente
    /// síncrona y barata: no renderiza ni reconoce texto.
    static func validate(data: Data, kind: String) throws {
        guard !data.isEmpty else { throw DocumentTextExtractionError.invalidDocument }
        guard data.count <= maximumInputBytes else {
            throw DocumentTextExtractionError.fileTooLarge(maximumMegabytes: maximumInputMegabytes)
        }
        switch kind {
        case "pdf":
            guard let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider),
                  document.numberOfPages > 0 else {
                throw DocumentTextExtractionError.invalidDocument
            }
        case "image":
            _ = try validatedImageSource(from: data)
        case "epub":
            try EPUBDocumentReader.validate(data: data)
        default:
            throw DocumentTextExtractionError.unsupportedKind
        }
    }

    private static func extractEPUB(_ data: Data) throws -> DocumentTextExtractionResult {
        let publication = try EPUBDocumentReader.extract(data: data)
        let sanitized = DocumentTextSanitizer.normalize(publication.chapters.map(\.text))
        return DocumentTextExtractionResult(
            text: sanitized.text,
            totalPageCount: publication.sourceChapterCount,
            processedPageCount: publication.processedChapterCount,
            recognizedPageCount: publication.chapters.count,
            usedOCR: false,
            wasTruncated: publication.wasTruncated || sanitized.wasTruncated
        )
    }

    private static func extractImage(_ data: Data) async throws -> DocumentTextExtractionResult {
        guard let image = try safeImage(from: data) else {
            throw DocumentTextExtractionError.invalidDocument
        }
        let recognized = try await recognizeText(in: image)
        let sanitized = DocumentTextSanitizer.normalize([recognized])
        return DocumentTextExtractionResult(
            text: sanitized.text,
            totalPageCount: 1,
            processedPageCount: 1,
            recognizedPageCount: sanitized.text.isEmpty ? 0 : 1,
            usedOCR: true,
            wasTruncated: sanitized.wasTruncated
        )
    }

    private static func extractPDF(_ data: Data) async throws -> DocumentTextExtractionResult {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw DocumentTextExtractionError.invalidDocument
        }

        let totalPages = document.pageCount
        let pageLimit = min(totalPages, maximumPDFPages)
        var fragments: [String] = []
        fragments.reserveCapacity(pageLimit)
        var recognizedPages = 0
        var ocrPages = 0
        var skippedOCRPages = 0

        for index in 0..<pageLimit {
            try Task.checkCancellation()
            let nativeText = autoreleasepool {
                document.page(at: index)?.string ?? ""
            }

            if hasMeaningfulText(nativeText) {
                fragments.append(nativeText)
                recognizedPages += 1
                continue
            }

            guard ocrPages < maximumOCRPages else {
                skippedOCRPages += 1
                continue
            }
            guard let image = autoreleasepool(invoking: { () -> CGImage? in
                guard let page = document.page(at: index)?.pageRef else { return nil }
                return renderedImage(for: page)
            }) else { continue }

            let recognized = try await recognizeText(in: image)
            if hasMeaningfulText(recognized) {
                fragments.append(recognized)
                recognizedPages += 1
            }
            ocrPages += 1
        }

        let sanitized = DocumentTextSanitizer.normalize(fragments)
        return DocumentTextExtractionResult(
            text: sanitized.text,
            totalPageCount: totalPages,
            processedPageCount: pageLimit,
            recognizedPageCount: recognizedPages,
            usedOCR: ocrPages > 0,
            wasTruncated: sanitized.wasTruncated
                || totalPages > maximumPDFPages
                || skippedOCRPages > 0
        )
    }

    private static func hasMeaningfulText(_ text: String) -> Bool {
        text.unicodeScalars.lazy.filter { CharacterSet.alphanumerics.contains($0) }.prefix(20).count >= 20
    }

    private static func recognizeText(in image: CGImage) async throws -> String {
        try Task.checkCancellation()
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: image)
        try Task.checkCancellation()
        return observations.compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// Decodifica una miniatura segura en vez de materializar la imagen original completa.
    private static func safeImage(from data: Data) throws -> CGImage? {
        let source = try validatedImageSource(from: data)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3_000,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func validatedImageSource(from data: Data) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) != nil,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw DocumentTextExtractionError.invalidDocument
        }
        guard width <= maximumImagePixels / max(1, height) else {
            throw DocumentTextExtractionError.imageTooLarge
        }
        return source
    }

    private static func renderedImage(for page: CGPDFPage) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(
            CGFloat(maximumRenderedDimension) / box.width,
            CGFloat(maximumRenderedDimension) / box.height,
            2.0
        )
        let width = max(1, Int((box.width * scale).rounded(.up)))
        let height = max(1, Int((box.height * scale).rounded(.up)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(target)
        context.concatenate(page.getDrawingTransform(
            .cropBox,
            rect: target,
            rotate: 0,
            preserveAspectRatio: true
        ))
        context.drawPDFPage(page)
        return context.makeImage()
    }
}
