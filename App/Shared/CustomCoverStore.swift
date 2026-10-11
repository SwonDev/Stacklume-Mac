import SwiftUI
import StacklumeDesignSystem
#if canImport(AppKit)
import AppKit
#endif

/// Portadas personalizadas por enlace: el usuario puede fijar una imagen propia (HD) como
/// portada de cualquier enlace, que tiene PRIORIDAD sobre la `imageURL` autodetectada.
/// Resuelve para siempre las portadas de baja resolución del origen y supera a Raindrop
/// (que limita las portadas personalizadas al plan Pro).
///
/// Se guarda en DISCO (un JPEG por enlace en Application Support), sin tocar el modelo
/// `Bookmark` (read-only). La reactividad la da `@Observable` + un contador de versión por
/// enlace: al cambiar/quitar una portada, las vistas que la consultan se repintan.
@Observable
@MainActor
final class CustomCoverStore {
    static let shared = CustomCoverStore()

    /// Caché en memoria de las portadas ya cargadas.
    private let cache: NSCache<NSUUID, PlatformImage> = {
        let cache = NSCache<NSUUID, PlatformImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()

    private func cacheImage(_ image: PlatformImage, for id: UUID) {
        cache.setObject(image, forKey: id as NSUUID,
                        cost: Int(image.size.width * image.size.height * 4))
    }
    /// Versión por enlace: mutar esto al cambiar una portada dispara el repintado de las
    /// vistas que leyeron `image(for:)` (registran dependencia con `@Observable`).
    private var version: [UUID: Int] = [:]

    /// Carpeta de portadas personalizadas (Application Support/Stacklume/CustomCovers).
    private let dir: URL = {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Stacklume/CustomCovers", isDirectory: true)
        try? PrivateFileIO.ensureDirectory(dir)
        return dir
    }()

    private func fileURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).jpg") }

    /// Portada personalizada del enlace (de caché o de disco), o `nil` si no tiene.
    func image(for id: UUID) -> PlatformImage? {
        _ = version[id]   // registra dependencia → repinta al cambiar de versión
        if let img = cache.object(forKey: id as NSUUID) { return img }
        let url = fileURL(id)
        guard let data = try? BoundedFileReader.read(
            url,
            maximumBytes: SecureImageCache.maximumImageBytes
        ), let img = CoverImage.decodedThumbnail(
            data,
            maximumInputBytes: SecureImageCache.maximumImageBytes,
            maxDimension: 1_600
        ) else { return nil }
        cacheImage(img, for: id)
        return img
    }

    /// Datos JPEG crudos de la portada personalizada (para el backup completo), o `nil`.
    func coverData(for id: UUID) -> Data? {
        let url = fileURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? BoundedFileReader.read(
            url,
            maximumBytes: SecureImageCache.maximumImageBytes
        )
    }

    /// Restaura una portada desde sus datos crudos (backup), sin re-comprimir.
    @discardableResult
    func restore(_ data: Data, for id: UUID) -> Bool {
        guard let safeData = CoverImage.downscaledJPEG(
            data,
            maximumInputBytes: SecureImageCache.maximumImageBytes,
            maxDimension: 1_600,
            quality: 0.85
        ) else { return false }
        do {
            try PrivateFileIO.write(safeData, to: fileURL(id))
            CoverRecoveryProvenanceStore.shared.remove(id)
            if let image = PlatformImage(data: safeData) { cacheImage(image, for: id) }
            version[id, default: 0] += 1
            NotificationCenter.default.post(name: .stacklumeSearchContentDidChange, object: nil)
            return true
        } catch { return false }
    }

    /// `true` si el enlace tiene una portada personalizada (sin cargar la imagen entera).
    func has(_ id: UUID) -> Bool {
        _ = version[id]
        return cache.object(forKey: id as NSUUID) != nil || FileManager.default.fileExists(atPath: fileURL(id).path)
    }

    /// Versión actual de la portada del enlace (cambia al fijar/quitar). Útil como `id` de
    /// `.task` para re-resolver la proporción del tile cuando cambia la portada.
    func currentVersion(for id: UUID) -> Int {
        _ = version[id]
        return version[id] ?? 0
    }

    /// Fija una portada personalizada (la reduce y comprime a JPEG ligero antes de guardar).
    @discardableResult
    func set(_ image: PlatformImage, for id: UUID) -> Bool {
        guard let data = CoverImage.downscaledJPEG(image, maxDimension: 1600, quality: 0.85) else { return false }
        do {
            try PrivateFileIO.write(data, to: fileURL(id))
            CoverRecoveryProvenanceStore.shared.remove(id)
            cacheImage(PlatformImage(data: data) ?? image, for: id)
            version[id, default: 0] += 1
            NotificationCenter.default.post(name: .stacklumeSearchContentDidChange, object: nil)
            return true
        } catch { return false }
    }

    /// Quita la portada personalizada (vuelve a la `imageURL` autodetectada).
    func remove(for id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(id))
        CoverRecoveryProvenanceStore.shared.remove(id)
        cache.removeObject(forKey: id as NSUUID)
        version[id, default: 0] += 1
        NotificationCenter.default.post(name: .stacklumeSearchContentDidChange, object: nil)
    }

    /// Borra TODAS las portadas personalizadas (restablecer la app): vacía el directorio.
    func removeAll() {
        try? FileManager.default.removeItem(at: dir)
        try? PrivateFileIO.ensureDirectory(dir)
        cache.removeAllObjects()
        version.removeAll()
        CoverRecoveryProvenanceStore.shared.removeAll()
    }
}
