import SwiftUI
import SwiftData
import WebKit
import StacklumeCore
import StacklumeDesignSystem
import StacklumeMetadata

/// Estado de navegación del navegador interno, observado por la UI (botones atrás/adelante,
/// barra de progreso, título). Es `@MainActor`, así que sirve de puente seguro entre las
/// notificaciones KVO del `WKWebView` y SwiftUI.
@MainActor
@Observable
final class WebViewModel {
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var progress: Double = 0
    var pageTitle = ""
    var currentHost = ""
    /// URL completa de la página actual (para la barra de direcciones).
    var currentURLString = ""
    /// Referencia débil al `WKWebView` para las acciones de la barra (atrás/adelante/recargar).
    weak var webView: WKWebView?

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stop() { webView?.stopLoading() }
    /// Navega a una URL (desde la barra de direcciones).
    func load(_ url: URL) { webView?.load(URLRequest(url: url)) }
}

/// `WKWebView` envuelto en `NSViewRepresentable` para mostrar una URL dentro de la app, con
/// bloqueo de anuncios opcional (`WKContentRuleList`, ver `AdBlocker`) y estado de navegación
/// publicado en un `WebViewModel`.
struct WebPageView: NSViewRepresentable {
    let url: URL
    /// Bloqueo de anuncios/rastreo (escudos). Activado por defecto.
    var adBlockEnabled: Bool = true
    /// Modelo de navegación opcional para alimentar la barra del navegador.
    var model: WebViewModel?
    /// Resaltados ya guardados a re-pintar sobre la página real al cargar (vacío = ninguno).
    var highlights: [ReaderHighlight] = []
    /// Paleta de colores del popover de selección (hex). Vacío = resaltado desactivado.
    var highlightColors: [String] = []
    /// Se invoca al resaltar la selección sobre la página real: (texto, colorHex). `nil` =
    /// navegador normal sin resaltado. Reutiliza la MISMA CSS Custom Highlight API y el
    /// mismo puente `slHighlight` que el modo lectura (`StaticHTMLView`).
    var onHighlight: (@MainActor (String, String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let web: WKWebView
        if onHighlight != nil {
            // Resaltado activo: inyecta el script compartido + el puente a Swift. La sesión
            // sigue siendo PERSISTENTE (no se toca `websiteDataStore`) para no cerrar la sesión.
            let config = WKWebViewConfiguration()
            let ucc = config.userContentController
            ucc.addUserScript(WKUserScript(
                source: StaticHTMLView.highlightJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: .defaultClient
            ))
            // Proxy DÉBIL para no crear el ciclo ucc → coordinator (el ucc retiene sus handlers).
            ucc.add(
                WeakMessageProxy(context.coordinator),
                contentWorld: .defaultClient,
                name: "slHighlight"
            )
            web = WKWebView(frame: .zero, configuration: config)
            web.navigationDelegate = context.coordinator
        } else {
            web = WKWebView()
        }
        web.allowsBackForwardNavigationGestures = true
        model?.webView = web
        context.coordinator.attach(to: web)
        context.coordinator.configureHighlight(colors: highlightColors, highlights: highlights, onHighlight: onHighlight)
        context.coordinator.apply(url: url, adBlock: adBlockEnabled)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.configureHighlight(colors: highlightColors, highlights: highlights, onHighlight: onHighlight)
        context.coordinator.apply(url: url, adBlock: adBlockEnabled)
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        // Rompe el puente JS→Swift al cerrar (no afecta al adblock, que usa rule lists).
        web.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let model: WebViewModel?
        private var observations: [NSKeyValueObservation] = []
        /// ¿Ya se hizo la primera carga de la URL inicial?
        private var didInitialLoad = false
        /// Estado de adblock ya aplicado al web view (`nil` = aún sin configurar).
        private var adBlockApplied: Bool?
        /// Estado de resaltado sobre la página real (paleta, existentes, callback).
        private var hlColors: [String] = []
        private var hlExisting: [ReaderHighlight] = []
        private var onHighlight: (@MainActor (String, String) -> Void)?

        init(model: WebViewModel?) { self.model = model; super.init() }

        /// Refresca la configuración de resaltado (colores, existentes y callback).
        func configureHighlight(colors: [String], highlights: [ReaderHighlight], onHighlight: (@MainActor (String, String) -> Void)?) {
            hlColors = colors
            hlExisting = highlights
            self.onHighlight = onHighlight
        }

        /// Al terminar de cargar una página: inicializa la paleta del popover y re-pinta los
        /// resaltados guardados (best-effort: si el texto no aparece en el DOM actual, se omite).
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard onHighlight != nil else { return }
            let colorsJSON = Self.jsonString(hlColors)
            let itemsJSON = Self.jsonString(hlExisting.map { ["text": $0.text, "color": $0.color] })
            webView.evaluateJavaScript(
                "window.__slInit && window.__slInit(\(colorsJSON)); window.__slPaintExisting && window.__slPaintExisting(\(itemsJSON));",
                in: nil,
                in: .defaultClient,
                completionHandler: nil
            )
        }

        /// Mensaje del popover JS: `{ text, color }` del fragmento recién resaltado.
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  message.name == "slHighlight",
                  let body = message.body as? [String: Any],
                  let text = body["text"] as? String,
                  let color = body["color"] as? String,
                  hlColors.contains(color) else { return }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= 20_000 else { return }
            MainActor.assumeIsolated { onHighlight?(clean, color) }
        }

