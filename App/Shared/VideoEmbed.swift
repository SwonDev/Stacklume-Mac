import SwiftUI
import WebKit
import AppKit

/// Construye la URL del REPRODUCTOR EMBEBIDO de un enlace de vídeo (YouTube/Vimeo) a partir de
/// su URL normal, para verlo DENTRO de la app sin abrir el navegador. `nil` si el enlace no es
/// un vídeo embebible conocido (entonces la ficha muestra su miniatura de siempre).
enum VideoEmbed {

    /// URL del reproductor embebido para YouTube (incl. `youtu.be`, Shorts, `live`) y Vimeo.
    /// Conserva el segundo de inicio (`t`/`start`) y activa autoplay (solo se carga cuando el
    /// usuario pulsa «reproducir», así que reproducir al instante es lo esperado).
    static func embedURL(for urlString: String) -> URL? {
        guard let comps = URLComponents(string: urlString), let rawHost = comps.host?.lowercased() else { return nil }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let parts = comps.path.split(separator: "/").map(String.init)

        // YouTube ───────────────────────────────────────────────
        if host == "youtu.be" {
            return youtube(parts.first, start: startSeconds(comps))
        }
        if host.hasSuffix("youtube.com") {
            if comps.path == "/watch",
               let v = comps.queryItems?.first(where: { $0.name == "v" })?.value {
                return youtube(v, start: startSeconds(comps))
            }
            if parts.count >= 2, ["embed", "shorts", "live", "v"].contains(parts[0]) {
                return youtube(parts[1], start: startSeconds(comps))
            }
        }

        // Vimeo ─────────────────────────────────────────────────
        if host == "vimeo.com", let id = parts.first, id.allSatisfy(\.isNumber) {
            return URL(string: "https://player.vimeo.com/video/\(id)?autoplay=1")
        }
        if host == "player.vimeo.com" {
            return URL(string: urlString)
        }

        // Twitch ────────────────────────────────────────────────  (parent = origen del baseURL)
        if host == "twitch.tv" {
            if parts.count >= 2, parts[0] == "videos" {
                return URL(string: "https://player.twitch.tv/?video=\(parts[1])&parent=stacklume.app&autoplay=true")
            }
            if parts.count >= 3, parts[1] == "clip" {
                return URL(string: "https://clips.twitch.tv/embed?clip=\(parts[2])&parent=stacklume.app&autoplay=true")
            }
            if parts.count == 1 {
                return URL(string: "https://player.twitch.tv/?channel=\(parts[0])&parent=stacklume.app&autoplay=true")
            }
        }
        if host == "clips.twitch.tv", let clip = parts.first {
            return URL(string: "https://clips.twitch.tv/embed?clip=\(clip)&parent=stacklume.app&autoplay=true")
        }

        // Dailymotion ───────────────────────────────────────────
        if host == "dailymotion.com", parts.count >= 2, parts[0] == "video" {
            let id = parts[1].split(separator: "_").first.map(String.init) ?? parts[1]
            return URL(string: "https://www.dailymotion.com/embed/video/\(id)?autoplay=1")
        }
        if host == "dai.ly", let id = parts.first {
            return URL(string: "https://www.dailymotion.com/embed/video/\(id)?autoplay=1")
        }

        // Loom ──────────────────────────────────────────────────
        if host == "loom.com", parts.count >= 2, parts[0] == "share" {
            return URL(string: "https://www.loom.com/embed/\(parts[1])")
        }
        return nil
    }

    private static func youtube(_ id: String?, start: Int?) -> URL? {
        guard let id, !id.isEmpty else { return nil }
        var query = "autoplay=1&rel=0"
        if let start, start > 0 { query += "&start=\(start)" }
        return URL(string: "https://www.youtube.com/embed/\(id)?\(query)")
    }

    /// Segundo de inicio de `t`/`start`. Admite «90» y «90s»; ignora formatos raros (`1m30s`).
    private static func startSeconds(_ comps: URLComponents) -> Int? {
        guard let raw = comps.queryItems?.first(where: { $0.name == "t" || $0.name == "start" })?.value
        else { return nil }
        return Int(raw.hasSuffix("s") ? String(raw.dropLast()) : raw)
    }
}

/// Posición de reproducción del reproductor inline, para REANUDAR al sacarlo a ventana (PiP /
/// pantalla completa) sin empezar de cero.
@MainActor
@Observable
final class VideoPlaybackState {
    var currentTime: Double = 0
}

