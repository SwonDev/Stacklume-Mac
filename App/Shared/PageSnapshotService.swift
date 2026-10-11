import AppKit
@preconcurrency import WebKit

/// Renderiza una página en un `WKWebView` FUERA DE PANTALLA y captura su viewport (el
/// «hero» que ve el usuario). Resuelve el caso de las SPAs / `canvas` / WebGL —como
/// buildwithstem.com (StemStudio), cuyo hero es un Three.js— que NO exponen `og:image`
/// ni `<img>` en el HTML estático: lo único que captura su portada real es una foto de la
/// página ya renderizada (igual que la «copia permanente» con captura de Raindrop).
/// 100 % local: no sube la página a ningún servicio externo.
@MainActor
enum PageSnapshotService {

    /// Cola SERIE: solo se renderiza UNA página a la vez. Cada captura abre su propia
    /// ventana `WKWebView`; lanzar muchas en paralelo —p. ej. al rellenar portadas de
    /// cientos de enlaces en un enriquecido masivo o una importación— agotaría memoria y
    /// GPU. Cada captura espera a que termine la anterior (el último `Task` encadena al
    /// previo; al completarse, cada uno suelta su referencia al anterior → sin fuga).
    private static var tail: Task<NSImage?, Never>?

    /// Captura el viewport de la página renderizada. `nil` si no carga a tiempo o falla el
    /// render. La operación tarda unos segundos (carga + asentado de JS + foto) y se
    /// serializa con las demás capturas en curso.
    static func snapshot(of rawURL: String, useCached: Bool = false) async -> NSImage? {
        let normalized = rawURL.contains("://") ? rawURL : "https://" + rawURL
        if useCached, let data = await EmbeddingGemmaCorpus.shared.pageSnapshot(for: normalized),
           let image = CoverImage.decodedThumbnail(data,
               maximumInputBytes: SecureImageCache.maximumImageBytes, maxDimension: 1280) {
            return image
        }
        guard let url = StacklumeAutomationPolicy.openableStoredURL(normalized),
              StacklumeAutomationPolicy.allowsAutomaticNetworkURL(url),
              let host = url.host(),
              await Task.detached(priority: .utility, operation: {
                  AssistantHostResolver.hasOnlyPublicAddresses(host)
              }).value else { return nil }
        let previous = tail
        let task = Task { @MainActor () -> NSImage? in
            _ = await previous?.value            // serializa: espera la captura anterior
            return await SnapshotDriver(url: url).run()
        }
        tail = task
        let image = await task.value
        if let image, let data = CoverImage.downscaledJPEG(image, maxDimension: 1280, quality: 0.85) {
            try? await EmbeddingGemmaCorpus.shared.savePageSnapshot(data, for: normalized)
            NotificationCenter.default.post(name: .stacklumeSearchContentDidChange, object: url)
        }
        return image
    }
}

/// Conductor de UNA captura: posee el web view + una ventana fuera de pantalla (necesaria
/// para que el contexto GPU pinte `canvas`/WebGL; sin ventana real saldrían en blanco),
/// carga la URL, espera a que la página «asiente» y hace la foto. Resuelve la continuación
/// una sola vez (carga ok, fallo o timeout).
@MainActor
private final class SnapshotDriver: NSObject, WKNavigationDelegate {
    private let url: URL
    /// 1280×832 ≈ 1,54:1: proporción de hero típica, encuadre por encima del pliegue.
    private let size = CGSize(width: 1280, height: 832)
    /// Margen para que el JS y el `canvas`/WebGL terminen de pintar antes de la foto.
    private let settleDelay: Duration = .seconds(2.6)
    private let timeout: Duration = .seconds(22)

    private var window: NSWindow?
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private var finished = false

    init(url: URL) { self.url = url; super.init() }

    func run() async -> NSImage? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            start()
        }
    }

    private func start() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        web.navigationDelegate = self
        // UA de Safari de escritorio: muchas SPAs sirven mejor layout/recursos a escritorio.
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

        // Ventana fuera de pantalla (invisible, en −30000,−30000): da un backing real para
        // que el contenido —incluido WebGL— se pinte y la captura no salga en blanco.
        let win = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: size),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = web
        win.isReleasedWhenClosed = false
        win.ignoresMouseEvents = true
        win.orderFrontRegardless()

        self.webView = web
        self.window = win

        // Adblock (mismas rule lists que el lector): evita fotografiar banners de cookies
        // o anuncios sobre el hero. Best-effort; si no hay lista, se carga igual.
        Task { @MainActor [weak self] in
            guard let self, let web = self.webView else { return }
            if let list = await AdBlocker.shared.ruleList() {
                web.configuration.userContentController.add(list)
            }
            web.load(URLRequest(url: self.url))
        }

        // Timeout: en vez de rendirse, CAPTURA lo que haya renderizado hasta ahora (la home).
        // Muchas SPAs (p. ej. macfolio, con un modal de login) no disparan `didFinish` limpio,
        // pero a los ~22 s ya están pintadas: así NINGÚN enlace se queda sin imagen por no
        // disparar `didFinish`. Si la navegación falló de verdad, `didFail` ya cerró con nil.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.timeout ?? .seconds(22))
            self?.capture()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finished else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.settleDelay)
            self.capture()
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame != false,
              let destination = navigationAction.request.url,
              StacklumeAutomationPolicy.allowsAutomaticNetworkURL(destination),
              destination.host().map(AssistantHostResolver.hasOnlyPublicAddresses) == true
        else {
            decisionHandler(.cancel)
            finish(nil)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    private func capture() {
        guard !finished, let web = webView else { return }
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: size)
        config.afterScreenUpdates = true
        web.takeSnapshot(with: config) { [weak self] image, _ in
            MainActor.assumeIsolated { self?.finish(image) }
        }
    }

    private func finish(_ image: NSImage?) {
        guard !finished else { return }
        finished = true
        // Validación mínima: una foto real y no trivial (evita capturas vacías de 0 px).
        let valid: NSImage? = (image.map { min($0.size.width, $0.size.height) >= 200 } == true) ? image : nil
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        window = nil
        continuation?.resume(returning: valid)
        continuation = nil
    }
}