        /// Serializa a JSON seguro para incrustar en `evaluateJavaScript`.
        private static func jsonString(_ value: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value),
                  let s = String(data: data, encoding: .utf8) else { return "[]" }
            return s
        }

        /// Observa las propiedades del `WKWebView` y refleja sus cambios en el modelo. Usa
        /// `change.newValue` (valores `Sendable`) para no tocar el web view (`@MainActor`)
        /// desde el closure de KVO; el modelo se actualiza en el `MainActor`.
        func attach(to web: WKWebView) {
            let model = self.model
            observations = [
                web.observe(\.estimatedProgress, options: [.new]) { _, change in
                    guard let v = change.newValue else { return }
                    Task { @MainActor in model?.progress = v }
                },
                web.observe(\.isLoading, options: [.new]) { _, change in
                    guard let v = change.newValue else { return }
                    Task { @MainActor in model?.isLoading = v }
                },
                web.observe(\.canGoBack, options: [.new]) { _, change in
                    guard let v = change.newValue else { return }
                    Task { @MainActor in model?.canGoBack = v }
                },
                web.observe(\.canGoForward, options: [.new]) { _, change in
                    guard let v = change.newValue else { return }
                    Task { @MainActor in model?.canGoForward = v }
                },
                web.observe(\.title, options: [.new]) { _, change in
                    let v = (change.newValue ?? nil) ?? ""
                    Task { @MainActor in model?.pageTitle = v }
                },
                web.observe(\.url, options: [.new]) { _, change in
                    let u = (change.newValue ?? nil)
                    let host = u?.host() ?? ""
                    let full = u?.absoluteString ?? ""
                    Task { @MainActor in model?.currentHost = host; model?.currentURLString = full }
                },
            ]
        }

        /// Sincroniza el estado de adblock y carga la URL. Si cambia el adblock, lo aplica
        /// (añade/quita la lista de reglas) y recarga; si solo cambia la URL, navega.
        func apply(url: URL, adBlock: Bool) {
            guard let web = model?.webView else { return }
            if adBlockApplied != adBlock {
                adBlockApplied = adBlock
                Task { @MainActor in
                    let ucc = web.configuration.userContentController
                    if adBlock {
                        if let list = await AdBlocker.shared.ruleList() {
                            ucc.add(list)
                        }
                    } else {
                        ucc.removeAllContentRuleLists()
                    }
                    // Primera vez: carga la URL inicial. Si ya navegó, recarga la página
                    // ACTUAL (para aplicar/quitar el escudo sin perder dónde está el usuario).
                    if didInitialLoad {
                        web.reload()
                    } else {
                        didInitialLoad = true
                        web.load(URLRequest(url: url))
                    }
                }
                return
            }
            if !didInitialLoad {
                didInitialLoad = true
                web.load(URLRequest(url: url))
            }
        }
    }
}

/// Wrapper Identifiable para presentar URLs en `.sheet(item:)`. Puede llevar la copia
/// sin conexión del enlace (si la hay) para que el modo lectura la use sin red.
struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
    var offlineHTML: String? = nil
}

