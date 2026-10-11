import SwiftUI
import SwiftData
import AppKit
import StacklumeCore
import StacklumeDesignSystem
import StacklumeMetadata

/// Utilidades compartidas por los widgets de «descubrir» (GitHub, repos, Hacker
/// News, dev.to, ofertas/juegos de Steam, App Store): guardar en la biblioteca,
/// acciones de contexto, lista compacta, botón de guardar y la vista ampliada
/// paginada. Versión macOS del soporte del iPhone (clic en vez de gestos táctiles,
/// `NSPasteboard` en vez de `UIPasteboard`, sin feedback háptico).
@MainActor
enum DiscoverWidget {
    /// Guarda un enlace externo en la biblioteca (evitando duplicados por URL) y
    /// lo enriquece en segundo plano. Devuelve `false` si ya existía.
    @discardableResult
    static func save(url urlString: String, title: String, imageURL: String?, in context: ModelContext) -> Bool {
        guard let parsed = StacklumeAutomationPolicy.openableStoredURL(urlString) else { return false }
        // Dedup por clave canónica (no por igualdad exacta): la misma página con/sin www,
        // tracking, etc. cuenta como ya guardada.
        let key = CanonicalURL.key(urlString)
        let already = (((try? context.fetch(FetchDescriptor<Bookmark>(
            predicate: #Predicate { $0.deletedAt == nil }))) ?? [])
            .contains { CanonicalURL.key($0.url) == key })
        if already { return false }
        // Alta por el embudo ÚNICO (`LinkIngest`): dedup canónico + plataforma + metadatos de
        // red + reglas + IA en segundo plano (autoorganizable, igual que cualquier otra alta).
        let link = LinkIngest.ingestLink(
            urlString: parsed.absoluteString,
            in: context,
            aiEnrich: true
        )
        // Aplica el título/imagen del feed si el enlace es nuevo y aún no los tiene mejores.
        if !title.isEmpty, link.title.isEmpty || link.title == (parsed.host() ?? "") { link.title = title }
        if let imageURL, !imageURL.isEmpty, link.imageURL?.isEmpty ?? true {
            link.imageURL = imageURL
            context.saveLogging()
        }
        return true
    }

    /// Copia un enlace al portapapeles del sistema (AppKit).
    static func copyToPasteboard(_ urlString: String) {
        NSPasteboard.copyString(urlString)
    }
}

/// Datos para guardar un elemento de descubrimiento en la biblioteca.
struct DiscoverSaveInfo {
    let url: String
    let title: String
    var imageURL: String? = nil
}

/// Añade a una fila de descubrimiento el menú contextual «Guardar en biblioteca»
/// / «Copiar enlace» (clic derecho). El clic normal lo gestiona `discoverRow`.
private struct DiscoverItemActions: ViewModifier {
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    let url: String
    let title: String
    let imageURL: String?

    func body(content: Content) -> some View {
        content.contextMenu {
            if let parsed = StacklumeAutomationPolicy.openableStoredURL(url) {
                Button {
                    openURL(parsed)
                } label: {
                    Label("Abrir original", systemImage: "arrow.up.right.square")
                }
            }
            Button {
                DiscoverWidget.save(url: url, title: title, imageURL: imageURL, in: context)
            } label: {
                Label("Guardar en biblioteca", systemImage: "bookmark")
            }
            Button {
                DiscoverWidget.copyToPasteboard(url)
            } label: {
                Label("Copiar enlace", systemImage: "doc.on.doc")
            }
        }
    }
}

extension View {
    /// Añade el menú contextual de acciones (guardar / copiar) a una fila.
    func discoverActions(url: String, title: String, imageURL: String? = nil) -> some View {
        modifier(DiscoverItemActions(url: url, title: title, imageURL: imageURL))
    }
}

/// Acción para ampliar un feed de descubrimiento a una hoja con la lista
/// completa. La gestiona la tarjeta-sección de «Descubrir» mediante su botón de
/// ampliar; es `nil` en la vista ya ampliada (`DiscoverDetailView`).
private struct DiscoverExpandActionKey: EnvironmentKey {
    // Valor por defecto `nil` inmutable: no hay estado mutable compartido, y la
    // acción inyectada se invoca siempre desde el MainActor (clics de UI). Por eso
    // `nonisolated(unsafe)` es seguro y evita exigir Sendable a la acción (que
    // captura una View con un @Model no-Sendable).
    nonisolated(unsafe) static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var discoverExpandAction: (() -> Void)? {
        get { self[DiscoverExpandActionKey.self] }
        set { self[DiscoverExpandActionKey.self] = newValue }
    }
}

/// Comportamiento de fila de descubrimiento en macOS: un clic abre el enlace;
/// clic derecho muestra el menú de guardar/copiar. (En iPhone el doble toque
/// ampliaba; en Mac la ampliación se ofrece desde la cabecera de la tarjeta.)
private struct DiscoverRowModifier: ViewModifier {
    @Environment(DiscoverSelection.self) private var discoverSelection: DiscoverSelection?
    @Environment(\.discoverSource) private var source
    let open: () -> Void
    let url: String
    let title: String
    let imageURL: String?

    func body(content: Content) -> some View {
        // Botón (en vez de `.onTapGesture`) para un clic FIABLE: en la sección Descubrir
        // (selección inyectada) selecciona el ítem → panel de detalle; en la vista
        // ampliada (hoja, sin selección) abre la URL.
        Button {
            if let discoverSelection, let source {
                discoverSelection.selected = DiscoverItem(
                    id: url, title: title, url: url, imageURL: imageURL,
                    sourceName: source.name, sourceIcon: source.icon)
            } else {
                open()
            }
        } label: {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .discoverActions(url: url, title: title, imageURL: imageURL)
    }
}

extension View {
    /// Aplica el comportamiento de fila de descubrimiento (clic = abrir, clic
    /// derecho = guardar/copiar).
    func discoverRow(url: String, title: String, imageURL: String? = nil,
                     open: @escaping () -> Void) -> some View {
        modifier(DiscoverRowModifier(open: open, url: url, title: title, imageURL: imageURL))
    }
}

/// Botón explícito para guardar un elemento en la biblioteca (vista ampliada).
/// Cambia a un check verde al guardar.
struct DiscoverSaveButton: View {
    @Environment(\.modelContext) private var context
    @Environment(\.themePalette) private var palette
    let url: String
    let title: String
    var imageURL: String? = nil
    @State private var saved = false

    var body: some View {
        Button {
            let ok = DiscoverWidget.save(url: url, title: title, imageURL: imageURL, in: context)
            withAnimation(.snappy) { saved = saved || ok }
        } label: {
            Image(systemName: saved ? "checkmark.circle.fill" : "plus.circle")
                .font(.title3)
                .foregroundStyle(saved ? Color(hex: "#22C55E") : palette.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(saved ? "Guardado" : "Guardar en biblioteca")
    }
}

/// Lista compacta de un widget de descubrimiento (dentro de la tarjeta). Muestra
/// solo las filas que CABEN ENTERAS en el alto disponible (acotadas además por
/// `limit`), midiendo el alto real de fila para no recortar ninguna por la mitad.
/// La versión completa, con scroll, vive en `DiscoverDetailView`.
struct DiscoverList<Item: Identifiable, Row: View>: View {
    @Environment(\.themePalette) private var palette
    let items: [Item]
    let limit: Int
    var spacing: CGFloat = 9
    @ViewBuilder let row: (Item) -> Row

    /// Alto real de la fila más alta (medido). 0 hasta la primera medición.
    @State private var rowHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let count = visibleCount(available: geo.size.height)
            let shown = Array(items.prefix(count))
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(shown) { item in
                    row(item)
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(key: RowHeightKey.self, value: g.size.height)
                            }
                        )
                    if item.id != shown.last?.id {
                        Divider().overlay(palette.border.opacity(0.4))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onPreferenceChange(RowHeightKey.self) { h in
                if h > 0 { rowHeight = h }
            }
        }
    }

    /// Cuántas filas caben enteras en `available`, acotado por `limit` y por los datos.
    private func visibleCount(available: CGFloat) -> Int {
        guard available > 0, rowHeight > 0 else { return min(limit, items.count) }
        let divider: CGFloat = 1
        let slot = rowHeight + spacing + divider
        let n = Int((available + spacing + divider) / slot)
        return max(1, min(limit, n, items.count))
    }
}

/// Mide el alto de la fila más alta de un `DiscoverList`.
private struct RowHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Estado de carga / sin resultados / error común a los widgets de descubrimiento.
///
/// Uso retrocompatible: el parámetro `error` y `retryAction` son opcionales con
/// valor por defecto, por lo que todos los usos existentes (`DiscoverPlaceholder(loading: …)`)
/// siguen compilando sin ningún cambio.
///
/// Estados:
/// - `loading = true`  → spinner de progreso.
/// - `loading = false, error = false` → «Sin novedades por ahora» (feed vacío OK).
/// - `loading = false, error = true`  → «No se pudo cargar» + botón «Reintentar» (si hay acción).
struct DiscoverPlaceholder: View {
    @Environment(\.themePalette) private var palette
    let loading: Bool
    /// `true` cuando la carga falló por error de red u otro motivo (no por feed vacío).
    var error: Bool = false
    /// Acción opcional del botón «Reintentar» (solo visible en estado de error).
    var retryAction: (() -> Void)? = nil

    var body: some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if error {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(palette.textSecondary)
                Text("No se pudo cargar")
                    .stacklumeFont(.caption2)
                    .foregroundStyle(palette.textSecondary)
                if let retryAction {
                    Button("Reintentar", action: retryAction)
                        .stacklumeFont(.caption2)
                        .tint(palette.accent)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 4) {
                Image(systemName: "rays")
                    .foregroundStyle(palette.textSecondary)
                Text("Sin novedades por ahora")
                    .stacklumeFont(.caption2)
                    .foregroundStyle(palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Vista ampliada (hoja) de un widget de descubrimiento: lista COMPLETA con
/// scroll vertical y paginación (scroll infinito), controles opcionales de
/// orden/modo arriba, y un botón de guardar por fila. Clic en una fila abre el
/// enlace; el botón + lo guarda en la biblioteca.
struct DiscoverDetailView<Item: Identifiable, RowView: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette

    let title: String
    let icon: String
    /// Controles (menú de orden/modo) mostrados fijos en la parte superior.
    var controls: AnyView? = nil
    /// Al cambiar (p. ej. el orden), se reinicia la paginación.
    let resetKey: String
    /// Carga la página `n` (empieza en 1). Devuelve [] cuando no hay más.
    let loadPage: (Int) async -> [Item]
    let saveInfo: (Item) -> DiscoverSaveInfo
    @ViewBuilder let row: (Item) -> RowView

    @State private var items: [Item] = []
    @State private var page = 0
    @State private var loading = false
    @State private var reachedEnd = false
    @State private var seen: Set<AnyHashable> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.border.opacity(0.4))
            if let controls {
                controls
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider().overlay(palette.border.opacity(0.4))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .top, spacing: 12) {
                                row(item)
                                let info = saveInfo(item)
                                DiscoverSaveButton(url: info.url, title: info.title, imageURL: info.imageURL)
                            }
                            Divider().overlay(palette.border.opacity(0.4))
                        }
                        // Al hacerse visible el último elemento, carga la siguiente página.
                        .onAppear {
                            if item.id == items.last?.id { Task { await loadMore() } }
                        }
                    }
                    footer
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
        }
        .frame(minWidth: 460, minHeight: 520)
        .background(palette.background)
        // En la vista ya ampliada, las filas solo abren el enlace (no re-amplían).
        .environment(\.discoverExpandAction, nil)
        .task(id: resetKey) { await reset() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(palette.accent)
            Text(title)
                .stacklumeFont(.headline)
                .foregroundStyle(palette.textPrimary)
            Spacer(minLength: 0)
            Button("Cerrar") { dismiss() }
                .tint(palette.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var footer: some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        } else if reachedEnd, items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "rays").font(.title3)
                Text("Sin resultados por ahora").stacklumeFont(.caption)
            }
            .foregroundStyle(palette.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else if reachedEnd {
            Text("No hay más resultados")
                .stacklumeFont(.caption2)
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
    }

    private func reset() async {
        items = []
        page = 0
        reachedEnd = false
        seen = []
        await loadMore()
    }

    private func loadMore() async {
        guard !loading, !reachedEnd else { return }
        loading = true
        let next = await loadPage(page + 1)
        page += 1
        let fresh = next.filter { seen.insert(AnyHashable($0.id)).inserted }
        items.append(contentsOf: fresh)
        if next.isEmpty { reachedEnd = true }
        loading = false
    }
}

/// Helpers para obtener iconos/previews fiables a partir de una URL. La clave para
/// que «se adquieran bien las imágenes»: NO depender de un único candidato (que a
/// veces falta o da 404), sino aportar una CASCADA de respaldos a `RemoteImage`.
enum PreviewImage {
    /// Favicon/icono del dominio de una URL (Google S2 + DuckDuckGo como respaldo).
    static func favicon(for urlString: String?, size: Int = 128) -> [String] {
        guard let urlString,
              let host = URL(string: urlString)?.host, !host.isEmpty else { return [] }
        return [
            "https://www.google.com/s2/favicons?domain=\(host)&sz=\(size)",
            "https://icons.duckduckgo.com/ip3/\(host).ico"
        ]
    }

    /// Avatar del propietario de un repo de GitHub (logo del proyecto, muy fiable).
    /// `https://github.com/OWNER/REPO` → `https://github.com/OWNER.png?size=…`.
    static func githubAvatar(forRepoURL repoURL: String?, size: Int = 200) -> String? {
        guard let repoURL, let url = URL(string: repoURL),
              (url.host?.contains("github.com") ?? false) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let owner = parts.first, !owner.isEmpty else { return nil }
        return "https://github.com/\(owner).png?size=\(size)"
    }

    /// ¿La URL es un favicon/icono diminuto? Estos NUNCA deben usarse como portada
    /// grande (estirados se ven pixelados); solo como icono pequeño y nítido.
    static func isFavicon(_ urlString: String?) -> Bool {
        guard let s = urlString?.lowercased() else { return false }
        return s.contains("s2/favicons") || s.contains("icons.duckduckgo")
            || s.contains("/favicon") || s.hasSuffix(".ico")
    }
}

/// Renderiza una imagen YA cargada como portada SIN ampliarla nunca por encima de su
/// resolución nativa (la causa de las portadas «blandas»/borrosas). Decide según los
/// PÍXELES reales de la imagen y el tamaño del marco:
/// - si tiene píxeles de sobra para LLENAR el marco a sangre → `scaledToFill` (nítido);
/// - si no → fondo desenfocado (sí puede ampliarse; el blur lo disimula) + la imagen
///   centrada a su tamaño NATIVO como máximo (1 píxel de imagen = 1 de pantalla → nítida),
///   estilo Apple Music. Así un banner de alta resolución llena, y uno pequeño o un logo
///   se ve nítido y premium en vez de reventado.
struct CoverImageContent: View {
    @Environment(\.displayScale) private var displayScale
    let image: NSImage

    /// Dimensiones REALES en píxeles (no en puntos) de la imagen.
    private var pixelSize: CGSize {
        var w = 0, h = 0
        for rep in image.representations { w = max(w, rep.pixelsWide); h = max(h, rep.pixelsHigh) }
        return (w > 0 && h > 0) ? CGSize(width: w, height: h) : image.size
    }

    var body: some View {
        GeometryReader { geo in
            let px = pixelSize
            let scale = max(displayScale, 1)
            // Píxeles de dispositivo que hay que cubrir para llenar el marco a sangre.
            let needW = geo.size.width * scale, needH = geo.size.height * scale
            let fillsSharp = px.width >= needW && px.height >= needH
            let aspect = px.height > 0 ? px.width / px.height : 1
            let bannerish = max(px.width, px.height) >= 360 && aspect >= 1.2
            let pad = min(geo.size.width, geo.size.height) * 0.10

            ZStack {
                if bannerish && fillsSharp {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                } else {
                    Image(nsImage: image).resizable().scaledToFill()
                        .blur(radius: 26).opacity(0.5)
                    // NÍTIDA: nunca por encima de su tamaño nativo en puntos (px / escala).
                    Image(nsImage: image).resizable().interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: px.width / scale, maxHeight: px.height / scale)
                        .padding(pad)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Portada premium reutilizable (héroe del detalle de Descubrir y de la biblioteca, y
/// portadas de galería). Carga la mejor imagen disponible (alta resolución primero) y la
/// presenta con `CoverImageContent` (nunca amplía por encima de lo nativo). Si nada carga,
/// muestra el símbolo de respaldo sobre un fondo de marca.
struct HeroCoverImage: View {
    @Environment(\.themePalette) private var palette
    let candidates: [String?]
    let fallbackSymbol: String
    /// Color del fondo/respaldo (por defecto, dorado). Útil para el color de marca.
    var tint: Color? = nil

    @State private var image: NSImage?
    @State private var finished = false

    private var accent: Color { tint ?? palette.accent }

    var body: some View {
        ZStack {
            palette.surface
            RadialGradient(colors: [accent.opacity(0.18), .clear],
                           center: .center, startRadius: 4, endRadius: 240)
            if let image {
                CoverImageContent(image: image)
                    .transition(.opacity)   // entra con un fundido suave, no de golpe
            } else if finished {
                Image(systemName: fallbackSymbol)
                    .scaledFont(40, weight: .semibold, scalesWithText: false)
                    .foregroundStyle(accent.opacity(0.55))
                    .transition(.opacity)
            } else {
                SkeletonView()
            }
        }
        .clipped()
        .task(id: candidates) { await load() }
    }

    private func load() async {
        finished = false
        image = nil
        for candidate in candidates {
            guard let candidate, let url = URL(string: candidate) else { continue }
            if let loaded = await SecureImageCache.shared.image(for: url) {
                // Fundido de entrada suave (premium) en lugar de un «pop» brusco.
                withAnimation(.easeOut(duration: 0.35)) { image = loaded }
                finished = true
                return
            }
        }
        withAnimation(.easeOut(duration: 0.25)) { finished = true }
    }
}

/// Color del punto de lenguaje de un repositorio. Es el helper canónico del Mac:
/// `RepoStatsBar` (Mac) delega aquí, igual que el iPhone usaba su propio método
/// estático. Centralizado para no duplicar la paleta de colores GitHub.
enum RepoLanguageColor {
    static func color(for language: String) -> Color {
        switch language.lowercased() {
        case "swift": Color(hex: "#F05138")
        case "javascript": Color(hex: "#F1E05A")
        case "typescript": Color(hex: "#3178C6")
        case "python": Color(hex: "#3572A5")
        case "kotlin": Color(hex: "#A97BFF")
        case "java": Color(hex: "#B07219")
        case "rust": Color(hex: "#DEA584")
        case "go": Color(hex: "#00ADD8")
        case "c", "c++", "c#": Color(hex: "#178600")
        case "ruby": Color(hex: "#701516")
        case "php": Color(hex: "#4F5D95")
        case "html": Color(hex: "#E34C26")
        case "css", "scss": Color(hex: "#563D7C")
        case "dart": Color(hex: "#00B4AB")
        case "shell": Color(hex: "#89E051")
        default: Color(hex: "#8B949E")
        }
    }
}
