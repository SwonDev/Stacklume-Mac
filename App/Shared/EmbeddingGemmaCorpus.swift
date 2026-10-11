import Foundation
import CryptoKit
import ImageIO
import CoreGraphics

struct EmbeddingGemmaDocument: Sendable {
    let id: UUID
    let text: String
    let cover: Data?
    let attachment: Data?
    let attachmentExtension: String?
    let pageSnapshot: Data?
}

/// Copias derivadas privadas. Solo sus propios archivos se actualizan o purgan.
actor EmbeddingGemmaCorpus {
    static let shared = EmbeddingGemmaCorpus()

    func write(_ document: EmbeddingGemmaDocument) throws {
        let folder = EmbeddingGemmaRuntime.corpus.appendingPathComponent(document.id.uuidString, isDirectory: true)
        try PrivateFileIO.ensureDirectory(folder)
        let cover = document.cover.flatMap(Self.searchImage)
        let page = document.pageSnapshot.flatMap(Self.searchImage)
        var text = document.text
        if let page {
            text += "\nAspecto de la página: " + Self.colors(in: page).joined(separator: ", ")
        } else if let cover {
            text += "\nColores de la portada: " + Self.colors(in: cover).joined(separator: ", ")
        }
        try writeIfChanged(Data(text.utf8), to: folder.appendingPathComponent("contenido.txt"))
        var names: Set<String> = ["contenido.txt"]
        if let cover {
            names.insert("portada.jpg")
            try writeIfChanged(cover, to: folder.appendingPathComponent("portada.jpg"))
        }
        if let data = document.attachment, let ext = document.attachmentExtension {
            let name = "original.\(ext)"
            names.insert(name)
            try writeIfChanged(data, to: folder.appendingPathComponent(name))
        }
        if let page {
            names.insert("pagina.jpg")
            try writeIfChanged(page, to: folder.appendingPathComponent("pagina.jpg"))
        }
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where !names.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
    }

    private var pages: URL { EmbeddingGemmaRuntime.root.appendingPathComponent("pages", isDirectory: true) }

    private func pageKey(_ rawURL: String) -> String {
        SHA256.hash(data: Data(CanonicalURL.key(rawURL).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func pageSnapshot(for rawURL: String) -> Data? {
        try? BoundedFileReader.read(pages.appendingPathComponent(pageKey(rawURL)), maximumBytes: 24 * 1_024 * 1_024)
    }

    func savePageSnapshot(_ data: Data, for rawURL: String) throws {
        try PrivateFileIO.ensureDirectory(pages)
        try writeIfChanged(data, to: pages.appendingPathComponent(pageKey(rawURL)))
    }

    func purgePageSnapshots(except rawURLs: Set<String>) throws {
        guard FileManager.default.fileExists(atPath: pages.path) else { return }
        let keys = Set(rawURLs.map(pageKey))
        for file in try FileManager.default.contentsOfDirectory(at: pages, includingPropertiesForKeys: nil)
            where !keys.contains(file.lastPathComponent) { try FileManager.default.removeItem(at: file) }
    }

    func purge(except ids: Set<UUID>) throws {
        try PrivateFileIO.ensureDirectory(EmbeddingGemmaRuntime.corpus)
        for folder in try FileManager.default.contentsOfDirectory(at: EmbeddingGemmaRuntime.corpus, includingPropertiesForKeys: nil) {
            if let id = UUID(uuidString: folder.lastPathComponent), !ids.contains(id) {
                try FileManager.default.removeItem(at: folder)
            }
        }
    }

    private func writeIfChanged(_ data: Data, to url: URL) throws {
        if let old = try? BoundedFileReader.read(url, maximumBytes: max(data.count, 1)), old == data { return }
        try PrivateFileIO.write(data, to: url)
    }

    /// La copia de búsqueda limita la decodificación y descarta respuestas HTML o imágenes corruptas.
    private static func searchImage(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_280,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return result as Data
    }

    /// Etiquetas visuales derivadas de una miniatura de 64 px, sin interpretar HTML ni ejecutar IA extra.
    private static func colors(in data: Data) -> [String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return [] }
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 64, height: 64,
                bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            return true
        }
        guard drawn else { return [] }
        var counts: [String: Int] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 127 {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let maxValue = max(r, g, b), minValue = min(r, g, b), delta = maxValue - minValue
            let name: String
            if maxValue < 0.18 { name = "negro" }
            else if delta < 0.10 { name = minValue > 0.80 ? "blanco" : "gris" }
            else {
                var hue = maxValue == r ? (g - b) / delta : maxValue == g ? 2 + (b - r) / delta : 4 + (r - g) / delta
                hue = (hue * 60 + 360).truncatingRemainder(dividingBy: 360)
                name = hue < 20 || hue >= 345 ? "rojo" : hue < 45 ? "naranja" : hue < 70 ? "amarillo"
                    : hue < 165 ? "verde" : hue < 195 ? "turquesa" : hue < 260 ? "azul" : hue < 295 ? "violeta" : "rosa"
            }
            counts[name, default: 0] += 1
        }
        return counts.filter { $0.value >= 64 }.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(4).map { "color " + $0.key }
    }
}