/// Fábrica del `WKWebView` del reproductor con TODO lo común: reproducción sin gesto previo,
/// pantalla completa habilitada, bloqueo de anuncios (reglas + script) y el `<iframe>` del
/// reproductor con `baseURL` NEUTRAL (si no, YouTube ve una página «falsa» → «Error 153»).
@MainActor
enum VideoPlayerFactory {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    static func makeWebView(embedURL: URL, startAt: Double = 0,
                            timeHandler: VideoTimeHandler? = nil,
                            errorHandler: VideoErrorHandler? = nil) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.userContentController.addUserScript(VideoAdBlock.adSkipScript)
        if let timeHandler {
            config.userContentController.add(
                timeHandler,
                contentWorld: .defaultClient,
                name: "stkTime"
            )
            config.userContentController.addUserScript(VideoAdBlock.timeScript)
        }
        if let errorHandler {
            config.userContentController.add(
                errorHandler,
                contentWorld: .defaultClient,
                name: "stkError"
            )
            config.userContentController.addUserScript(VideoAdBlock.errorScript)
        }
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = userAgent
        var src = embedURL.absoluteString
        if startAt > 1 { src += (src.contains("?") ? "&" : "?") + "start=\(Int(startAt))" }
        Task { @MainActor in
            if let youtube = await VideoAdBlock.youtubeRuleList() {
                web.configuration.userContentController.add(youtube)
            }
            web.loadHTMLString(html(src: src), baseURL: URL(string: "https://stacklume.app"))
        }
        return web
    }

    static func html(src: String) -> String {
        """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;padding:0;background:#000;height:100%;overflow:hidden}
        iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style></head>
        <body><iframe src="\(src)"
          allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
          allowfullscreen></iframe></body></html>
        """
    }
}

/// Recibe el `currentTime` del vídeo (vía `postMessage`) para reanudar al sacar a ventana.
final class VideoTimeHandler: NSObject, WKScriptMessageHandler {
    private let onTime: @MainActor (Double) -> Void
    init(onTime: @escaping @MainActor (Double) -> Void) { self.onTime = onTime; super.init() }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let time = message.body as? Double else { return }
        Task { @MainActor in onTime(time) }
    }
}

/// Avisa de que el reproductor mostró un ERROR (p. ej. el autor desactivó la incrustación), para
/// que la ficha vuelva a la miniatura en vez de dejar el mensaje de error de YouTube.
final class VideoErrorHandler: NSObject, WKScriptMessageHandler {
    private let onError: @MainActor () -> Void
    init(onError: @escaping @MainActor () -> Void) { self.onError = onError; super.init() }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor in onError() }
    }
}

/// Reproductor de vídeo embebido INLINE en la ficha. Va actualizando `state.currentTime` para
/// que al sacarlo a ventana (PiP/pantalla completa) reanude donde estaba.
struct VideoEmbedView: NSViewRepresentable {
    let url: URL
    var state: VideoPlaybackState? = nil
    /// Segundo en el que empezar (reanudar). Se llama si el reproductor muestra un error.
    var startAt: Double = 0
    /// Clave (URL del enlace) para PERSISTIR el progreso de visionado y poder «continuar viendo».
    var progressKey: String? = nil
    var onError: (@MainActor () -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let state = self.state
        let progressKey = self.progressKey
        let timeHandler: VideoTimeHandler? = (state != nil || progressKey != nil)
            ? VideoTimeHandler { time in
                state?.currentTime = time
                if let progressKey { VideoProgressStore.save(time, for: progressKey) }
            }
            : nil
        let errorHandler = onError.map { cb in VideoErrorHandler(onError: cb) }
        return VideoPlayerFactory.makeWebView(embedURL: url, startAt: startAt,
                                              timeHandler: timeHandler, errorHandler: errorHandler)
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        // La ficha recrea la vista por enlace (`.id(link.id)`), así que no hace falta recargar aquí.
    }
}

/// Saca el reproductor a una VENTANA de macOS NATIVA: con el botón verde da pantalla completa
/// REAL (lo que el fullscreen del WebView NO conseguía: dejaba el vídeo pequeño sobre negro), y
/// en modo flotante pequeño hace de IMAGEN SOBRE IMAGEN (PiP) —siempre encima y movible—. Es
/// 100 % fiable porque NO depende de las APIs de PiP/fullscreen del WebView (restringidas para
/// iframes de origen cruzado), solo de AppKit. Una sola ventana a la vez.
@MainActor
final class VideoWindowController: NSObject, NSWindowDelegate {
    static let shared = VideoWindowController()
    private var window: NSWindow?

    /// Abre el reproductor en ventana. `floating`: ventana pequeña siempre-encima que se muestra
    /// SIN robar el foco (la app sigue usándose mientras el vídeo flota) = imagen sobre imagen
    /// (PiP). `fullscreen`: ventana en pantalla completa REAL. `startAt`: segundo de reanudación.
    func open(embedURL: URL, startAt: Double, floating: Bool, fullscreen: Bool, title: String = "Reproductor") {
        closeWindow()
        let web = VideoPlayerFactory.makeWebView(embedURL: embedURL, startAt: startAt)
        let size = floating ? NSSize(width: 480, height: 286) : NSSize(width: 1040, height: 620)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = title.isEmpty ? "Reproductor" : title
        window.contentView = web
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 320, height: 180)
        window.aspectRatio = NSSize(width: 16, height: 9)
        window.center()
        self.window = window

