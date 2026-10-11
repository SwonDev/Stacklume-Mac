import SwiftUI
import CryptoKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Caché en disco PERSISTENTE de los bytes de las imágenes remotas ya descargadas.
/// Esta app es 100 % local: una imagen (portada/favicon) que se bajó con éxito UNA vez
/// no debe volver a pedirse a la red en arranques posteriores. La `NSCache` en memoria de
/// `ImageCache` se vacía en cada arranque en frío y el `URLCache` del sistema depende de
/// las cabeceras `Cache-Control` del origen (muchas CDN mandan `no-store`) y de su tope
/// de capacidad, así que NO garantizaba persistencia → al hacer scroll en una biblioteca
/// grande las portadas se re-descargaban una y otra vez. Esta caché propia sí lo garantiza:
/// guarda los bytes originales en `Application Support/Stacklume/RemoteImageCache` y los
/// sirve sin tocar la red. Es un `actor` para que el I/O de disco NO bloquee el render.
actor DiskImageCache {
    static let shared = DiskImageCache()

    private let dir: URL?
    /// Tope generoso (el usuario: «no importa el tamaño, es una app local»). Solo se recorta
    /// si se supera, borrando lo más antiguo primero. Una imagen rara vez supera unos cientos
    /// de KB, así que 2 GB cubren decenas de miles de portadas sin recortar nunca en la práctica.
    private let maxBytes = 2 * 1024 * 1024 * 1024
    private var didTrim = false

    init() {
        let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true)
        let d = base?.appendingPathComponent("Stacklume/RemoteImageCache", isDirectory: true)
        if let d { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        dir = d
    }

    /// Nombre de archivo estable y sin colisiones a partir de la URL (SHA-256 hex). No se usa
    /// `String.hashValue` porque su semilla cambia entre arranques (no sería estable en disco).
    private static func fileName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(for key: String) -> URL? {
        dir?.appendingPathComponent(Self.fileName(for: key))
    }

    /// Bytes en disco de una imagen ya cacheada, o `nil` si nunca se guardó. Lectura pura
    /// (sin tocar metadatos) para que el scroll no pague I/O extra.
    func data(for key: String) -> Data? {
        guard let url = fileURL(for: key) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Persiste los bytes descargados para futuros arranques. Escritura atómica.
    func store(_ data: Data, for key: String) {
        guard let url = fileURL(for: key) else { return }
        try? data.write(to: url, options: .atomic)
        if !didTrim { didTrim = true; trim() }   // recorte perezoso: una vez por sesión.
    }

    /// Recorta la caché si supera `maxBytes`, borrando los archivos más antiguos hasta bajar
    /// a ~75 % del tope. Best-effort; solo corre la primera vez que se escribe en la sesión.
    private func trim() {
        guard let dir else { return }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: Array(keys)) else { return }
        var entries: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for f in files {
            let v = try? f.resourceValues(forKeys: keys)
            let size = v?.fileSize ?? 0
            entries.append((f, size, v?.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > maxBytes else { return }
        let target = maxBytes * 3 / 4
        for e in entries.sorted(by: { $0.date < $1.date }) where total > target {
            try? FileManager.default.removeItem(at: e.url)
            total -= e.size
        }
    }
}

/// Caché de imágenes remotas (memoria + disco persistente propio + disco vía URLCache).
/// Garantiza que los favicons y previews se carguen de forma fiable y rápida, y que NO se
/// vuelvan a descargar de la red una vez bajados (ver `DiskImageCache`).
@MainActor
public final class ImageCache {
    public static let shared = ImageCache()

    private let cache = NSCache<NSURL, PlatformImage>()
    private let session: URLSession
    private var failed: Set<URL> = []

    private init() {
        // Límite explícito de la caché en memoria: así NO crece sin control y compite
        // con el modelo de IA por la RAM. La NSCache la purga bajo presión de memoria.
        // En macOS se sube MUCHO el nº de objetos: las listas densas muestran cientos de
        // FAVICONS (diminutos) a la vez y, con un tope bajo (250), al hacer scroll se
        // expulsaban y se re-cargaban/re-dibujaban sin parar → tirones. El tope por COSTE
        // (bytes) sigue acotando la memoria real (los favicons pesan poquísimo; las portadas
        // grandes se limitan por coste). En iOS se mantiene más conservador.
        #if canImport(UIKit)
        cache.countLimit = 500
        cache.totalCostLimit = 80 * 1024 * 1024
        #else
        cache.countLimit = 3000                     // miles de favicons diminutos en memoria
        cache.totalCostLimit = 192 * 1024 * 1024    // el coste real lo marcan las portadas
        #endif

        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 25 * 1024 * 1024,
                                          diskCapacity: 200 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)

        #if canImport(UIKit)
        // En macOS no existe el aviso de memoria de iOS; los límites fijos de la
        // NSCache bastan. Solo en iOS limpiamos los fallos transitorios al purgarse.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.failed.removeAll() }
        }
        #endif
    }

    /// Lectura síncrona de la caché en memoria (sin red), para evitar parpadeos
    /// al recrearse la vista.
    public func cached(for url: URL) -> PlatformImage? {
        cache.object(forKey: url as NSURL)
    }

    public func image(for url: URL) async -> PlatformImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if failed.contains(url) { return nil }

        let key = url.absoluteString
        // 1) Caché en disco PROPIA: si ya se descargó esta imagen alguna vez, se sirve desde
        //    disco SIN tocar la red (clave para el arranque en frío con miles de portadas).
        if let data = await DiskImageCache.shared.data(for: key),
           let image = PlatformImage(data: data) {
            cache.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image))
            return image
        }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 Stacklume/1.0",
            forHTTPHeaderField: "User-Agent")

        // Error de red/timeout → TRANSITORIO: NO se marca como fallido permanente, así
        // se reintenta al reaparecer la vista. (Antes, un timeout durante la carga del
        // modelo de IA dejaba el favicon genérico para siempre hasta reiniciar.)
        guard let (data, response) = try? await session.data(for: request) else {
            return nil
        }
        if let http = response as? HTTPURLResponse {
            let code = http.statusCode
            // Solo 404/410 son fallos definitivos (recurso inexistente). 5xx y otros
            // 4xx pueden ser transitorios → reintentar más tarde.
            if code == 404 || code == 410 { failed.insert(url); return nil }
            if !(200...399).contains(code) { return nil }
        }
        // Respuesta válida pero los datos no son una imagen → fallo definitivo.
        guard let image = PlatformImage(data: data) else {
            failed.insert(url); return nil
        }
        cache.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image))
        // 2) Persiste los bytes ORIGINALES en disco para no volver a bajarlos nunca. Off-main
        //    (detached) para no demorar la aparición de la imagen.
        Task.detached { await DiskImageCache.shared.store(data, for: key) }
        return image
    }

    /// Coste ≈ bytes en memoria, para acotar la `NSCache`. `UIImage` tiene `scale`; `NSImage`
    /// no, así que en macOS se usa el tamaño en puntos (aproximación suficiente).
    private static func cost(of image: PlatformImage) -> Int {
        #if canImport(UIKit)
        return Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        #else
        return Int(image.size.width * image.size.height * 4)
        #endif
    }
}

