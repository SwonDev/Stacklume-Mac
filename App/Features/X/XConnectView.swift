import SwiftUI
import SwiftData
import WebKit
import StacklumeCore
import StacklumeDesignSystem

extension Notification.Name {
    /// Se emite cuando se ingiere un tweet/enlace guardado desde la sección X.
    static let xTweetSaved = Notification.Name("stacklume.xTweetSaved")
    /// El usuario eligió «Buscar en GitHub» sobre un texto seleccionado en el WebView de X.
    /// `userInfo["query"]` lleva el texto seleccionado.
    static let xSearchGitHub = Notification.Name("stacklume.xSearchGitHub")
}

/// Texto de búsqueda envuelto para presentar la hoja de GitHub con `.sheet(item:)`.
struct GitHubQuery: Identifiable {
    let id = UUID()
    let text: String
}

/// Conexión integrada con X (Twitter), SIN API y SIN tocar credenciales.
///
/// Es un `WKWebView` con sesión PERSISTENTE (el login sobrevive al cierre) que carga
/// x.com con apariencia in-app: una barra de marca con acciones mínimas (inicio,
/// recargar, atrás), sin barra de direcciones ni cromo de navegador. El usuario inicia
/// sesión con su cuenta y navega/interactúa con X normalmente.
///
/// El `WKWebView` vive en un holder SINGLETON (`XWebHolder`), no en esta vista: así NO se
/// recarga ni pierde el estado al cambiar de sección y volver (sigue donde estaba).
///
/// Cuando guarda un tweet (botón «Guardar» de X), un script inyectado lo detecta en el
/// DOM y lo manda a la app: si el tweet contiene un ENLACE externo (texto o tarjeta) se
/// ingiere ese enlace (resuelto a su URL final); si no, se guarda el propio tweet. Todo
/// reutiliza `LinkIngest.ingestLink` (dedup + enriquecido).
///
/// La detección depende del HTML de X (atributos `data-testid`, estables porque X los usa
/// en sus propios tests): si X cambiara su maquetado, basta con ajustar `detectorJS`.
struct XConnectView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.themePalette) private var palette

    /// Aviso efímero al guardar (confirma qué se añadió a la biblioteca).
    @State private var toast: String?
    @State private var toastIcon = "checkmark.circle.fill"
    /// `changeCount` del portapapeles ya visto: detecta una copia NUEVA mientras navegas en X.
    @State private var lastClipCount = ClipboardLink.changeCount
    /// Enlace EXTERNO a abrir en el navegador interno (con AdBlock) al pulsarlo en X, para no
    /// sacar al usuario de X y mantener la experiencia (lo enruta `XWebHolder`).
    @State private var externalLink: IdentifiableURL?
    /// Búsqueda en GitHub pendiente de abrir (texto seleccionado en un tweet vía clic derecho).
    @State private var githubQuery: GitHubQuery?

    /// Estado de carga/navegación del web view (observable, vive en el holder singleton).
    private var state: XWebState { XWebHolder.shared.state }

    /// Bienvenida de X mostrada una sola vez (explica el flujo de la integración).
    @AppStorage("stacklume.x.onboarded") private var xOnboarded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            // Barra de progreso fina mientras carga; si no, un separador.
            if state.isLoading && state.progress < 1 {
                ProgressView(value: state.progress)
                    .progressViewStyle(.linear)
                    .tint(palette.accent)
                    .frame(height: 2)
            } else {
                Divider().overlay(palette.border.opacity(0.5))
            }
            XWebView()
        }
        .background(WindowBackground())
        .overlay(alignment: .top) { toastView }
        .overlay { if !xOnboarded { onboarding } }
        .navigationTitle("X")
        // El holder vive fuera de la vista: aquí solo le pasamos el contexto para ingerir.
        .onAppear { XWebHolder.shared.context = context }
        .onReceive(NotificationCenter.default.publisher(for: .xTweetSaved)) { note in
            let message = note.userInfo?["message"] as? String ?? "Guardado"
            let icon = note.userInfo?["icon"] as? String ?? "checkmark.circle.fill"
            showToast(message, icon: icon)
        }
        // Vigila el PORTAPAPELES mientras navegas en X. Si copias un enlace con «Copiar enlace»
        // del menú contextual del WebView (la URL EXTERNA del tweet, p. ej. huggingface.co/…, NO
        // la del tweet), avisa a la ventana para que el banner del portapapeles ofrezca añadirlo.
        // Poll ligero (lee solo un contador), solo activo mientras la sección X está visible.
        .task {
            while !Task.isCancelled {
                let count = ClipboardLink.changeCount
                if count != lastClipCount {
                    lastClipCount = count
                    NotificationCenter.default.post(name: .stacklumeCheckClipboard, object: nil)
                }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        // Enlace externo pulsado en X → abrir en el navegador INTERNO (con AdBlock), sin salir de X.
        .onReceive(NotificationCenter.default.publisher(for: .xOpenExternalURL)) { note in
            if let url = note.userInfo?["url"] as? URL { externalLink = IdentifiableURL(url: url) }
        }
        .sheet(item: $externalLink) { item in
            InAppBrowserSheet(url: item.url).themedSheet(palette)
        }
        // Clic derecho sobre texto seleccionado en un tweet → «Buscar en GitHub» abre la hoja.
        .onReceive(NotificationCenter.default.publisher(for: .xSearchGitHub)) { note in
            if let text = note.userInfo?["query"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                githubQuery = GitHubQuery(text: text)
            }
        }
        .sheet(item: $githubQuery) { item in
            GitHubSearchSheet(initialQuery: item.text).themedSheet(palette)
        }
    }

    // MARK: - Barra de marca (sin cromo de navegador)

    private var header: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "at.circle.fill")
                .font(.title3)
                .foregroundStyle(palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("X")
                    .stacklumeFont(.headline.weight(.bold))
                    .foregroundStyle(palette.textPrimary)
                Text("Inicia sesión y guarda tweets: se añaden a tu biblioteca")
                    .stacklumeFont(.caption2)
                    .foregroundStyle(palette.textSecondary)
                    .stacklumeLineLimit(1)
            }
            Spacer()
            // Importar / resolver: traer los guardados de X y rescatar enlaces de tarjetas.
            if state.importing {
                progressChip("Importando \(state.importedCount)…")
            } else if state.resolving {
                progressChip("Resolviendo \(state.resolvedDone)/\(state.resolvedTotal)…")
            } else {
                Button { XWebHolder.shared.importBookmarks() } label: {
                    Label("Importar guardados", systemImage: "square.and.arrow.down")
                        .stacklumeFont(.callout.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.textPrimary)
                .themedHelp("Trae a tu biblioteca los tweets que ya tienes guardados en X")
                Button { XWebHolder.shared.resolveTweetLinks() } label: {
                    Label("Resolver enlaces", systemImage: "link")
                        .stacklumeFont(.callout.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.textSecondary)
                .themedHelp("Abre cada tweet guardado como x.com y, si llevaba un enlace, lo rescata (lento)")
            }
            Divider().frame(height: 16).overlay(palette.border.opacity(0.4))
            headerButton("chevron.backward", help: "Atrás", enabled: state.canGoBack) { XWebHolder.shared.goBack() }
            headerButton("chevron.forward", help: "Adelante", enabled: state.canGoForward) { XWebHolder.shared.goForward() }
            headerButton("house", help: "Inicio de X") { XWebHolder.shared.goHome() }
            headerButton("arrow.clockwise", help: "Recargar") { XWebHolder.shared.reload() }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
    }

    private func headerButton(_ icon: String, help: String, enabled: Bool = true,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.body)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? palette.textSecondary : palette.textSecondary.opacity(0.35))
        .disabled(!enabled)
        .themedHelp(help)
        .accessibilityLabel(help)
    }

    /// Indicador compacto de progreso (spinner + texto) para importar/resolver.
    private func progressChip(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).stacklumeFont(.caption).monospacedDigit().foregroundStyle(palette.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    // MARK: - Aviso efímero

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Label(toast, systemImage: toastIcon)
                .stacklumeFont(.callout.weight(.medium))
                .foregroundStyle(palette.textPrimary)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.accent.opacity(0.4), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                .padding(.top, DesignSystem.Spacing.md)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Bienvenida (primera vez)

    private var onboarding: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "at.circle.fill").scaledFont(40, scalesWithText: false).foregroundStyle(palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tu X, dentro de Stacklume").stacklumeFont(.title2.weight(.bold)).foregroundStyle(palette.textPrimary)
                        Text("Sin API y sin que veamos tus credenciales.").stacklumeFont(.callout).foregroundStyle(palette.textSecondary)
                    }
                }
                onboardingRow("1.circle.fill", "Inicia sesión con tu cuenta de X aquí mismo y navega con normalidad.")
                onboardingRow("2.circle.fill", "Guarda un tweet (su botón «Guardar»): se añade a tu biblioteca. Si lleva un enlace, se guarda el enlace.")
                onboardingRow("3.circle.fill", "«Importar guardados» trae los que ya tenías en X; «Resolver enlaces» rescata el enlace de los tweets con tarjeta.")
                onboardingRow("4.circle.fill", "¿Un tweet menciona un repo sin enlazarlo? Selecciona su nombre, clic derecho → «Buscar en GitHub» y añádelo desde el listado.")
                Button { xOnboarded = true } label: {
                    Text("Entendido").stacklumeFont(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(palette.accent)
                .padding(.top, DesignSystem.Spacing.xs)
            }
            .padding(DesignSystem.Spacing.xl)
            .frame(maxWidth: 480)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(palette.border.opacity(0.5), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
            .padding(DesignSystem.Spacing.xl)
        }
    }

    private func onboardingRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: icon).font(.title3).foregroundStyle(palette.accent)
            Text(text).stacklumeFont(.callout).foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func showToast(_ message: String, icon: String) {
        toastIcon = icon
        withAnimation(.snappy) { toast = message }
        AccessibilityNotification.Announcement(message).post()  // VoiceOver anuncia el guardado
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            withAnimation(.snappy) { toast = nil }
        }
    }
}