        if floating {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.hidesOnDeactivate = false
            window.orderFrontRegardless()      // mostrar SIN activar/robar el foco → app usable
        } else {
            window.collectionBehavior = [.fullScreenPrimary]
            window.makeKeyAndOrderFront(nil)
            window.toggleFullScreen(nil)
        }
    }

    func closeWindow() {
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

/// Bloqueo de anuncios para el reproductor de vídeo embebido. Combina reglas de red de los
/// dominios/endpoints de anuncios de YouTube (vía `WKContentRuleList`, el motor de Brave/Safari)
/// con un script que salta los anuncios que igualmente lleguen al reproductor.
@MainActor
enum VideoAdBlock {

    /// Lista de reglas (cacheada/persistida por WebKit) para los anuncios de YouTube. Bloquea sus
    /// endpoints de PRIMERA parte (que las listas genéricas no tocan para no romper el sitio) y los
    /// dominios de ads de Google, SIN tocar `googlevideo.com` (el CDN del vídeo real).
    static func youtubeRuleList() async -> WKContentRuleList? {
        guard let store = WKContentRuleListStore.default() else { return nil }
        let id = "stacklume-video-adblock-v1"
        if let existing = await lookUp(store, id) { return existing }
        return try? await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: rulesJSON())
    }

    private static func lookUp(_ store: WKContentRuleListStore, _ id: String) async -> WKContentRuleList? {
        await withCheckedContinuation { cont in
            store.lookUpContentRuleList(forIdentifier: id) { list, _ in cont.resume(returning: list) }
        }
    }

    private static func rulesJSON() -> String {
        let patterns = [
            "^https?://([^/]+\\.)?youtube\\.com/api/stats/ads",
            "^https?://([^/]+\\.)?youtube\\.com/pagead/",
            "^https?://([^/]+\\.)?youtube\\.com/ptracking",
            "^https?://([^/]+\\.)?youtube\\.com/get_midroll_",
            "^https?://([^/]+\\.)?youtube\\.com/api/stats/qoe.*adformat",
            "^https?://([^/]+\\.)?doubleclick\\.net",
            "^https?://([^/]+\\.)?googlesyndication\\.com",
            "^https?://([^/]+\\.)?googleadservices\\.com",
            "^https?://([^/]+\\.)?google\\.com/pagead",
            "^https?://([^/]+\\.)?2mdn\\.net",
            "^https?://([^/]+\\.)?googletagservices\\.com",
        ]
        let rules = patterns.map { ["trigger": ["url-filter": $0], "action": ["type": "block"]] }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// Script que salta los anuncios del reproductor de YouTube: pulsa «Saltar anuncios», adelanta
    /// los anuncios no saltables hasta el final y los silencia (devolviendo el sonido al acabar).
    /// `forMainFrameOnly: false` para que corra dentro del iframe de youtube.com.
    static let adSkipScript = WKUserScript(source: """
    (function(){
      var mutedByAd = false;
      function tick(){
        try {
          var player = document.querySelector('.html5-video-player');
          var video = document.querySelector('video');
          var adShowing = player && player.classList.contains('ad-showing');
          var skip = document.querySelector('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytp-ad-skip-button-container button');
          if (skip) { skip.click(); }
          if (adShowing && video) {
            if (isFinite(video.duration) && video.duration > 0) { video.currentTime = video.duration; }
            if (!video.muted) { video.muted = true; mutedByAd = true; }
          } else if (mutedByAd && video) {
            video.muted = false; mutedByAd = false;
          }
          var overlay = document.querySelector('.ytp-ad-overlay-close-button, .ytp-ad-overlay-close-container');
          if (overlay) { overlay.click(); }
        } catch (e) {}
      }
      setInterval(tick, 400);
    })();
    """, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient)

    /// Reporta el segundo actual del vídeo a la app (para reanudar al sacar a ventana).
    static let timeScript = WKUserScript(source: """
    setInterval(function(){
      try {
        var v = document.querySelector('video');
        if (v && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.stkTime) {
          window.webkit.messageHandlers.stkTime.postMessage(v.currentTime || 0);
        }
      } catch (e) {}
    }, 1000);
    """, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient)

    /// Detecta si el reproductor de YouTube muestra un ERROR (incrustación desactivada por el autor,
    /// vídeo no disponible…) y avisa a la app UNA vez para que vuelva a la miniatura.
    static let errorScript = WKUserScript(source: """
    (function(){
      var sent = false;
      setInterval(function(){
        if (sent) return;
        try {
          if (document.querySelector('.ytp-error, .ytp-error-content-wrap')) {
            sent = true;
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.stkError) {
              window.webkit.messageHandlers.stkError.postMessage('error');
            }
          }
        } catch (e) {}
      }, 1200);
    })();
    """, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient)
}