/// Hoja con el navegador integrado: barra con navegación (atrás/adelante/recargar), barra de
/// DIRECCIONES editable (navega a cualquier URL o busca), MODO LECTURA (extrae el artículo
/// limpio), escudo de bloqueo de anuncios (estilo Brave), abrir en el navegador del sistema y
/// cerrar; barra de progreso de carga.
struct InAppBrowserSheet: View {
    let url: URL
    /// Copia sin conexión del enlace (si existe): el modo lectura la usa sin red.
    var offlineHTML: String? = nil
    /// Enlace asociado (si se abre desde su ficha): habilita resaltar en modo lectura.
    var bookmark: Bookmark? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.themePalette) private var palette
    @Environment(\.modelContext) private var context
    /// Preferencia persistente del bloqueo de anuncios del navegador interno.
    @AppStorage("stacklume.browser.adblock") private var adBlock = true
    /// Tamaño de fuente del modo lectura (porcentaje, compartido con el lector offline).
    @AppStorage("stacklume.reader.fontPercent") private var readerFont = 100
    /// Tema de lectura (oscuro/sepia/claro) y tipografía (sans/serif), persistidos.
    @AppStorage("stacklume.reader.theme") private var readerThemeRaw = ReaderTheme.dark.rawValue
    @AppStorage("stacklume.reader.font") private var readerFontRaw = ReaderFont.sans.rawValue
    private var readerTheme: ReaderTheme { ReaderTheme(rawValue: readerThemeRaw) ?? .dark }
    private var readerFontFamily: ReaderFont { ReaderFont(rawValue: readerFontRaw) ?? .sans }
    @State private var model = WebViewModel()
    /// Texto de la barra de direcciones (editable).
    @State private var addressText = ""
    @FocusState private var addressFocused: Bool
    /// Modo lectura: HTML del artículo limpio (nil = navegador normal).
    @State private var readerHTML: String?
    @State private var loadingReader = false
    /// ¿La página en la que estamos AHORA ya está en la biblioteca? (icono de marcador lleno).
    @State private var savedCurrent = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            // Barra de progreso fina durante la carga; si no, un separador.
            if model.isLoading && model.progress < 1 && readerHTML == nil {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(palette.accent)
                    .frame(height: 2)
            } else {
                Divider()
            }
            ZStack {
                WebPageView(
                    url: url, adBlockEnabled: adBlock, model: model,
                    highlights: (bookmark?.highlights ?? []).map { ReaderHighlight(text: $0.text, color: $0.colorHex) },
                    highlightColors: bookmark == nil ? [] : ColorPresets.all,
                    onHighlight: highlightHandler()
                )
                    .opacity(readerHTML == nil ? 1 : 0)
                if let html = readerHTML {
                    StaticHTMLView(
                        html: html, fontPercent: readerFont,
                        theme: readerTheme, fontFamily: readerFontFamily,
                        highlights: (bookmark?.highlights ?? []).map { ReaderHighlight(text: $0.text, color: $0.colorHex) },
                        highlightColors: bookmark == nil ? [] : ColorPresets.all,
                        onHighlight: highlightHandler(),
                        scrollKey: CanonicalURL.key(bookmark?.url ?? url.absoluteString)
                    )
                }
                if loadingReader {
                    ProgressView("Preparando lectura…")
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .frame(width: 1000, height: 720)
        .onAppear { addressText = url.absoluteString; refreshSavedState() }
        // Refleja en la barra la URL real al navegar (salvo mientras el usuario escribe) y
        // recalcula si la nueva página ya está guardada (marcador lleno/vacío).
        .onChange(of: model.currentURLString) { _, new in
            if !addressFocused, !new.isEmpty { addressText = new }
            refreshSavedState()
        }
        // Detección del PORTAPAPELES «desde donde sea»: si copias un enlace DENTRO del navegador
        // interno, Stacklume lo detecta (banner «Añadir») igual que en el resto de la app. Poll
        // ligero (solo lee un contador) mientras la hoja está abierta.
        .task {
            var last = ClipboardLink.changeCount
            while !Task.isCancelled {
                let count = ClipboardLink.changeCount
                if count != last {
                    last = count
                    NotificationCenter.default.post(name: .stacklumeCheckClipboard, object: nil)
                }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(palette.textSecondary)
                .themedHelp("Cerrar")
                .accessibilityLabel("Cerrar")

            Divider().frame(height: 16)

            Button { model.goBack() } label: { Image(systemName: "chevron.backward") }
                .buttonStyle(.plain)
                .foregroundStyle(model.canGoBack ? palette.textPrimary : palette.textSecondary.opacity(0.4))
                .disabled(!model.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .themedHelp("Atrás (⌘[)")
                .accessibilityLabel("Atrás")
            Button { model.goForward() } label: { Image(systemName: "chevron.forward") }
                .buttonStyle(.plain)
                .foregroundStyle(model.canGoForward ? palette.textPrimary : palette.textSecondary.opacity(0.4))
                .disabled(!model.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
                .themedHelp("Adelante (⌘])")
                .accessibilityLabel("Adelante")
            Button { model.isLoading ? model.stop() : model.reload() } label: {
                Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.textPrimary)
            .keyboardShortcut("r", modifiers: .command)
            .themedHelp(model.isLoading ? "Detener" : "Recargar (⌘R)")
            .accessibilityLabel(model.isLoading ? "Detener" : "Recargar")

            // Atajo ⌘L: enfocar la barra de direcciones (botón invisible, sin ocupar espacio).
            Button("") { addressFocused = true }
                .keyboardShortcut("l", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

            // Barra de direcciones editable (URL o búsqueda).
            addressBar

            // Tamaño de fuente del lector (solo en modo lectura).
            if readerHTML != nil {
                Button { readerFont = max(70, readerFont - 10) } label: { Image(systemName: "textformat.size.smaller") }
                    .buttonStyle(.plain).foregroundStyle(palette.textSecondary)
                    .disabled(readerFont <= 70).themedHelp("Reducir texto")
                    .accessibilityLabel("Reducir texto")
                Button { readerFont = min(180, readerFont + 10) } label: { Image(systemName: "textformat.size.larger") }
                    .buttonStyle(.plain).foregroundStyle(palette.textSecondary)
                    .disabled(readerFont >= 180).themedHelp("Agrandar texto")
                    .accessibilityLabel("Agrandar texto")

                // Tema de lectura (oscuro/sepia/claro) + tipografía (sans/serif).
                Menu {
                    Picker("Tema", selection: $readerThemeRaw) {
                        ForEach(ReaderTheme.allCases) { Label($0.label, systemImage: $0.icon).tag($0.rawValue) }
                    }
                    Divider()
                    Picker("Tipografía", selection: $readerFontRaw) {
                        ForEach(ReaderFont.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                } label: {
                    Image(systemName: readerTheme.icon)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(palette.textSecondary)
                .themedHelp("Tema y tipografía de lectura")
                .accessibilityLabel("Tema y tipografía de lectura")
            }

            // Modo lectura (extrae el artículo limpio).
            Button { toggleReader() } label: {
                Image(systemName: readerHTML == nil ? "doc.plaintext" : "doc.plaintext.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(readerHTML == nil ? palette.textSecondary : palette.accent)
            .disabled(loadingReader)
            .themedHelp(readerHTML == nil ? "Modo lectura" : "Salir del modo lectura")
            .accessibilityLabel(readerHTML == nil ? "Modo lectura" : "Salir del modo lectura")

            // Escudo de bloqueo de anuncios (toggle persistente, estilo Brave).
            Button { adBlock.toggle() } label: {
                Image(systemName: adBlock ? "shield.lefthalf.filled" : "shield.slash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(adBlock ? palette.accent : palette.textSecondary)
            .themedHelp(adBlock ? "Bloqueo de anuncios activado — toca para desactivar"
                          : "Bloqueo de anuncios desactivado — toca para activar")
            .accessibilityLabel(adBlock ? "Bloqueo de anuncios activado" : "Bloqueo de anuncios desactivado")

            // Guardar en Stacklume la página ACTUAL (estés donde estés navegando). Lleno + acento
            // cuando ya está en la biblioteca; reutiliza `LinkIngest` (dedup + enriquecido).
            Button { saveCurrent() } label: {
                Image(systemName: savedCurrent ? "bookmark.fill" : "bookmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(savedCurrent ? palette.accent : palette.textSecondary)
            .keyboardShortcut("d", modifiers: .command)
            .themedHelp(savedCurrent ? "Ya está en tu biblioteca" : "Guardar en Stacklume (⌘D)")
            .accessibilityLabel(savedCurrent ? "Ya está en tu biblioteca" : "Guardar en Stacklume")

            Button { openURL(currentURL); dismiss() } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.accent)
            .themedHelp("Abrir en el navegador")
            .accessibilityLabel("Abrir en el navegador")
        }
        .padding(10)
        // Superficie del tema (navy) en vez del material `.bar` GRIS del sistema, para que la
        // barra del navegador interno se integre con la app (lo pidió el usuario). Borde inferior
        // sutil para separarla del contenido web.
        .background(palette.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.border.opacity(0.5)).frame(height: 1)
        }
    }

    private var addressBar: some View {
        HStack(spacing: 6) {
            Image(systemName: model.currentURLString.hasPrefix("https") ? "lock.fill" : "globe")
                .font(.caption2)
                .foregroundStyle(palette.textSecondary)
            TextField("Buscar o escribir una dirección", text: $addressText)
                .textFieldStyle(.plain)
                .stacklumeFont(.callout)
                .foregroundStyle(palette.textPrimary)
                .focused($addressFocused)
                .onSubmit { navigateToAddress() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(palette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5))
        .frame(maxWidth: .infinity)
    }

    /// URL actual del navegador (para «abrir en el sistema» y el modo lectura).
    private var currentURL: URL {
        URL(string: model.currentURLString) ?? url
    }

    /// Guarda en la biblioteca la página en la que estamos ahora mismo. Reutiliza el embudo
    /// único [[LinkIngest]] (dedup + autocategoría/etiquetas + enriquecido IA), así que pulsarlo
    /// dos veces no duplica. Marca el icono como lleno al instante.
    private func saveCurrent() {
        guard !savedCurrent else { return }
        _ = LinkIngest.ingestLink(urlString: currentURL.absoluteString, in: context, aiEnrich: true)
        withAnimation(.snappy) { savedCurrent = true }
        AccessibilityNotification.Announcement("Guardado en Stacklume").post()
    }

    /// Recalcula si la página actual YA está en la biblioteca, para reflejarlo en el marcador.
    /// Acota el fetch por host (no recorre toda la biblioteca: clave para escalar) y compara por
    /// clave canónica ([[CanonicalURL]]), igual que el banner del portapapeles.
    private func refreshSavedState() {
        let target = currentURL.absoluteString
        let host = target.urlHost
        guard !host.isEmpty, !host.contains("/") else { savedCurrent = false; return }
        let key = CanonicalURL.key(target)
        let candidates = (try? context.fetch(FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.deletedAt == nil && $0.url.contains(host) }))) ?? []
        savedCurrent = candidates.contains { CanonicalURL.key($0.url) == key }
    }

    /// Interpreta el texto de la barra: si parece dominio/URL navega; si no, busca en DuckDuckGo.
    private func navigateToAddress() {
        var text = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.contains("://") {
            if text.contains(" ") || !text.contains(".") {
                let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
                text = "https://duckduckgo.com/?q=\(q)"
            } else {
                text = "https://\(text)"
            }
        }
        guard let target = URL(string: text) else { return }
        readerHTML = nil
        addressFocused = false
        model.load(target)
    }

    /// Activa/desactiva el modo lectura. Si el enlace tiene copia sin conexión y seguimos
    /// en su página original, usa esa copia (instantánea y sin red); si no, descarga el
    /// contenido legible de la página actual (mismo extractor que la copia sin conexión).
    private func toggleReader() {
        if readerHTML != nil { readerHTML = nil; return }
        // Copia guardada: solo si no hemos navegado fuera del enlace original.
        let onOriginal = model.currentURLString.isEmpty || model.currentURLString == url.absoluteString
        if onOriginal, let saved = offlineHTML, !saved.isEmpty {
            readerHTML = saved
            return
        }
        loadingReader = true
        let target = currentURL.absoluteString
        Task { @MainActor in
            defer { loadingReader = false }
            readerHTML = await MacOfflineCopyService.fetchReadable(url: target)
        }
    }

    /// Handler de resaltado con tipo EXPLÍCITO (evita un fallo de inferencia del compilador
    /// con el closure `@MainActor` opcional). `nil` si la hoja se abrió sin enlace asociado.
    @MainActor
    private func highlightHandler() -> (@MainActor (String, String) -> Void)? {
        guard let bm = bookmark else { return nil }
        return { text, color in
            BookmarkActions.addHighlight(text: text, colorHex: color, to: bm, in: context)
        }
    }
}

/// Tema de lectura del modo lector (fondo + texto + enlaces), estilo Raindrop/Safari.
enum ReaderTheme: String, CaseIterable, Identifiable {
    case dark, sepia, light
    var id: String { rawValue }
    var label: String { switch self { case .dark: "Oscuro"; case .sepia: "Sepia"; case .light: "Claro" } }
    var icon: String { switch self { case .dark: "moon.fill"; case .sepia: "book.closed.fill"; case .light: "sun.max.fill" } }
    var bg: String { switch self { case .dark: "#0b0f17"; case .sepia: "#f4ecd8"; case .light: "#ffffff" } }
    var fg: String { switch self { case .dark: "#e8e6df"; case .sepia: "#5b4636"; case .light: "#1b1b1b" } }
    var link: String { switch self { case .dark: "#d6a62e"; case .sepia: "#9a6b3f"; case .light: "#0b7ed0" } }
    var scheme: String { self == .dark ? "dark" : "light" }
}

/// Tipografía del modo lectura (sans del sistema o serif clásica).
enum ReaderFont: String, CaseIterable, Identifiable {
    case sans, serif
    var id: String { rawValue }
    var label: String { self == .sans ? "Sans" : "Serif" }
    var css: String {
        self == .sans ? "-apple-system, system-ui, sans-serif" : "Georgia, 'Times New Roman', serif"
    }
}

/// Un resaltado a re-pintar en el lector: el fragmento de texto y su color (hex).
struct ReaderHighlight: Equatable {
    let text: String
    let color: String
}

/// Renderiza un HTML estático autocontenido en un `WKWebView` sin red (modo lectura y copia
/// sin conexión). Reutilizable por `InAppBrowserSheet` y `OfflineReaderView`. `fontPercent`
/// escala la tipografía (vía `pageZoom`); `theme`/`fontFamily` aplican un tema de lectura y
/// una tipografía mediante CSS inyectado (con `!important` para mandar sobre el del origen).
///
/// **Resaltado desde la selección (paridad con Raindrop):** si se pasa `onHighlight`, al
/// seleccionar texto aparece un popover flotante con colores; al elegir uno se resalta la
/// selección (vía la **CSS Custom Highlight API**, que NO modifica el DOM ni rompe el
/// layout) y se notifica el fragmento a Swift para crear un `Highlight`. Los `highlights`
/// ya guardados se re-pintan al cargar. El componente es genérico (no depende del modelo):
/// recibe los colores y el texto, y devuelve `(texto, colorHex)`.
struct StaticHTMLView: NSViewRepresentable {
    let html: String
    var fontPercent: Int = 100
    var theme: ReaderTheme = .dark
    var fontFamily: ReaderFont = .sans
    /// Resaltados existentes a re-pintar al cargar (vacío = ninguno).
    var highlights: [ReaderHighlight] = []
    /// Paleta de colores ofrecida en el popover de selección (hex). Vacío = sin popover.
    var highlightColors: [String] = []
    /// Se invoca al crear un resaltado desde la selección: (texto, colorHex). `nil` =
    /// resaltado desactivado (comportamiento clásico de solo lectura). Es `@MainActor`
    /// porque crea un `Highlight` en el `ModelContext` (WebKit entrega el mensaje en el
    /// hilo principal).
    var onHighlight: (@MainActor (String, String) -> Void)? = nil
    /// Clave (canónica) del enlace para PERSISTIR el progreso de lectura (% de scroll) y
    /// restaurarlo al volver. `nil` = no se sigue el progreso.
    var scrollKey: String? = nil

    /// HTML con el CSS de lectura inyectado (tema + tipografía + ancho de columna cómodo).
    private var styledHTML: String {
        let css = """
        <style>
        html, body { background: \(theme.bg) !important; color: \(theme.fg) !important; \
        font-family: \(fontFamily.css) !important; line-height: 1.65 !important; \
        color-scheme: \(theme.scheme); }
        body { padding: 28px !important; max-width: 720px !important; margin: 0 auto !important; }
        a { color: \(theme.link) !important; }
        img, video { max-width: 100% !important; height: auto !important; border-radius: 8px; }
        pre, code { background: rgba(127,127,127,0.14) !important; }
        h1, h2, h3, h4 { color: \(theme.fg) !important; }
        </style>
        """
        return css + html
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let ucc = config.userContentController
        // Resaltado activo: inyecta el script de selección/pintado y el puente a Swift.
        if onHighlight != nil {
            ucc.addUserScript(WKUserScript(
                source: Self.highlightJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: .defaultClient
            ))
            // Proxy DÉBIL: el `userContentController` retiene el handler; sin proxy
            // crearía un ciclo (ucc → coordinator). El proxy no retiene al coordinator.
            ucc.add(
                WeakMessageProxy(context.coordinator),
                contentWorld: .defaultClient,
                name: "slHighlight"
            )
        }
        // Progreso de lectura: reporta el % de scroll y restaura la posición al cargar.
        if scrollKey != nil {
            ucc.addUserScript(WKUserScript(
                source: Self.scrollJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true,
                in: .defaultClient
            ))
            ucc.add(
                WeakMessageProxy(context.coordinator),
                contentWorld: .defaultClient,
                name: "slScroll"
            )
        }
        let web = WKWebView(frame: .zero, configuration: config)
        if onHighlight != nil || scrollKey != nil { web.navigationDelegate = context.coordinator }
        context.coordinator.configure(colors: highlightColors, highlights: highlights, onHighlight: onHighlight)
        context.coordinator.scrollKey = scrollKey
        let styled = styledHTML
        context.coordinator.lastHTML = styled
        web.loadHTMLString(styled, baseURL: nil)
        web.pageZoom = CGFloat(fontPercent) / 100
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.configure(colors: highlightColors, highlights: highlights, onHighlight: onHighlight)
        context.coordinator.scrollKey = scrollKey
        let styled = styledHTML
        if context.coordinator.lastHTML != styled {
            context.coordinator.lastHTML = styled
            web.loadHTMLString(styled, baseURL: nil)
        }
        web.pageZoom = CGFloat(fontPercent) / 100
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        // Rompe el puente JS→Swift al cerrar (evita retención del web view).
        web.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    func makeCoordinator() -> Coordinator { Coordinator(html: "") }

    /// Coordinator: puente del puerto de mensajes JS y re-pintado de los resaltados al cargar.
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var lastHTML: String
        var scrollKey: String?
        private var colors: [String] = []
        private var highlights: [ReaderHighlight] = []
        private var onHighlight: (@MainActor (String, String) -> Void)?
        init(html: String) { lastHTML = html }

        func configure(colors: [String], highlights: [ReaderHighlight], onHighlight: (@MainActor (String, String) -> Void)?) {
            self.colors = colors
            self.highlights = highlights
            self.onHighlight = onHighlight
        }

        /// Al terminar de cargar: configura la paleta del popover, re-pinta los resaltados y
        /// restaura la posición de lectura guardada (continúa donde lo dejaste).
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let colorsJSON = jsonString(colors)
            let itemsJSON = jsonString(highlights.map { ["text": $0.text, "color": $0.color] })
            webView.evaluateJavaScript(
                "window.__slInit && window.__slInit(\(colorsJSON)); window.__slPaintExisting && window.__slPaintExisting(\(itemsJSON));",
                in: nil,
                in: .defaultClient,
                completionHandler: nil
            )
            if let key = scrollKey {
                let p = MainActor.assumeIsolated { ReadingProgressStore.progress(forKey: key) }
                if p > 0.01 {
                    webView.evaluateJavaScript(
                        "window.__slRestore && window.__slRestore(\(p));",
                        in: nil,
                        in: .defaultClient,
                        completionHandler: nil
                    )
                }
            }
        }

        /// Mensajes del JS: `slHighlight` (fragmento resaltado) o `slScroll` (% de lectura).
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame else { return }
            switch message.name {
            case "slHighlight":
                guard let body = message.body as? [String: Any],
                      let text = body["text"] as? String,
                      let color = body["color"] as? String,
                      colors.contains(color) else { return }
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, clean.count <= 20_000 else { return }
                // WebKit entrega los mensajes en el hilo principal: salta al MainActor para
                // crear el `Highlight` con seguridad de concurrencia.
                MainActor.assumeIsolated { onHighlight?(clean, color) }
            case "slScroll":
                guard let p = message.body as? Double, p.isFinite, (0...1).contains(p),
                      let key = scrollKey else { return }
                MainActor.assumeIsolated { ReadingProgressStore.setProgress(p, forKey: key) }
            default:
                break
            }
        }

        /// Serializa a JSON seguro para incrustar en `evaluateJavaScript`.
        private func jsonString(_ value: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value),
                  let s = String(data: data, encoding: .utf8) else { return "[]" }
            return s
        }
    }
}

/// Reenvía mensajes de `WKScriptMessageHandler` a un destino DÉBIL, para que el
/// `userContentController` (que retiene fuerte a sus handlers) no cree un ciclo de
/// retención con el coordinator del web view.
final class WeakMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}

extension StaticHTMLView {
    /// Script de progreso de lectura: reporta el % de scroll (throttled) y expone
    /// `__slRestore(p)` para volver a la posición guardada al cargar.
    static let scrollJS = """
    (function(){
      if (window.__slScroll) return; window.__slScroll = true;
      var t = null;
      function pct(){ var h = document.documentElement; var max = h.scrollHeight - h.clientHeight; return max > 0 ? (window.pageYOffset || h.scrollTop || 0) / max : 0; }
      function report(){ try { window.webkit.messageHandlers.slScroll.postMessage(pct()); } catch(e){} }
      window.addEventListener('scroll', function(){ if(t){ clearTimeout(t); } t = setTimeout(report, 300); }, { passive: true });
      window.__slRestore = function(p){ var h = document.documentElement; var max = h.scrollHeight - h.clientHeight; if(max > 0 && p > 0.01){ window.scrollTo(0, max * p); } };
    })();
    """

    /// Script inyectado para resaltar la selección y re-pintar los resaltados guardados.
    /// Usa la **CSS Custom Highlight API** (`CSS.highlights` + `::highlight()`), que pinta
    /// `Range`s sin tocar el DOM —robusto con selecciones que cruzan varios nodos y sin
    /// romper el layout—. Degrada con elegancia: si la API no existe, el resaltado no se
    /// pinta pero la cita igualmente se guarda (el `postMessage` sigue funcionando).
    static let highlightJS = """
    (function(){
      if (window.__slHL) return;
      var HL = { colors: [], objs: {}, popover: null };
      window.__slHL = HL;
      function name(hex){ return 'slhl-' + hex.replace('#','').toLowerCase(); }
      function rgba(hex, a){
        var r = parseInt(hex.substr(1,2),16), g = parseInt(hex.substr(3,2),16), b = parseInt(hex.substr(5,2),16);
        return 'rgba(' + r + ',' + g + ',' + b + ',' + a + ')';
      }
      function ensureStyle(colors){
        var css = '';
        colors.forEach(function(hex){ css += '::highlight(' + name(hex) + '){ background-color:' + rgba(hex,0.40) + '; border-radius:2px; }\\n'; });
        var st = document.getElementById('__slHLStyle');
        if(!st){ st = document.createElement('style'); st.id = '__slHLStyle'; (document.head||document.documentElement).appendChild(st); }
        st.textContent = css;
      }
      function obj(hex){
        if(!window.CSS || !CSS.highlights) return null;
        if(!HL.objs[hex]){ HL.objs[hex] = new Highlight(); CSS.highlights.set(name(hex), HL.objs[hex]); }
        return HL.objs[hex];
      }
      function firstRange(text){
        if(!text) return null;
        var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
        var node;
        while((node = walker.nextNode())){
          var i = node.nodeValue.indexOf(text);
          if(i >= 0){ var r = document.createRange(); r.setStart(node, i); r.setEnd(node, i + text.length); return r; }
        }
        return null;
      }
      window.__slInit = function(colors){ HL.colors = colors || []; ensureStyle(HL.colors.length ? HL.colors : ['#D4A853']); };
      window.__slPaintExisting = function(items){
        (items||[]).forEach(function(it){ var o = obj(it.color); var r = firstRange(it.text); if(o && r){ o.add(r); } });
      };
      function removePopover(){ if(HL.popover){ HL.popover.remove(); HL.popover = null; } }
      function showPopover(rect){
        removePopover();
        var pop = document.createElement('div');
        pop.id = '__slHLPopover';
        pop.style.cssText = 'position:fixed;z-index:2147483647;display:flex;gap:7px;padding:7px 9px;border-radius:11px;background:rgba(16,20,28,0.96);box-shadow:0 8px 24px rgba(0,0,0,0.5);';
        var palette = (HL.colors.length ? HL.colors : ['#D4A853']).slice(0,6);
        palette.forEach(function(hex){
          var sw = document.createElement('button');
          sw.style.cssText = 'width:18px;height:18px;border-radius:50%;border:1.5px solid rgba(255,255,255,0.55);cursor:pointer;padding:0;background:' + hex + ';';
          sw.addEventListener('mousedown', function(e){
            if(!e.isTrusted || HL.popover !== pop){ return; }
            e.preventDefault(); e.stopPropagation();
            var sel = window.getSelection();
            if(!sel || sel.isCollapsed){ removePopover(); return; }
            var text = sel.toString();
            if(!text.trim() || text.length > 20000){ removePopover(); return; }
            HL.popover = null;
            pop.remove();
            var o = obj(hex);
            if(o){ for(var k=0;k<sel.rangeCount;k++){ o.add(sel.getRangeAt(k).cloneRange()); } ensureStyle(HL.colors.length ? HL.colors : [hex]); }
            try { window.webkit.messageHandlers.slHighlight.postMessage({ text: text, color: hex }); } catch(err){}
            sel.removeAllRanges();
            removePopover();
          });
          pop.appendChild(sw);
        });
        document.body.appendChild(pop);
        HL.popover = pop;
        var w = pop.offsetWidth || (palette.length * 25 + 18);
        var top = rect.top - 42; if(top < 8){ top = rect.bottom + 8; }
        var left = rect.left + rect.width/2 - w/2;
        left = Math.max(8, Math.min(left, window.innerWidth - w - 8));
        pop.style.top = top + 'px'; pop.style.left = left + 'px';
      }
      document.addEventListener('mouseup', function(e){
        if(!e.isTrusted){ return; }
        setTimeout(function(){
          var sel = window.getSelection();
          if(!sel || sel.isCollapsed || !sel.toString().trim()){ return; }
          var rect = sel.getRangeAt(0).getBoundingClientRect();
          if(rect && (rect.width || rect.height)){ showPopover(rect); }
        }, 10);
      });
      document.addEventListener('mousedown', function(e){ if(HL.popover && !HL.popover.contains(e.target)){ removePopover(); } });
      document.addEventListener('scroll', function(){ removePopover(); }, true);
    })();
    """
}