/// Datos capturados de un tweet al guardarlo en X (vía el script inyectado).
struct XTweetCapture {
    let tweetUrl: String
    let text: String
    let links: [String]
    let author: String
    /// URL de la media del tweet (foto o póster del vídeo), si la tiene. `""` si no.
    let image: String
}

/// Holder SINGLETON del `WKWebView` de X: lo crea UNA vez y lo reutiliza, para que la
/// vista pueda montarse/desmontarse al navegar entre secciones SIN recargar la página ni
/// perder el estado/login. Es además el puente JS→Swift (handler permanente) y quien
/// ingiere el tweet/enlace guardado. Al ser singleton, su retención por el
/// `userContentController` es intencional (vive toda la sesión).
/// Estado de navegación observable del web view de X (para la barra de marca).
@MainActor
@Observable
final class XWebState {
    var progress: Double = 0
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    /// Importación de los bookmarks ya guardados de X en curso + cuántos van.
    var importing = false
    var importedCount = 0
    /// Resolución de enlaces (abrir cada tweet x.com guardado y extraer su enlace de tarjeta).
    var resolving = false
    var resolvedDone = 0
    var resolvedTotal = 0
}

@MainActor
final class XWebHolder: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    static let shared = XWebHolder()

    let webView: WKWebView
    /// Estado de carga/navegación observable (progreso + atrás/adelante) para la barra.
    let state = XWebState()
    /// Contexto para ingerir (lo fija la vista al aparecer; sobrevive a navegar fuera).
    var context: ModelContext?
    private var observations: [NSKeyValueObservation] = []
    /// Hay una importación de bookmarks pendiente de arrancar (tras cargar la página).
    private var pendingImport = false
    /// Continuation reanudada al terminar de cargar una página (resolución de enlaces tweet
    /// a tweet, que espera a cada carga antes de extraer su enlace).
    private var navContinuation: CheckedContinuation<Void, Never>?

    private override init() {
        let config = WKWebViewConfiguration()
        // Sesión PERSISTENTE: el login de X sobrevive a cerrar y reabrir la app.
        config.websiteDataStore = .default()
        config.userContentController.addUserScript(
            WKUserScript(
                source: XConnectView.detectorJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: .defaultClient
            )
        )
        webView = SelectableWebView(frame: .zero, configuration: config)
        super.init()
        let ucc = config.userContentController
        ucc.add(self, contentWorld: .defaultClient, name: "slXBookmark")
        ucc.add(self, contentWorld: .defaultClient, name: "slXImport")
        ucc.add(self, contentWorld: .defaultClient, name: "slXImportDone")
        ucc.add(self, contentWorld: .defaultClient, name: "slXError")
        webView.navigationDelegate = self
        webView.uiDelegate = self   // para interceptar los enlaces `target="_blank"` de X
        webView.allowsBackForwardNavigationGestures = true
        observeNavigation()
        goHome()
    }

    /// Importa los tweets YA guardados en X: navega a la lista de bookmarks y, al cargar,
    /// lanza el recorrido con scroll progresivo (el script `__slXImport`). Cada tweet llega
    /// por `slXImport` y se ingiere (dedup evita duplicados); al final, `slXImportDone`.
    /// Timeout (segundos) para la carga de la página de guardados antes de abortar.
    private let importTimeoutSeconds: Double = 30

    func importBookmarks() {
        guard !state.importing else { return }
        state.importing = true
        state.importedCount = 0
        pendingImport = true
        guard let url = URL(string: "https://x.com/i/bookmarks") else { return }
        webView.load(URLRequest(url: url))
        // Cortafuegos: si la página nunca termina de cargar, libera el estado
        // para que el botón vuelva a ser usable y avisa al usuario.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(importTimeoutSeconds))
            guard state.importing, pendingImport else { return }
            pendingImport = false
            state.importing = false
            notify("La importación tardó demasiado. Comprueba tu conexión e inténtalo de nuevo.", icon: "exclamationmark.triangle.fill")
        }
    }

    /// Al terminar de cargar la página de bookmarks, arranca el recorrido (con un margen
    /// para que X cargue de forma diferida los primeros tweets).
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            // Resolución de enlaces: reanuda la espera de la carga de este tweet.
            if let cont = navContinuation { navContinuation = nil; cont.resume(); return }
            guard pendingImport, webView.url?.absoluteString.contains("/i/bookmarks") == true else { return }
            pendingImport = false
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                webView.evaluateJavaScript(
                    "window.__slXImport && window.__slXImport();",
                    in: nil,
                    in: .defaultClient,
                    completionHandler: nil
                )
            }
        }
    }

    // MARK: - Enlaces externos → navegador interno (con AdBlock)

    /// Hosts que SON X: se navegan dentro del WebView de X. Todo lo demás es «externo» y se abre
    /// en el navegador interno de la app (con AdBlock) para no sacar al usuario de X.
    private static let xHosts: Set<String> = [
        "x.com", "twitter.com", "mobile.twitter.com", "m.twitter.com", "pic.twitter.com",
        "abs.twimg.com", "pbs.twimg.com", "video.twimg.com", "twimg.com",
        "api.twitter.com", "api.x.com", "analytics.twitter.com", "ton.twitter.com",
    ]
    private static func isXHost(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        return xHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Dominios de AUTENTICACIÓN (OAuth): «Iniciar sesión con Google/Apple…». Llegan como popup
    /// (`createWebViewWith`) hacia un host externo, pero NO deben ir al navegador interno (rompería
    /// el login y la vuelta a X): se cargan en el propio WebView de X, que conserva la sesión.
    private static let authHosts: Set<String> = [
        "accounts.google.com", "appleid.apple.com", "login.microsoftonline.com",
        "github.com", "www.facebook.com", "oauth.telegram.org", "auth0.com",
    ]
    private static func isAuthFlow(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        return authHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// `true` solo si es un enlace web (http/https) hacia FUERA de X y NO un flujo de login.
    private static func isExternalWeb(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return !isXHost(url) && !isAuthFlow(url)
    }

    /// Avisa a la sección X para que abra la URL en el navegador interno (con AdBlock).
    private func openExternal(_ url: URL) {
        NotificationCenter.default.post(name: .xOpenExternalURL, object: nil, userInfo: ["url": url])
    }

    /// Clic en un enlace que SALE de X → cancelar y abrir en el navegador interno. El resto de
    /// navegaciones (login, redirecciones, SPA interna de X) siguen con normalidad.
    @MainActor
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           (navigationAction.targetFrame?.isMainFrame ?? true),
           Self.isExternalWeb(navigationAction.request.url),
           let url = navigationAction.request.url {
            openExternal(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// `target="_blank"` (X abre los enlaces externos en pestaña nueva): NO creamos un WebView
    /// nuevo; si es externo lo mandamos al navegador interno y si es de X lo cargamos en el mismo.
    @MainActor
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if Self.isExternalWeb(url) {
                openExternal(url)                        // contenido externo → navegador interno
            } else {
                webView.load(navigationAction.request)   // X o login (auth) → mismo WebView (sesión)
            }
        }
        return nil
    }

    /// Refleja el progreso/carga/atrás-adelante del web view en `state` (para la barra).
    private func observeNavigation() {
        let s = state
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { _, c in
                guard let v = c.newValue else { return }; Task { @MainActor in s.progress = v }
            },
            webView.observe(\.isLoading, options: [.new]) { _, c in
                guard let v = c.newValue else { return }; Task { @MainActor in s.isLoading = v }
            },
            webView.observe(\.canGoBack, options: [.new]) { _, c in
                guard let v = c.newValue else { return }; Task { @MainActor in s.canGoBack = v }
            },
            webView.observe(\.canGoForward, options: [.new]) { _, c in
                guard let v = c.newValue else { return }; Task { @MainActor in s.canGoForward = v }
            },
        ]
    }

    func reload() { webView.reload() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func openComposer(_ url: URL) {
        guard url.scheme == "https", url.host() == "x.com", url.path == "/intent/tweet" else { return }
        webView.load(URLRequest(url: url))
    }
    func goHome() {
        guard let url = URL(string: "https://x.com/home") else { return }
        webView.load(URLRequest(url: url))
    }

    // MARK: Puente JS→Swift

    nonisolated func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        // WebKit entrega los mensajes en el hilo principal.
        MainActor.assumeIsolated {
            // El script se inyecta en cada navegación del WebView persistente. Solo X/Twitter
            // puede ejecutar acciones nativas; OAuth/externas no deben simular guardados.
            let origin = message.frameInfo.securityOrigin.host.lowercased()
            let trustedOrigin = origin == "x.com" || origin.hasSuffix(".x.com")
                || origin == "twitter.com" || origin.hasSuffix(".twitter.com")
            guard message.frameInfo.isMainFrame, trustedOrigin else { return }
            switch message.name {
            case "slXBookmark":
                if let capture = Self.parse(message.body) { ingest(capture, announce: true) }
            case "slXImport":
                if let capture = Self.parse(message.body) { ingest(capture, announce: false); state.importedCount += 1 }
            case "slXImportDone":
                state.importing = false
                let n = state.importedCount
                // Tras una importación masiva: reindexar Spotlight y recargar el widget.
                if let context { SpotlightIndexer.reindexAll(in: context) }
                WidgetReloader.reload()
                notify("Importados \(n) de tus guardados de X", icon: "square.and.arrow.down.fill")
            case "slXError":
                // Error del script detector JS (window.onerror): aviso suave, sin bloquear.
                let msg = (message.body as? String) ?? "error desconocido"
                NSLog("[Stacklume·X] Error en el detector JS: \(msg)")
                notify("El detector de X encontró un problema (\(msg.prefix(60))). Puede que X haya cambiado su maquetado.", icon: "exclamationmark.triangle")
            default: break
            }
        }
    }

    private static func parse(_ body: Any) -> XTweetCapture? {
        guard let d = body as? [String: Any],
              let tweetUrl = d["tweetUrl"] as? String,
              let tweetURL = URL(string: tweetUrl),
              ["http", "https"].contains(tweetURL.scheme?.lowercased() ?? ""),
              isXHost(tweetURL) else { return nil }
        let links = ((d["links"] as? [String]) ?? []).prefix(20).filter { raw in
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }
        let rawImage = d["image"] as? String ?? ""
        let image: String
        if let url = URL(string: rawImage), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            image = String(rawImage.prefix(4_096))
        } else {
            image = ""
        }
        return XTweetCapture(tweetUrl: tweetUrl,
                             text: String((d["text"] as? String ?? "").prefix(20_000)),
                             links: Array(links),
                             author: String((d["author"] as? String ?? "").prefix(500)),
                             image: image)
    }

    /// Decide qué guardar: si el tweet trae un enlace externo, ese enlace (resuelto a su
    /// URL final); si no, el propio tweet. `announce` muestra el aviso (off en importación
    /// masiva para no encadenar toasts). Reutiliza `LinkIngest` (dedup + enriquecido).
    private func ingest(_ capture: XTweetCapture, announce: Bool) {
        guard let context else { return }
        if let externalLink = capture.links.first {
            let tweetUrl = capture.tweetUrl
            Task { @MainActor in
                let resolved = await Self.resolveFinalURL(externalLink) ?? externalLink
                _ = LinkIngest.ingestLink(urlString: resolved, in: context, aiEnrich: true)
                // Si este tweet se había guardado ANTES como el propio tweet (x.com) porque
                // entonces no se detectó su enlace (tarjeta cargada tarde), se reemplaza:
                // prevalece el ENLACE y se elimina el marcador del tweet. Así, reimportar
                // CORRIGE los que quedaron como x.com.
                Self.removeTweetBookmark(tweetUrl, in: context)
                if announce { notify("Enlace del tweet guardado", icon: "link.circle.fill") }
            }
        } else {
            // Tweet sin enlace: X bloquea el scraping, así que se guarda el texto del
            // tweet como nota para que tenga contexto aunque el enriquecido no dé título.
            let bookmark = LinkIngest.ingestLink(urlString: capture.tweetUrl, in: context, aiEnrich: true)
            let text = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, (bookmark.notes ?? "").isEmpty {
                bookmark.notes = text
                bookmark.updatedAt = Date()
                context.saveLogging()
            }
            // Imagen REAL del tweet (su media), extraída del DOM ya logueado: x.com no
            // expone `og:image` al alta, así que esta es la única portada fiable del propio
            // tweet. Solo si la trae y aún no tiene imagen.
            let image = capture.image.trimmingCharacters(in: .whitespacesAndNewlines)
            if !image.isEmpty, (bookmark.imageURL?.isEmpty ?? true) {
                bookmark.imageURL = image
                bookmark.updatedAt = Date()
                context.saveLogging()
            }
            if announce { notify("Tweet guardado en tu biblioteca", icon: "checkmark.circle.fill") }
        }
    }

    /// Elimina un marcador guardado como el PROPIO tweet (su permalink x.com). Se usa al
    /// reimportar cuando un tweet que antes quedó como x.com ahora SÍ revela su enlace:
    /// se borra el marcador del tweet para que prevalezca el enlace (compara por URL
    /// canónica, tolerante a `?s=20` y demás variantes del permalink).
    private static func removeTweetBookmark(_ tweetUrl: String, in context: ModelContext) {
        // Predicado INDEXADO por url (antes traía TODA la biblioteca por cada tweet → O(n²)
        // al importar/resolver en masa). El tweet se guarda y se reimporta con el mismo
        // permalink, así que el match exacto basta.
        let descriptor = FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.deletedAt == nil && $0.url == tweetUrl })
        guard let matches = try? context.fetch(descriptor), !matches.isEmpty else { return }
        BookmarkActions.deleteForever(matches, in: context)
    }

    // MARK: - Resolver enlaces de tweets (abrir cada tweet x.com y sacar su enlace)

    /// Para los tweets que quedaron guardados como x.com (su enlace estaba en una tarjeta
    /// que el scroll de la importación no llegó a cargar), abre CADA uno en su página
    /// individual —donde X sí renderiza la tarjeta— y, si tiene enlace externo, lo guarda y
    /// reemplaza el marcador del tweet. Es lento (una carga por tweet) pero fiable.
    func resolveTweetLinks() {
        guard let context, !state.resolving else { return }
        let targets = Self.collectTweetURLs(in: context)
        guard !targets.isEmpty else { return }
        state.resolving = true
        state.resolvedDone = 0
        state.resolvedTotal = targets.count
        let home = webView.url
        Task { @MainActor in
            defer { state.resolving = false; navContinuation = nil }
            var failCount = 0
            for tweetURL in targets {
                if Task.isCancelled { break }
                if let link = await loadAndExtractLink(tweetURL) {
                    let resolved = await Self.resolveFinalURL(link) ?? link
                    _ = LinkIngest.ingestLink(urlString: resolved, in: context, aiEnrich: true)
                    Self.removeTweetBookmark(tweetURL, in: context)
                } else {
                    failCount += 1
                }
                state.resolvedDone += 1
            }
            if let home { webView.load(URLRequest(url: home)) } else { goHome() }
            SpotlightIndexer.reindexAll(in: context)
            WidgetReloader.reload()
            let resueltos = state.resolvedTotal - failCount
            let resumen = failCount > 0
                ? "Resueltos \(resueltos) de \(state.resolvedTotal). Fallos: \(failCount)"
                : "Resueltos \(resueltos) enlaces de tweets"
            notify(resumen, icon: "link.circle.fill")
        }
    }

    /// URLs guardadas como el PROPIO tweet (permalink x.com/.../status/).
    private static func collectTweetURLs(in context: ModelContext) -> [String] {
        let descriptor = FetchDescriptor<Bookmark>(predicate: #Predicate { $0.deletedAt == nil })
        guard let all = try? context.fetch(descriptor) else { return [] }
        return all.map(\.url).filter {
            ($0.contains("x.com/") || $0.contains("twitter.com/")) && $0.contains("/status/")
        }
    }

    /// Carga la página de un tweet, espera a que renderice y devuelve su primer enlace
    /// externo (o nil). Con salvaguarda de tiempo para no colgarse si una carga no termina.
    private func loadAndExtractLink(_ tweetURL: String) async -> String? {
        guard let url = URL(string: tweetURL) else { return nil }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            navContinuation = cont
            webView.load(URLRequest(url: url))
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(12))
                if let c = navContinuation { navContinuation = nil; c.resume() }
            }
        }
        // Margen para la tarjeta del enlace (lazy) con el tweet ya en pantalla.
        try? await Task.sleep(for: .seconds(2.6))
        return await extractFirstExternalLink()
    }

    /// Primer enlace externo del tweet principal de la página actual.
    private func extractFirstExternalLink() async -> String? {
        let js = """
        (function(){
          var a = document.querySelector('article[data-testid="tweet"]');
          if (!a) return '';
          var anchors = a.querySelectorAll('a[href]');
          for (var i=0;i<anchors.length;i++){
            var h = anchors[i].href || '';
            if (h.indexOf('http://')!==0 && h.indexOf('https://')!==0) continue;
            var host; try { host = new URL(h).hostname.toLowerCase(); } catch(e){ continue; }
            if (host.indexOf('www.')===0) host = host.slice(4);
            if (host==='x.com'||host==='twitter.com'||host==='mobile.twitter.com'||host==='pic.twitter.com') continue;
            return h;
          }
          return '';
        })()
        """
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            webView.evaluateJavaScript(
                js,
                in: nil,
                in: .defaultClient
            ) { result in
                let value = try? result.get()
                let s = (value as? String) ?? ""
                cont.resume(returning: s.isEmpty ? nil : s)
            }
        }
    }

    private func notify(_ message: String, icon: String) {
        NotificationCenter.default.post(name: .xTweetSaved, object: nil,
                                        userInfo: ["message": message, "icon": icon])
    }

    /// Resuelve la URL final de un enlace acortado (t.co) para guardar la página REAL y no el
    /// acortador. Delega en el punto ÚNICO [[ShortLinkResolver]], que sigue la redirección HTTP
    /// (301) Y el destino embebido en el HTML (`meta refresh`/`location.replace`) — t.co a veces
    /// sirve un 200 con `meta refresh` (descargas directas, p. ej. una release de GitHub), caso
    /// que el resolutor anterior (solo HEAD) NO cubría y dejaba el enlace como `t.co` con la
    /// plataforma/favicon/imagen de X. Si no se puede resolver, devuelve `nil`.
    static func resolveFinalURL(_ urlString: String) async -> String? {
        await ShortLinkResolver.resolve(urlString)
    }
}