/// Imagen remota con cascada de candidatos: prueba cada URL en orden y, si todas
/// fallan, muestra el `placeholder`. Pensada para que SIEMPRE se vea algo.
///
/// Mientras carga (y solo si se aporta un `skeleton`) muestra ese placeholder
/// animado; al resolverse, la imagen entra con un cross-fade en vez de un «pop»
/// brusco. Sin `skeleton`, se comporta como antes: muestra el `placeholder` desde
/// el primer frame.
public struct RemoteImage<Placeholder: View>: View {
    private let candidates: [String]
    private let placeholder: Placeholder
    private let skeleton: AnyView?

    @State private var image: PlatformImage?
    /// `true` cuando ya se han probado todos los candidatos (haya imagen o no), para
    /// dejar de mostrar el skeleton y caer al placeholder si nada cargó.
    @State private var finishedLoading = false

    @MainActor
    public init(candidates: [String?], @ViewBuilder placeholder: () -> Placeholder) {
        self.init(candidates: candidates, skeleton: nil, placeholder: placeholder)
    }

    /// Variante con skeleton animado mientras carga (si hay candidatos a imagen).
    @MainActor
    public init<Skeleton: View>(candidates: [String?],
                                @ViewBuilder skeleton: () -> Skeleton,
                                @ViewBuilder placeholder: () -> Placeholder) {
        self.init(candidates: candidates, skeleton: AnyView(skeleton()), placeholder: placeholder)
    }

    @MainActor
    private init(candidates: [String?], skeleton: AnyView?,
                 @ViewBuilder placeholder: () -> Placeholder) {
        let cleaned: [String] = candidates.compactMap { url in
            guard let url, !url.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return url
        }
        self.candidates = cleaned
        self.placeholder = placeholder()
        self.skeleton = skeleton
        // Inicializa desde la caché en memoria de forma síncrona: si la vista se
        // recrea (reflujo, arrastre), la imagen ya está y no parpadea.
        let initial = cleaned.lazy.compactMap { URL(string: $0) }
            .compactMap { ImageCache.shared.cached(for: $0) }.first
        _image = State(initialValue: initial)
    }

    public var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFill()
            } else if let skeleton, !finishedLoading, !candidates.isEmpty {
                skeleton
            } else {
                placeholder
            }
        }
        // La imagen entra con un cross-fade suave en lugar de aparecer de golpe.
        .animation(.easeOut(duration: 0.3), value: image)
        .task(id: candidates) { await load() }
    }

    private func load() async {
        // No se borra la imagen actual: evita el parpadeo al re-renderizar.
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if let loaded = await ImageCache.shared.image(for: url) {
                if loaded != image { image = loaded }
                finishedLoading = true
                return
            }
        }
        finishedLoading = true
    }
}
