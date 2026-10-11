import SwiftUI
import CryptoKit
import ImageIO
import StacklumeDesignSystem
#if canImport(AppKit)
import AppKit
#endif

/// Caché de bytes compatible con la ruta histórica de Stacklume, pero con lectura
/// acotada y permisos privados. Así se reutilizan imágenes existentes sin volver a red.
private actor SecureDiskImageCache {
    static let shared = SecureDiskImageCache()

    private let directory: URL?

    init() {
        let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let path = base?.appendingPathComponent("Stacklume/RemoteImageCache", isDirectory: true)
        if let path { try? PrivateFileIO.ensureDirectory(path) }
        directory = path
    }

    init(directory: URL) {
        try? PrivateFileIO.ensureDirectory(directory)
        self.directory = directory
    }

    private static func fileName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(for key: String) -> URL? {
        directory?.appendingPathComponent(Self.fileName(for: key))
    }

    func data(for key: String, maximumBytes: Int) -> Data? {
        guard let url = fileURL(for: key) else { return nil }
        return try? BoundedFileReader.read(url, maximumBytes: maximumBytes)
    }

    func store(_ data: Data, for key: String) {
        guard let url = fileURL(for: key) else { return }
        try? PrivateFileIO.write(data, to: url)
    }
}

/// Decodifica mediante ImageIO creando siempre un thumbnail. Evita que una imagen con
/// pocos bytes pero dimensiones descomunales reserve memoria sin cota al mostrarse.
private actor SafeRemoteImageDecoder {
    static let shared = SafeRemoteImageDecoder()
    static let maximumPixelDimension = 4_096

    func image(from data: Data, maxPixels: Int) -> CGImage? {
        guard !Task.isCancelled, !data.isEmpty else { return nil }
        let maximum = min(Self.maximumPixelDimension, max(1, maxPixels))
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetCount(source) > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximum,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return Task.isCancelled ? nil : image
            }
        }
        guard !Task.isCancelled else { return nil }
        return StaticSVGImageDecoder.image(from: data, maxPixels: maximum)
    }
}

/// Sustituto seguro del cargador de imágenes compartido: mismo comportamiento visual,
/// pero solo adquiere destinos públicos, valida cada redirección, limita los bytes y
/// reduce la decodificación al tamaño solicitado, con un máximo de 4096 px.
@MainActor
final class SecureImageCache {
    static let shared = SecureImageCache()

    static let maximumImageBytes = 24 * 1_024 * 1_024

    private let disk: SecureDiskImageCache
    private let cache = NSCache<NSString, PlatformImage>()
    private var permanentlyFailed: Set<URL> = []
    private var failureReasons: [URL: String] = [:]
    private var networkFlights: [URL: NetworkFlight] = [:]
    private var decodeFlights: [String: DecodeFlight] = [:]

    @MainActor private final class ImageValue {
        let image: PlatformImage
        init(_ image: PlatformImage) { self.image = image }
    }

    @MainActor private final class NetworkFlight {
        let id = UUID()
        var task: Task<Void, Never>?
        var persistence: Task<Void, Never>?
        var observers: Set<UUID> = []
        var waiters: [UUID: CheckedContinuation<Data?, Never>] = [:]
        var completed = false
        var data: Data?
    }

