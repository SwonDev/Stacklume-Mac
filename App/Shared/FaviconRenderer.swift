import AppKit
@preconcurrency import WebKit

/// Metadatos leídos de la página YA RENDERIZADA (tras ejecutar su JavaScript): el favicon real
/// y el título en vivo. Sirve para webs que inyectan estos datos por JS (Framer/Webflow/SPA),
/// cuyo HTML estático trae un favicon ausente y a veces un título VIEJO.
struct RenderedMeta: Sendable {
    let favicon: String?
    let title: String?
    /// Texto REAL de la página ya renderizada (innerText), para FUNDAMENTAR la descripción y la
    /// categoría de la IA en webs JS cuyo HTML estático no trae prosa (si no, la IA adivinaría
    /// mal por el nombre, p. ej. «Islet» → «Videojuegos»). `nil`/corto = no aprovechable.
    let text: String?
}

/// ÚLTIMO RECURSO para obtener el favicon (y el título en vivo) de webs que los INYECTAN con
/// JavaScript: su HTML estático no trae `<link rel="icon">` ni el título actual. La única forma
/// es renderizar la página y leer el DOM ya inyectado.
///
/// Caro (abre un `WKWebView` fuera de pantalla), así que se usa SOLO cuando la cascada barata
/// falla, y serializado (una página a la vez), igual que [[PageSnapshotService]]. 100 % local.
@MainActor
enum FaviconRenderer {

    /// Cola SERIE: una página a la vez (no agotar memoria/GPU al curar muchos).
    private static var tail: Task<RenderedMeta, Never>?

    /// Renderiza la página y devuelve su favicon real (URL absoluta) y su título en vivo. Campos
    /// `nil` si no hay o no carga a tiempo. NO valida que el favicon sea imagen real: lo hace quien
    /// llama (probándolo con la caché de imágenes).
    static func render(of rawURL: String) async -> RenderedMeta {
        let normalized = rawURL.contains("://") ? rawURL : "https://" + rawURL
        guard let url = StacklumeAutomationPolicy.openableStoredURL(normalized),
              StacklumeAutomationPolicy.allowsAutomaticNetworkURL(url),
              let host = url.host(),
              await Task.detached(priority: .utility, operation: {
                  AssistantHostResolver.hasOnlyPublicAddresses(host)
              }).value else {
            return RenderedMeta(favicon: nil, title: nil, text: nil)
        }
        let previous = tail
        let task = Task { @MainActor () -> RenderedMeta in
            _ = await previous?.value
            return await RenderDriver(url: url).run()
        }
        tail = task
        return await task.value
    }
}

/// Conductor de UNA extracción: web view + ventana fuera de pantalla, carga la URL, espera a que
/// el JS asiente, y lee favicon + título del DOM. Resuelve la continuación una sola vez.
@MainActor
private final class RenderDriver: NSObject, WKNavigationDelegate {
    private let url: URL
    private let size = CGSize(width: 600, height: 600)
    /// Margen para que el JS inyecte el favicon/título antes de leerlos.
    private let settleDelay: Duration = .seconds(2.0)
    private let timeout: Duration = .seconds(18)

    private var window: NSWindow?
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<RenderedMeta, Never>?
    private var finished = false

    /// Lee del DOM renderizado el mejor `<link rel="icon|apple-touch-icon">` (prefiere mayor
    /// `sizes`; `el.href` resuelve a absoluta) y el `document.title`. Devuelve JSON `{f,t}`.
    private static let extractJS = """
    (function(){
      try {
        var sels = ['link[rel~="icon"]','link[rel="shortcut icon"]','link[rel="apple-touch-icon"]','link[rel="apple-touch-icon-precomposed"]','link[rel="mask-icon"]'];
        var best = '', bestSize = -1;
        for (var i=0;i<sels.length;i++){
          var els = document.querySelectorAll(sels[i]);
          for (var j=0;j<els.length;j++){
            var el = els[j]; var href = el.href; if(!href) continue;
            var sz = 0; var s = el.getAttribute('sizes');
            if (s){ var m = s.match(/(\\d+)/); if(m) sz = parseInt(m[1]); }
            if (el.rel && el.rel.indexOf('apple') >= 0 && sz === 0) sz = 180;
            if (sz > bestSize){ best = href; bestSize = sz; }
          }
        }
        var txt = '';
        try { txt = (document.body ? (document.body.innerText || '') : '').replace(/\\s+/g,' ').trim().slice(0, 4000); } catch(e){}
        return JSON.stringify({ f: best, t: (document.title || ''), x: txt });
      } catch(e){ return '{}'; }
    })()
    """

    init(url: URL) { self.url = url; super.init() }

    func run() async -> RenderedMeta {
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
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        let win = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: size),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = web
        win.orderFrontRegardless()
        webView = web
        window = win
        web.load(URLRequest(url: url))

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.timeout ?? .seconds(18))
            self?.finish(nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finished else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.settleDelay)
            self.extract()
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

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }

    private func extract() {
        guard !finished, let web = webView else { return }
        web.evaluateJavaScript(Self.extractJS) { [weak self] result, _ in
            MainActor.assumeIsolated { self?.finish(result as? String) }
        }
    }

    private func finish(_ json: String?) {
        guard !finished else { return }
        finished = true
        let meta = Self.parse(json)
        window?.orderOut(nil)
        window?.contentView = nil
        webView?.navigationDelegate = nil
        webView = nil
        window = nil
        continuation?.resume(returning: meta)
        continuation = nil
    }

    /// Parsea el JSON `{f,t}` del DOM. El favicon solo se acepta http(s) absoluto.
    private static func parse(_ json: String?) -> RenderedMeta {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return RenderedMeta(favicon: nil, title: nil, text: nil) }
        var favicon: String? = nil
        if let f = (obj["f"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty,
           let u = StacklumeAutomationPolicy.openableStoredURL(f),
           StacklumeAutomationPolicy.allowsAutomaticNetworkURL(u) {
            favicon = u.absoluteString
        }
        var title: String? = nil
        if let t = (obj["t"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            title = t
        }
        var text: String? = nil
        if let x = (obj["x"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), x.count >= 80 {
            text = x
        }
        return RenderedMeta(favicon: favicon, title: title, text: text)
    }
}