/// `WKWebView` de X montado desde el holder singleton (no se recrea al navegar).
struct XWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { XWebHolder.shared.webView }
    func updateNSView(_ web: WKWebView, context: Context) {}
}

/// `WKWebView` que añade «Buscar en GitHub» al menú contextual de macOS, pero SOLO cuando hay
/// texto seleccionado (entre las opciones nativas «Buscar con…», «Buscar en el diccionario»…).
/// Al elegirlo, lee la selección (`window.getSelection()`) y avisa por `NotificationCenter`
/// (`.xSearchGitHub`) para que la sección X abra la hoja de búsqueda. Así el usuario puede
/// rescatar el repo de un tweet que lo menciona sin enlazarlo.
final class SelectableWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // Solo si WebKit añadió items que aparecen únicamente con texto seleccionado.
        guard let anchor = selectionAnchorIndex(in: menu) else { return }
        let item = NSMenuItem(title: "Buscar en GitHub",
                              action: #selector(searchGitHubFromSelection), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right",
                             accessibilityDescription: "Buscar en GitHub")
        // Insertar justo después del grupo «Buscar con…/Buscar en el diccionario».
        menu.insertItem(.separator(), at: anchor + 1)
        menu.insertItem(item, at: anchor + 2)
    }

    /// Índice del primer item del menú que WebKit añade SOLO con una selección de texto
    /// («Buscar con…», «Buscar en el diccionario», «Traducir») o, en su defecto, «Copiar».
    private func selectionAnchorIndex(in menu: NSMenu) -> Int? {
        func firstIndex(where test: (String) -> Bool) -> Int? {
            menu.items.firstIndex { ($0.identifier?.rawValue).map(test) ?? false }
        }
        let markers = ["SearchWeb", "LookUp", "Translate"]
        if let i = firstIndex(where: { raw in markers.contains { raw.contains($0) } }) { return i }
        // Reserva: «Copiar» de selección de texto (excluye CopyLink/CopyImage de enlaces/imágenes).
        if let i = firstIndex(where: { $0 == "WKMenuItemIdentifierCopy" }) { return i }
        return nil
    }

    @objc private func searchGitHubFromSelection() {
        evaluateJavaScript(
            "window.getSelection().toString()",
            in: nil,
            in: .defaultClient
        ) { result in
            let value = try? result.get()
            let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return }
            NotificationCenter.default.post(name: .xSearchGitHub, object: nil,
                                            userInfo: ["query": text])
        }
    }
}