    @MainActor private final class DecodeFlight {
        let id = UUID()
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<ImageValue?, Never>] = [:]
    }

    private init() {
        disk = .shared
        configureMemoryCache()
    }

    /// Frontera de almacenamiento aislable para pruebas y diagnósticos: no toca la
    /// caché canónica cuando se verifica adquisición y decodificación fuera de la app.
    init(cacheDirectory: URL) {
        disk = SecureDiskImageCache(directory: cacheDirectory)
        configureMemoryCache()
    }

    private func configureMemoryCache() {
        cache.countLimit = 3_000
        // NSCache aplica un objetivo de coste; no es una cota estricta de RAM.
        cache.totalCostLimit = 192 * 1_024 * 1_024
    }

    private static func cacheKey(_ url: URL, maxPixels: Int) -> NSString {
        (url.absoluteString + "\u{0}" + String(min(4_096, max(1, maxPixels)))) as NSString
    }

    func cached(for url: URL, maxPixels: Int = 4_096) -> PlatformImage? {
        cache.object(forKey: Self.cacheKey(url, maxPixels: maxPixels))
    }

    func failureDescription(for url: URL) -> String? { failureReasons[url] }

    func retry(for url: URL) {
        permanentlyFailed.remove(url)
        failureReasons[url] = nil
    }

    private func recordFailure(_ description: String, for url: URL) {
        if failureReasons.count >= 300 { failureReasons.removeAll(keepingCapacity: true) }
        failureReasons[url] = description
    }

    func cachedBytesForSearch(for url: URL) async -> Data? {
        if let data = await disk.data(for: url.absoluteString, maximumBytes: Self.maximumImageBytes) { return data }
        return cached(for: url).flatMap { CoverImage.downscaledJPEG($0, maxDimension: 1600, quality: 0.85) }
    }

    /// Comparte los bytes ya adquiridos con la búsqueda; usa la misma frontera segura.
    func bytesForSearch(for url: URL) async -> Data? {
        if let data = await disk.data(for: url.absoluteString, maximumBytes: Self.maximumImageBytes) {
            return data
        }
        guard let image = await image(for: url) else { return nil }
        return CoverImage.downscaledJPEG(image, maxDimension: 1600, quality: 0.85)
    }

    /// Solo memoria y disco: permite probar todas las variantes antes de usar la red.
    func storedImage(for url: URL, maxPixels: Int = 4_096) async -> PlatformImage? {
        guard !Task.isCancelled else { return nil }
        if let cached = cached(for: url, maxPixels: maxPixels) { return cached }

        let key = url.absoluteString
        if let data = await disk.data(
            for: key,
            maximumBytes: Self.maximumImageBytes
        ), !Task.isCancelled {
            return await decodedImage(data, for: url, maxPixels: maxPixels)?.image
        }

        return nil
    }

    func image(for url: URL, maxPixels: Int = 4_096) async -> PlatformImage? {
        if let image = await storedImage(for: url, maxPixels: maxPixels) { return image }
        guard !Task.isCancelled else { return nil }
        guard StacklumeAutomationPolicy.allowsExternalCaptureURL(url) else {
            recordFailure("La dirección de la muestra no está permitida.", for: url)
            return nil
        }
        if permanentlyFailed.contains(url) { return nil }

        let observer = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            let data = await networkData(for: url, observer: observer)
            defer { removeNetworkObserver(observer, for: url) }
            guard let data, !Task.isCancelled else { return nil }
            guard let value = await decodedImage(data, for: url, maxPixels: maxPixels) else {
                if !Task.isCancelled {
                    permanentlyFailed.insert(url)
                    recordFailure("La fuente respondió, pero macOS no pudo decodificar la imagen.", for: url)
                }
                return nil
            }
            guard !Task.isCancelled else { return nil }
            await persistOriginal(data, for: url, observer: observer)
            guard !Task.isCancelled else { return nil }
            failureReasons[url] = nil
            return value.image
        } onCancel: {
            Task { @MainActor [weak self] in self?.removeNetworkObserver(observer, for: url) }
        }
    }

    private func networkData(for url: URL, observer: UUID) async -> Data? {
        await withCheckedContinuation { continuation in
            guard !Task.isCancelled else { continuation.resume(returning: nil); return }
            let flight: NetworkFlight
            if let existing = networkFlights[url], !existing.completed || existing.data != nil {
                flight = existing
            } else {
                flight = NetworkFlight()
                networkFlights[url] = flight
            }
            flight.observers.insert(observer)
            if flight.completed { continuation.resume(returning: flight.data); return }
            flight.waiters[observer] = continuation
            guard flight.task == nil else { return }
            let id = flight.id
            flight.task = Task { [weak self] in
                guard let self else { return }
                let data = await download(url)
                finishNetwork(data, for: url, id: id)
            }
        }
    }

    private func finishNetwork(_ data: Data?, for url: URL, id: UUID) {
        guard let flight = networkFlights[url], flight.id == id else { return }
        flight.completed = true
        flight.data = data
        flight.task = nil
        let waiters = flight.waiters
        flight.waiters.removeAll()
        for continuation in waiters.values { continuation.resume(returning: data) }
    }

    private func removeNetworkObserver(_ observer: UUID, for url: URL) {
        guard let flight = networkFlights[url], flight.observers.remove(observer) != nil else { return }
        flight.waiters.removeValue(forKey: observer)?.resume(returning: nil)
        if flight.observers.isEmpty {
            flight.task?.cancel()
            networkFlights[url] = nil
        }
    }

    private func persistOriginal(_ data: Data, for url: URL, observer: UUID) async {
        guard let flight = networkFlights[url], flight.observers.contains(observer) else { return }
        if flight.persistence == nil {
            let disk = disk
            flight.persistence = Task(priority: .utility) {
                await disk.store(data, for: url.absoluteString)
                NotificationCenter.default.post(name: .stacklumeSearchContentDidChange, object: url)
            }
        }
        await flight.persistence?.value
    }

    private func decodedImage(_ data: Data, for url: URL, maxPixels: Int) async -> ImageValue? {
        guard !Task.isCancelled else { return nil }
        if let image = cached(for: url, maxPixels: maxPixels) { return ImageValue(image) }
        let key = Self.cacheKey(url, maxPixels: maxPixels) as String
        let observer = UUID()
        let value: ImageValue? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                let flight = decodeFlights[key] ?? DecodeFlight()
                decodeFlights[key] = flight
                flight.waiters[observer] = continuation
                guard flight.task == nil else { return }
                let id = flight.id
                flight.task = Task { [weak self] in
                    let decoded = await SafeRemoteImageDecoder.shared.image(from: data, maxPixels: maxPixels)
                    guard !Task.isCancelled else { return }
                    self?.finishDecode(decoded, for: key, id: id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.removeDecodeObserver(observer, for: key) }
        }
        return Task.isCancelled ? nil : value
    }

    private func finishDecode(_ decoded: CGImage?, for key: String, id: UUID) {
        guard let flight = decodeFlights[key], flight.id == id else { return }
        decodeFlights[key] = nil
        let value = decoded.map { ImageValue(Self.platformImage($0)) }
        if let decoded, let value {
            cache.setObject(value.image, forKey: key as NSString, cost: decoded.bytesPerRow * decoded.height)
        }
        for continuation in flight.waiters.values { continuation.resume(returning: value) }
    }

    private func removeDecodeObserver(_ observer: UUID, for key: String) {
        guard let flight = decodeFlights[key] else { return }
        flight.waiters.removeValue(forKey: observer)?.resume(returning: nil)
        if flight.waiters.isEmpty {
            flight.task?.cancel()
            decodeFlights[key] = nil
        }
    }

    private func download(_ url: URL) async -> Data? {

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(
            "Mozilla/5.0 (Macintosh; Apple Silicon Mac OS X 26_0) AppleWebKit/605.1.15 Stacklume/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("image/*,*/*;q=0.2", forHTTPHeaderField: "Accept")

        do {
            let result = try await ExternalHTTPClient.shared.data(
                for: request,
                maximumBytes: Self.maximumImageBytes
            )
            guard !Task.isCancelled else { return nil }
            return result.data
        } catch ExternalHTTPError.unacceptableStatus(let status) {
            guard !Task.isCancelled else { return nil }
            if status == 404 || status == 410 { permanentlyFailed.insert(url) }
            let message: String
            switch status {
            case 404, 410: message = "El proveedor ya no ofrece esta muestra (HTTP \(status))."
            case 401, 403: message = "El proveedor denegó el acceso a esta muestra (HTTP \(status))."
            case 429: message = "El proveedor ha limitado las consultas de imágenes (HTTP 429)."
            default: message = "No se pudo obtener la muestra (HTTP \(status))."
            }
            recordFailure(message, for: url)
            return nil
        } catch {
            if !Task.isCancelled { recordFailure("No se pudo adquirir la muestra. Comprueba la conexión o vuelve a intentarlo.", for: url) }
            return nil
        }
    }

    private static func platformImage(_ image: CGImage) -> PlatformImage {
        #if canImport(AppKit)
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        #else
        PlatformImage(cgImage: image)
        #endif
    }

}

