import SwiftUI
import StacklumeCore
import StacklumeDesignSystem

/// Modos de visualización de la Biblioteca (paridad con el proyecto iPhone real:
/// Lista, Cuadrícula, Moodboard/mosaico, Titulares).
enum LibraryViewMode: String, CaseIterable, Identifiable {
    case list, grid, moodboard, headlines

    var id: String { rawValue }

    var label: String {
        switch self {
        case .list: "Lista"
        case .grid: "Cuadrícula"
        case .moodboard: "Moodboard"
        case .headlines: "Titulares"
        }
    }

    var icon: String {
        switch self {
        case .list: "list.bullet"
        case .grid: "square.grid.2x2"
        case .moodboard: "rectangle.3.offgrid"
        case .headlines: "text.alignleft"
        }
    }

    /// Siguiente modo (para el botón cíclico de la toolbar).
    var next: LibraryViewMode {
        let all = LibraryViewMode.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx + 1) % all.count]
    }
}

/// Tarjeta de moodboard: mural visual INMERSIVO tipo Pinterest. La portada LLENA la
/// tarjeta a sangre (`scaledToFill`) y el título se superpone sobre un degradado inferior.
/// Sin host ni adornos: la imagen manda. Si no hay imagen, un tile de color con el título.
///
/// La tarjeta LLENA el ANCHO de su columna (lo fija el muro, que controla el deslizador
/// de tamaño de portada) y su ALTURA sale de la proporción real de la imagen (alturas
/// variables → masonry). La proporción se resuelve leyendo el tamaño de `ImageCache`
/// (`resolveAspect`); mientras carga usa una estimación y refina al valor real.
struct MoodboardCard: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let link: Bookmark

    /// Proporción REAL de la portada (ancho/alto). `nil` hasta resolver → estimación.
    @State private var aspect: CGFloat?
    /// Hover: eleva la tarjeta con una escala sutil + sombra (premium, como Raindrop).
    @State private var isHovering = false
    /// Portadas personalizadas: tienen prioridad sobre la `imageURL` autodetectada.
    @State private var coverStore = CustomCoverStore.shared

    // Color del enlace: el de su plataforma si lo tiene; si no, uno estable derivado
    // del host, para que el mural quede como un mosaico variado y no monótono.
    private var accent: Color { link.platformColor.map { Color(hex: $0) } ?? Color(seed: link.url.urlHost) }
    private var title: String { link.title.isEmpty ? link.url.urlHost : link.title }

    private var coverImage: PlatformImage? {
        if let data = link.fileData, link.fileKind == "image" { return PlatformImage(data: data) }
        return nil
    }

    /// Proporción efectiva de la portada, acotada a un rango cómodo (ni cintas ni torres).
    private var resolvedAspect: CGFloat {
        min(1.5, max(0.8,aspect ?? MoodboardLayout.estimatedAspect(link)))
    }

    var body: some View {
        // Blindaje anti-crash SwiftData: no renderizar un modelo ya invalidado.
        if link.modelContext == nil {
            EmptyView()
        } else {
            // La tarjeta LLENA el ancho de su columna (lo da el muro, que controla el
            // deslizador); la altura sale de la proporción real → muro tipo Pinterest. La
            // portada `scaledToFill` LLENA el tile y se recorta dentro del `clipShape`.
            Color.clear
                .aspectRatio(resolvedAspect, contentMode: .fit)
                .overlay { cover }
                // Degradado inferior + título superpuesto (solo con imagen real) para
                // garantizar legibilidad del título sobre cualquier portada.
                .overlay(alignment: .bottomLeading) {
                    if hasImage {
                        ZStack(alignment: .bottomLeading) {
                            LinearGradient(colors: [.clear, .black.opacity(0.6)],
                                           startPoint: .center, endPoint: .bottom)
                            Text(title)
                                .stacklumeFont(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .stacklumeLineLimit(2)
                                .shadow(radius: 3)
                                .padding(DesignSystem.Spacing.sm)
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if link.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(palette.accent)
                            .padding(5)
                            .background(.black.opacity(0.4), in: Circle())
                            .padding(6)
                            .accessibilityLabel("Favorito")
                    }
                }
                // La máscara debe envolver la composición COMPLETA. Antes se aplicaba
                // antes del degradado y la estrella; el overlay inferior quedaba fuera
                // del recorte y sus esquinas negras rectangulares sobresalían del tile.
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                // Elevación premium al pasar el ratón: escala sutil + sombra (Reduce
                // Motion: solo sombra). El cristal del muro «cobra vida» como en Raindrop.
                .scaleEffect(isHovering && !reduceMotion ? 1.03 : 1)
                .shadow(color: .black.opacity(isHovering ? 0.32 : 0), radius: isHovering ? 16 : 0, y: isHovering ? 8 : 0)
                .zIndex(isHovering ? 1 : 0)
                .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: isHovering)
                .onHover { isHovering = $0 }
                // Vista previa rica al pasar el ratón: el Moodboard solo muestra la imagen,
                // así que el popover aporta título, descripción y etiquetas.
                .linkHoverPreview(link)
                .draggable(BookmarkTransfer(from: link))
                .task(id: "\(link.imageURL ?? "")|\(coverStore.currentVersion(for: link.id))") {
                    await resolveAspect()
                }
        }
    }

    private var hasImage: Bool {
        coverStore.has(link.id) || coverImage != nil || (link.imageURL?.isEmpty == false)
    }

    // Muro tipo Pinterest: la imagen LLENA el tile a sangre (el tile ya tiene su MISMA
    // proporción, así que no recorta) con alta interpolación → nítida. (El relleno a
    // sangre es el look correcto de un muro; el tratamiento pixel-aware con fondo
    // desenfocado se reserva al héroe del detalle, donde la imagen se muestra entera.)
    @ViewBuilder
    private var cover: some View {
        if let custom = coverStore.image(for: link.id) {
            // Portada personalizada (prioridad).
            Image(platformImage: custom).resizable().interpolation(.high).scaledToFill()
        } else if let image = coverImage {
            Image(platformImage: image).resizable().interpolation(.high).scaledToFill()
        } else if let imageURL = link.imageURL, !imageURL.isEmpty {
            // Adquisición HD: prueba primero la variante de mayor resolución.
            SecureRemoteImage(candidates: HDImage.candidates(imageURL), skeleton: { SkeletonView() }) { colorTile }
        } else {
            colorTile
        }
    }

    /// Portada de respaldo para enlaces SIN og:image: muestra el LOGO/favicon del sitio
    /// centrado sobre un degradado de marca (como Raindrop con los enlaces sin imagen),
    /// con el título debajo. Si no hay favicon, el glifo de la plataforma. Así estas
    /// tarjetas tienen una portada reconocible en vez de un placeholder genérico.
    private var colorTile: some View {
        ZStack {
            LinearGradient(colors: [accent.opacity(0.9), accent.opacity(0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: DesignSystem.Spacing.sm) {
                SecureRemoteImage(candidates: [link.faviconURL] + PreviewImage.favicon(for: link.url, size: 256).map { Optional($0) }) {
                    Image(systemName: link.platform.sfSymbol)
                        .scaledFont(30, weight: .regular, scalesWithText: false)
                        .foregroundStyle(.white.opacity(0.92))
                }
                .frame(width: 64, height: 64)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(title)
                    .stacklumeFont(.caption.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(palette.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    /// Resuelve el tamaño NÍTIDO del tile a partir de la resolución REAL (en píxeles) de
    /// la portada: imagen local (síncrona) o remota (caché o descarga). El ancho nunca
    /// supera píxeles/escala (1 px imagen ≈ 1 px pantalla → sin ampliar = sin borrosos).
    /// Resuelve la proporción REAL de la portada (imagen local síncrona; remota desde
    /// caché o descarga) y refina la tarjeta al cargar.
    @MainActor
    private func resolveAspect() async {
        if let custom = coverStore.image(for: link.id), custom.size.height > 0 {
            setAspect(custom.size.width / custom.size.height); return
        }
        if let img = coverImage, img.size.width > 0, img.size.height > 0 {
            setAspect(img.size.width / img.size.height); return
        }
        guard let urlStr = link.imageURL, !urlStr.isEmpty, let url = URL(string: urlStr) else { return }
        if let cached = SecureImageCache.shared.cached(for: url), cached.size.height > 0 {
            setAspect(cached.size.width / cached.size.height); return
        }
        if let loaded = await SecureImageCache.shared.image(for: url), loaded.size.height > 0 {
            setAspect(loaded.size.width / loaded.size.height)
        }
    }

    private func setAspect(_ value: CGFloat) {
        let clamped = min(1.5, max(0.8,value))
        if aspect == nil || abs((aspect ?? 0) - clamped) > 0.01 { aspect = clamped }
    }
}

/// Cálculo del muro masonry del Moodboard: proporción estimada por enlace (para colocar y
/// balancear las columnas antes de que cargue la portada) y reparto greedy en columnas.
enum MoodboardLayout {
    /// Proporción estimada (ancho/alto). Usa el tamaño cacheado de la portada si está; si
    /// no, una variación estable derivada de la URL para que el muro no quede monótono.
    @MainActor
    static func estimatedAspect(_ link: Bookmark) -> CGFloat {
        if let urlStr = link.imageURL, let url = URL(string: urlStr),
           let img = SecureImageCache.shared.cached(for: url), img.size.height > 0 {
            return min(1.5, max(0.8,img.size.width / img.size.height))
        }
        let ratios: [CGFloat] = [0.85, 1.0, 1.33, 0.9, 1.45, 1.0, 1.2, 0.95]
        return ratios[stableHash(link.imageURL ?? link.url) % ratios.count]
    }

    /// Hash estable entre lanzamientos (FNV-1a): `String.hashValue` se aleatoriza por
    /// proceso, lo que cambiaría la disposición del muro en cada arranque.
    static func stableHash(_ s: String) -> Int {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Int(h & 0x7fffffff)
    }

    /// Reparte los enlaces en `columns` columnas balanceando por ALTURA estimada (greedy:
    /// cada enlace va a la columna actualmente más corta). Es lo que hace un masonry tipo
    /// Pinterest/Raindrop: las columnas se apilan verticalmente sin huecos. Conserva el
    /// orden de la lista dentro de cada columna.
    @MainActor
    static func distribute(_ links: [Bookmark], into columns: Int) -> [[Bookmark]] {
        guard columns > 1 else { return [links] }
        var buckets = Array(repeating: [Bookmark](), count: columns)
        var heights = Array(repeating: CGFloat(0), count: columns)
        for link in links {
            let h = 1 / max(0.3, estimatedAspect(link))   // alto relativo (los retratos pesan más)
            var idx = 0
            for c in 1..<columns where heights[c] < heights[idx] { idx = c }
            buckets[idx].append(link)
            heights[idx] += h
        }
        return buckets
    }
}

/// Fila de «Titulares»: ultra-densa, solo texto (punto de color + título + host),
/// una línea. Pensada para escanear muchísimos enlaces de un vistazo (estilo RSS).
struct HeadlineRow: View {
    @Environment(\.themePalette) private var palette
    let link: Bookmark

    private var accent: Color { link.platformColor.map { Color(hex: $0) } ?? palette.accent }

    var body: some View {
        // Blindaje anti-crash SwiftData: no renderizar un modelo ya invalidado.
        if link.modelContext == nil {
            EmptyView()
        } else {
            rowBody
        }
    }

    private var rowBody: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(link.isRead ? palette.textSecondary.opacity(0.4) : accent)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)  // Decorativo: el estado leído lo anuncia el texto
            Text(link.title.isEmpty ? link.url : link.title)
                .stacklumeFont(.subheadline)
                .foregroundStyle(link.isRead ? palette.textSecondary : palette.textPrimary)
                .stacklumeLineLimit(1)
            Spacer(minLength: 8)
            Text(link.url.urlHost)
                .stacklumeFont(.caption2)
                .foregroundStyle(palette.textSecondary)
                .stacklumeLineLimit(1)
                .layoutPriority(-1)
            if link.isFavorite {
                Image(systemName: "star.fill").scaledFont(9, scalesWithText: false).foregroundStyle(palette.accent)
                    .accessibilityLabel("Favorito")
            }
        }
        .padding(.vertical, 2)
        .draggable(BookmarkTransfer(from: link))
    }
}
