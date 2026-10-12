import Foundation
import ImageIO
import UniformTypeIdentifiers
import StacklumeDesignSystem
#if canImport(AppKit)
import AppKit
#endif

/// Utilidades para preparar imágenes de portada de colecciones en macOS: reduce la
/// resolución y comprime a JPEG ligero antes de guardarlas en `coverImageData`,
/// para no inflar el almacén ni la memoria (equivalente al `downscaled` del iPhone).
enum CoverImage {
    private static func thumbnail(
        from data: Data,
        maximumInputBytes: Int,
        maxDimension: CGFloat
    ) -> CGImage? {
        guard !data.isEmpty, data.count <= maximumInputBytes, maxDimension > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension.rounded(.up)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            sourceOptions as CFDictionary
        )
    }

    /// Carga una imagen no confiable sin decodificar nunca su resolución completa.
    static func decodedThumbnail(
        _ data: Data,
        maximumInputBytes: Int = 32 * 1_024 * 1_024,
        maxDimension: CGFloat = 1_600
    ) -> PlatformImage? {
        guard let thumbnail = thumbnail(
            from: data,
            maximumInputBytes: maximumInputBytes,
            maxDimension: maxDimension
        ) else { return nil }
        #if canImport(AppKit)
        return NSImage(
            cgImage: thumbnail,
            size: NSSize(width: thumbnail.width, height: thumbnail.height)
        )
        #else
        return PlatformImage(cgImage: thumbnail)
        #endif
    }

    /// Decodifica datos no confiables mediante ImageIO creando directamente un thumbnail.
    /// Nunca materializa la imagen a resolución original.
    static func downscaledJPEG(
        _ data: Data,
        maximumInputBytes: Int = 32 * 1_024 * 1_024,
        maxDimension: CGFloat = 800,
        quality: CGFloat = 0.8,
        minimumDimension: Int = 0
    ) -> Data? {
        guard let thumbnail = thumbnail(
            from: data,
            maximumInputBytes: maximumInputBytes,
            maxDimension: maxDimension
        ), min(thumbnail.width, thumbnail.height) >= minimumDimension else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Reduce la imagen a `maxDimension` px (lado mayor) y la codifica como JPEG.
    /// Devuelve `nil` si no puede generar la representación.
    static func downscaledJPEG(_ image: PlatformImage,
                               maxDimension: CGFloat = 800,
                               quality: CGFloat = 0.8) -> Data? {
        #if canImport(AppKit)
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = NSSize(width: floor(size.width * scale), height: floor(size.height * scale))

        let resized = NSImage(size: target)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: size),
                   operation: .sourceOver, fraction: 1)
        resized.unlockFocus()

        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        #else
        return nil
        #endif
    }
}