struct SecureRemoteImage<Placeholder: View>: View {
    private let candidates: [String]
    private let maxPixels: Int
    private let placeholder: Placeholder
    private let skeleton: AnyView?

    @State private var storage = SecureRemoteImageStorage()
    @State private var hasImage = false
    @State private var finishedLoading = false
    @State private var cacheRevision = 0

    @MainActor
    init(candidates: [String?], maxPixels: Int = 1_024, @ViewBuilder placeholder: () -> Placeholder) {
        self.init(candidates: candidates, maxPixels: maxPixels, skeleton: nil, placeholder: placeholder)
    }

    @MainActor
    init<Skeleton: View>(
        candidates: [String?],
        maxPixels: Int = 1_024,
        @ViewBuilder skeleton: () -> Skeleton,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.init(candidates: candidates, maxPixels: maxPixels, skeleton: AnyView(skeleton()), placeholder: placeholder)
    }

    @MainActor
    private init(
        candidates: [String?],
        maxPixels: Int,
        skeleton: AnyView?,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        let cleaned = candidates.compactMap { candidate -> String? in
            guard let candidate else { return nil }
            let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        self.candidates = cleaned
        let pixelLimit = min(4_096, max(1, maxPixels))
        self.maxPixels = pixelLimit
        self.placeholder = placeholder()
        self.skeleton = skeleton
    }

    var body: some View {
        ZStack {
            if hasImage {
                SecureRemoteImageRenderer(storage: storage)
            } else if let skeleton, !finishedLoading, !candidates.isEmpty {
                skeleton
            } else {
                placeholder
            }
        }
        .animation(.easeOut(duration: 0.3), value: hasImage)
        .task(id: SecureRemoteImageLoadID(candidates: candidates, maxPixels: maxPixels, revision: cacheRevision)) { await load() }
        .onDisappear {
            storage.setImage(nil)
            hasImage = false
            finishedLoading = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .stacklumeSearchContentDidChange)) { notification in
            guard !hasImage, let url = notification.object as? URL,
                  candidates.contains(url.absoluteString) else { return }
            cacheRevision &+= 1
        }
    }