extension XConnectView {
    /// Script inyectado en x.com que detecta cuándo el usuario GUARDA un tweet y manda sus
    /// datos a la app. Usa delegación de eventos sobre `document` (sobrevive a la navegación
    /// SPA de X) y los atributos `data-testid` de X (estables: los usan en sus propios tests).
    /// Captura el permalink, el texto, el autor y TODOS los enlaces externos del tweet
    /// (tanto del texto como de la tarjeta/card), excluyendo lo interno de X.
    static let detectorJS = """
    (function(){
      if (window.__slX) return;
      window.__slX = true;
      // Captura errores JS no controlados del propio detector y los manda a Swift.
      var _slXPrevError = window.onerror;
      window.onerror = function(msg, src, line, col, err){
        try { window.webkit.messageHandlers.slXError.postMessage(String(msg)); } catch(e){}
        if (_slXPrevError) return _slXPrevError(msg, src, line, col, err);
        return false;
      };
      var lastKey = '', lastTime = 0;
      function externalLinks(article){
        var out = [];
        var anchors = article.querySelectorAll('a[href]');
        for (var i = 0; i < anchors.length; i++) {
          var href = anchors[i].href || '';
          if (href.indexOf('http://') !== 0 && href.indexOf('https://') !== 0) continue;
          var host;
          try { host = new URL(href).hostname.toLowerCase(); } catch(e) { continue; }
          if (host.indexOf('www.') === 0) host = host.slice(4);
          // Excluir lo interno de X (menciones, hashtags, perfiles, permalinks, media).
          if (host === 'x.com' || host === 'twitter.com' || host === 'mobile.twitter.com' || host === 'pic.twitter.com') continue;
          if (out.indexOf(href) < 0) out.push(href);
        }
        return out;
      }
      // Imagen REAL del tweet (su media) desde el DOM ya logueado: la foto o, si es vídeo,
      // su póster. Se sube la URL de `pbs.twimg.com` a resolución grande (`name=large`).
      // Best-effort: '' si el tweet no tiene media.
      function tweetImage(article){
        var img = article.querySelector('[data-testid="tweetPhoto"] img');
        if (img && img.src) { return img.src.replace(/([?&])name=[^&]+/, '$1name=large'); }
        var vid = article.querySelector('video[poster]');
        if (vid && vid.poster) { return vid.poster; }
        return '';
      }
      function articleData(article, fallbackUrl){
        var permalink = '';
        var statusLink = article.querySelector('a[href*="/status/"]');
        if (statusLink) { try { permalink = new URL(statusLink.getAttribute('href'), location.origin).href; } catch(e){} }
        if (!permalink) { permalink = fallbackUrl || ''; }
        if (!permalink) { return null; }
        var textEl = article.querySelector('[data-testid="tweetText"]');
        var text = textEl ? textEl.innerText : '';
        var authorEl = article.querySelector('[data-testid="User-Name"] a[href]');
        var author = authorEl ? authorEl.href : '';
        return { tweetUrl: permalink, text: text, links: externalLinks(article), author: author, image: tweetImage(article) };
      }
      function capture(btn){
        var article = btn.closest('article[data-testid="tweet"]');
        if (!article) return null;
        return articleData(article, location.href);
      }
      // Recorre los tweets YA guardados (página de bookmarks) con scroll progresivo.
      // seen[permalink] = ¿ya se detectó su enlace? (undefined: no visto; false: visto SIN
      // enlace; true: con enlace). Si la TARJETA de un tweet carga tarde, se reenvía el
      // tweet ya con su enlace para que la app reemplace el marcador del tweet por el enlace.
      // El scroll es moderado y la pausa generosa: así da tiempo a que las tarjetas (donde
      // suele estar el enlace) carguen antes de extraer, en vez de guardar el tweet a secas.
      window.__slXImport = async function(){
        var seen = {}, total = 0, stagnant = 0;
        for (var i = 0; i < 120 && stagnant < 6; i++) {
          var arts = document.querySelectorAll('article[data-testid="tweet"]');
          var fresh = 0;
          for (var j = 0; j < arts.length; j++) {
            var d = articleData(arts[j], '');
            if (!d) continue;
            var prev = seen[d.tweetUrl];
            var hasLink = d.links.length > 0;
            if (prev === undefined) {
              seen[d.tweetUrl] = hasLink; total++; fresh++;
              try { window.webkit.messageHandlers.slXImport.postMessage(d); } catch(e){}
            } else if (prev === false && hasLink) {
              // su tarjeta cargó tarde: reenvía el tweet, ahora con su enlace (corrige).
              seen[d.tweetUrl] = true; fresh++;
              try { window.webkit.messageHandlers.slXImport.postMessage(d); } catch(e){}
            }
          }
          stagnant = (fresh === 0) ? stagnant + 1 : 0;
          // Scroll con algo de solapamiento + pausa: captura el enlace de los tweets que lo
          // llevan en el TEXTO (la mayoría). Las TARJETAS de enlace no se intentan forzar
          // por aquí: X no las carga con scroll automático; para esas está «Resolver enlaces».
          window.scrollBy(0, window.innerHeight * 0.9);
          await new Promise(function(r){ setTimeout(r, 1500); });
        }
        try { window.webkit.messageHandlers.slXImportDone.postMessage({ count: total }); } catch(e){}
      };
      document.addEventListener('click', function(e){
        var t = e.target;
        if (!t || !t.closest) return;
        // Solo el botón de GUARDAR (no el de quitar: data-testid='removeBookmark').
        var btn = t.closest('[data-testid="bookmark"]');
        if (!btn) return;
        var data = capture(btn);
        if (!data) return;
        // Anti-rebote: ignora el mismo tweet repetido en menos de 1.2 s.
        var now = Date.now();
        if (data.tweetUrl === lastKey && (now - lastTime) < 1200) return;
        lastKey = data.tweetUrl; lastTime = now;
        try { window.webkit.messageHandlers.slXBookmark.postMessage(data); } catch(err){}
      }, true);
    })();
    """
}