    private func load() async {
        guard !Task.isCancelled else { return }
        storage.setImage(nil)
        hasImage = false
        finishedLoading = false
        let urls = candidates.compactMap(URL.init(string:))
        for url in urls {
            guard !Task.isCancelled else { return }
            if let cached = SecureImageCache.shared.cached(for: url, maxPixels: maxPixels) {
                storage.setImage(cached)
                hasImage = true
                finishedLoading = true
                return
            }
            if let loaded = await SecureImageCache.shared.storedImage(for: url, maxPixels: maxPixels) {
                guard !Task.isCancelled else { return }
                storage.setImage(loaded)
                hasImage = true
                finishedLoading = true
                return
            }
        }
        for url in urls {
            guard !Task.isCancelled else { return }
            if let loaded = await SecureImageCache.shared.image(for: url, maxPixels: maxPixels) {
                guard !Task.isCancelled else { return }
                storage.setImage(loaded)
                hasImage = true
                finishedLoading = true
                return
            }
        }
        if !Task.isCancelled { finishedLoading = true }
    }
}

private struct SecureRemoteImageLoadID: Hashable {
    let candidates: [String]
    let maxPixels: Int
    let revision: Int
}

// SwiftUI puede conservar el árbol fuera de pantalla; la caja permite liberar
// el bitmap sin depender de que vuelva a evaluar la vista representada.
@MainActor final class SecureRemoteImageStorage {
    private(set) var image: NSImage?
    fileprivate weak var renderer: SecureRemoteImageDrawingView?
    func setImage(_ value: NSImage?) {
        image = value
        renderer?.needsDisplay = true
        renderer?.setAccessibilityLabel(value?.accessibilityDescription ?? "Imagen")
        if value == nil { renderer?.layer?.contents = nil }
    }
}
struct SecureRemoteImageRenderer: NSViewRepresentable {
    let storage: SecureRemoteImageStorage
    func makeNSView(context: Context) -> NSView {
        let view = SecureRemoteImageDrawingView()
        view.storage = storage
        storage.renderer = view
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel(storage.image?.accessibilityDescription ?? "Imagen")
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? SecureRemoteImageDrawingView else { return }
        view.storage = storage
        storage.renderer = view
        view.needsDisplay = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        let size = proposal.replacingUnspecifiedDimensions()
        return CGSize(width: size.width.isFinite ? size.width : 10, height: size.height.isFinite ? size.height : 10)
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        guard let view = nsView as? SecureRemoteImageDrawingView else { return }
        view.storage = nil
        view.layer?.contents = nil
    }
}
private final class SecureRemoteImageDrawingView: NSView {
    var storage: SecureRemoteImageStorage?
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let image = storage?.image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let target = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)
        bounds.clip()
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
    }
}
