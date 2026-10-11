import SwiftUI
import StacklumeCore
import StacklumeDesignSystem

/// Tarjeta de vista previa que aparece al pasar el ratón (paridad Raindrop): portada
/// grande + título + host + descripción + etiquetas + tipo/fecha. Da contexto rico sin
/// abrir la ficha, sobre todo en la Lista y el Moodboard, donde la fila/baldosa no
/// muestra ni portada ni descripción. Solo lectura.
struct LinkPreviewCard: View {
    let link: Bookmark
    @Environment(\.themePalette) private var palette
    @State private var coverStore = CustomCoverStore.shared

    private var host: String {
        URL(string: link.url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? link.url
    }
    private var brand: Color { Color(hex: link.platformColor ?? link.platform.brandColorHex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
                .frame(width: 340, height: 191)   // 16:9
                .clipped()
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(link.title.isEmpty ? host : link.title)
                    .stacklumeFont(.headline.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                    .stacklumeLineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    PlatformBadge(platform: link.platform, size: 16)
                        .accessibilityHidden(true)  // Decorativo: el host lo identifica
                    Text(host).stacklumeFont(.caption).foregroundStyle(palette.textSecondary).stacklumeLineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: link.contentType.sfSymbol).font(.caption2)
                        .foregroundStyle(palette.textSecondary)
                        .accessibilityLabel(link.contentType.displayName)
                    Text(link.createdAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                        .stacklumeFont(.caption2).monospacedDigit().foregroundStyle(palette.textSecondary)
                }

                if let details = link.details?.trimmingCharacters(in: .whitespacesAndNewlines), !details.isEmpty {
                    Text(details)
                        .stacklumeFont(.callout)
                        .foregroundStyle(palette.textSecondary)
                        .stacklumeLineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !link.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(link.tags.prefix(4)) { TagChip(tag: $0) }
                    }
                }
            }
            .padding(DesignSystem.Spacing.sm)
        }
        .frame(width: 340)
        .background(palette.surface)
    }

    /// Misma cascada de portada que las tarjetas: personalizada → og:image → logo centrado.
    private var cover: some View {
        ZStack {
            palette.surface
            if let custom = coverStore.image(for: link.id) {
                Image(platformImage: custom).resizable().interpolation(.high).scaledToFill()
            } else {
                SecureRemoteImage(candidates: HDImage.candidates(link.imageURL), skeleton: { SkeletonView() }) {
                    ZStack {
                        RadialGradient(colors: [brand.opacity(0.20), .clear], center: .top, startRadius: 0, endRadius: 200)
                        SecureRemoteImage(candidates: [link.faviconURL] + PreviewImage.favicon(for: link.url, size: 256).map { Optional($0) }) {
                            Image(systemName: link.platform.sfSymbol)
                                .scaledFont(34, weight: .regular, scalesWithText: false)
                                .foregroundStyle(brand.opacity(0.55))
                        }
                        .frame(width: 64, height: 64)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
    }
}

/// Muestra `LinkPreviewCard` en un popover tras un breve retardo de hover (~0,55 s), para
/// que un paseo rápido del ratón NO dispare popovers. Se ancla a un objetivo PEQUEÑO (el
/// favicon/portada), no a toda la fila, para no competir con el clic de selección.
/// Conjunto de IDs de enlaces SELECCIONADOS (visibles en el panel de detalle). Se publica por
/// Environment desde la vista que posee la selección; la preview de hover se omite para ellos.
private struct SelectedLinkIDsKey: EnvironmentKey {
    static let defaultValue: Set<Bookmark.ID> = []
}
extension EnvironmentValues {
    var selectedLinkIDs: Set<Bookmark.ID> {
        get { self[SelectedLinkIDsKey.self] }
        set { self[SelectedLinkIDsKey.self] = newValue }
    }
}

// MARK: - Presentador a nivel de VENTANA (sin popover)

/// Estado compartido del preview. ANTES se usaba `.popover`, que en macOS es TRANSITORIO: al
/// estar visible y hacer clic fuera, ese primer clic se CONSUME al cerrarlo → había que clicar
/// dos veces para navegar (lo que el usuario notaba como «click varias veces»). Ahora el preview
/// se pinta como un overlay normal a nivel de ventana, que NO captura ni consume eventos: navegar
/// con un preview abierto registra el clic a la primera.
@MainActor
@Observable
final class LinkPreviewPresenter {
    private(set) var link: Bookmark?

    func present(_ link: Bookmark) {
        guard link.modelContext != nil else { return }   // nunca un enlace borrado (anti-crash)
        self.link = link
    }
    /// Oculta el preview de `id` (solo si es el que se muestra). Idempotente.
    func hide(_ id: UUID) { if link?.id == id { link = nil } }
    /// Oculta el preview que se esté mostrando (al scrollear/deslizar). Idempotente.
    func hideCurrent() { if link != nil { link = nil } }
}

/// Publica el marco (bounds) de cada fila con preview, indexado por id de enlace. El overlay
/// resuelve el del enlace mostrado con `proxy[anchor]`, que da coordenadas LOCALES exactas SIN
/// depender de un espacio de coordenadas con nombre (este último arrastraba un desfase oculto
/// —la barra de título/safe area— que hacía caer la tarjeta y la flecha una fila más abajo).
private struct PreviewAnchorKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct LinkPreviewPresenterKey: EnvironmentKey {
    static let defaultValue: LinkPreviewPresenter? = nil
}
extension EnvironmentValues {
    var linkPreviewPresenter: LinkPreviewPresenter? {
        get { self[LinkPreviewPresenterKey.self] }
        set { self[LinkPreviewPresenterKey.self] = newValue }
    }
}

private struct LinkHoverPreviewModifier: ViewModifier {
    let link: Bookmark
    let edge: Edge
    /// Desactiva la preview por contexto (lista perezosa, tarjetas del tablero Kanban). Cuando es
    /// `false` el modifier es un NO-OP total: sin GeometryReader ni hover → cero coste en el scroll.
    var enabled: Bool = true

    func body(content: Content) -> some View {
        if enabled {
            content.modifier(ActiveLinkHoverPreview(link: link))
        } else {
            content
        }
    }
}

/// Tracking del hover SOLO donde el preview está habilitado. Mide el marco del elemento (en una
/// caja de referencia, para no re-renderizar la tarjeta al scrollear) y, tras el retardo, lo
/// presenta en el overlay de ventana vía el `LinkPreviewPresenter`.
private struct ActiveLinkHoverPreview: ViewModifier {
    /// Coordinación interna que no participa en el render. Mantenerla como referencia no
    /// observable evita invalidar y recomponer la `List` nativa desde cada callback `onHover`.
    private final class HoverState {
        var isInside = false
        var generation = 0
    }

    let link: Bookmark
    @Environment(\.selectedLinkIDs) private var selectedIDs
    @Environment(\.linkPreviewPresenter) private var presenter
    @State private var hoverState = HoverState()

    /// La preview se muestra solo si el enlace NO está seleccionado (si lo está, ya se ve completo
    /// en el panel de detalle).
    private var active: Bool { !selectedIDs.contains(link.id) }

    func body(content: Content) -> some View {
        content
            // Publica el marco de ESTA fila (bounds) para que el overlay lo resuelva con proxy[anchor].
            .anchorPreference(key: PreviewAnchorKey.self, value: .bounds) { [link.id: $0] }
            .onHover { isInside in
                guard active else { presenter?.hide(link.id); return }
                hoverState.isInside = isInside
                if isInside {
                    hoverState.generation &+= 1
                    let mine = hoverState.generation
                    Task { @MainActor in
                        // Retardo (1,4 s): un paseo rápido del ratón mientras navegas NO lo dispara;
                        // solo aparece si te detienes a propósito sobre el enlace.
                        try? await Task.sleep(for: .seconds(1.4))
                        // No aparece si acabas de scrollear/deslizar (taparía el swipe / estorbaría).
                        if hoverState.isInside, active, mine == hoverState.generation,
                           !UserActivityMonitor.shared.recentlyScrolled(within: 1.0) {
                            presenter?.present(link)
                        }
                    }
                } else {
                    hoverState.generation &+= 1
                    presenter?.hide(link.id)
                }
            }
            .onChange(of: selectedIDs.contains(link.id)) { _, nowSelected in
                if nowSelected { hoverState.generation &+= 1; presenter?.hide(link.id) }
            }
            .onDisappear { hoverState.generation &+= 1; presenter?.hide(link.id) }
    }
}

/// Punta de bocadillo del preview: un triángulo que sale del recuadro y apunta al enlace al
/// que pertenece (como antes con el `.popover`, pero aquí dibujada a mano para NO reintroducir
/// el popover, que consumía el clic). `pointsLeft`: la punta mira a la IZQUIERDA (tarjeta a la
/// derecha del enlace) o a la DERECHA (tarjeta a la izquierda). La base queda pegada al recuadro.
private struct CalloutArrow: Shape {
    var pointsLeft: Bool
    /// `true` (relleno): triángulo cerrado. `false` (borde): solo los dos lados que apuntan,
    /// SIN la base, para que el trazo no dibuje una línea sobre el borde de la tarjeta.
    var closed: Bool = true
    func path(in rect: CGRect) -> Path {
        var p = Path()
        if pointsLeft {
            // Base en el borde derecho; vértice (punta) a la izquierda.
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            // Base en el borde izquierdo; vértice (punta) a la derecha.
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        if closed { p.closeSubpath() }
        return p
    }
}

/// Overlay del preview a nivel de ventana. Pinta `LinkPreviewCard` flotando junto al elemento
/// anclado, SIN capturar el ratón (`allowsHitTesting(false)` en toda la capa). Auto-flip a la
/// izquierda si no cabe a la derecha. Define el espacio de coordenadas compartido.
private struct LinkPreviewLayerModifier: ViewModifier {
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presenter = LinkPreviewPresenter()
    /// Alto medido de la tarjeta: ancla la punta de bocadillo en vertical sin que se despegue
    /// cuando la tarjeta se acota cerca del borde superior/inferior de la ventana.
    @State private var cardHeight: CGFloat = 360

    func body(content: Content) -> some View {
        content
            .environment(\.linkPreviewPresenter, presenter)
            // Al scrollear o DESLIZAR (swipe de dos dedos), oculta la preview para que no tape las
            // acciones de swipe ni estorbe al desplazarte.
            .onReceive(NotificationCenter.default.publisher(for: .stacklumeUserScrolled)) { _ in
                presenter.hideCurrent()
            }
            .overlayPreferenceValue(PreviewAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    if let link = presenter.link, link.modelContext != nil, let anc = anchors[link.id] {
                        // `proxy[anc]` resuelve el marco de la fila en el espacio LOCAL de este overlay:
                        // exacto, sin el desfase del espacio con nombre.
                        let a = proxy[anc]
                        let cardW: CGFloat = 340, gap: CGFloat = 7
                        let arrowW: CGFloat = 9, arrowH: CGFloat = 18, coverH: CGFloat = 191
                        // La punta ocupa hueco entre el enlace y la tarjeta: cuéntala al decidir el lado.
                        let fitsRight = a.maxX + gap + arrowW + cardW <= proxy.size.width
                        let centerX = fitsRight ? a.maxX + gap + arrowW + cardW / 2
                                                : a.minX - gap - arrowW - cardW / 2
                        // Desplaza la tarjeta hacia ARRIBA ~media portada, para que su CUERPO (no la
                        // portada) quede a la altura de la fila: así la cola sale del cuerpo —mismo
                        // `palette.surface`, integrada— y apunta al enlace. Acotada a la ventana.
                        let half = cardHeight / 2
                        let centerY = min(max(a.midY - coverH / 2, half + 8),
                                          max(half + 8, proxy.size.height - half - 8))
                        // Borde de la tarjeta que mira al enlace; la punta solapa 1,5 pt ese borde.
                        let nearEdgeX = fitsRight ? centerX - cardW / 2 : centerX + cardW / 2
                        let arrowX = fitsRight ? nearEdgeX + 1.5 - arrowW / 2 : nearEdgeX - 1.5 + arrowW / 2
                        // La cola apunta SIEMPRE al centro de la fila, acotada al recuadro completo.
                        // Casi siempre sale del CUERPO (gracias al desplazamiento de arriba) → color
                        // `surface`, integrada. Solo en la 1.ª fila, con la tarjeta pegada al borde
                        // superior, la cola cae a la altura de la PORTADA: ahí se colorea CLARA para
                        // integrarse con ella (en vez de un pico oscuro sobre la portada clara).
                        let coverEdge = centerY - half + coverH
                        let arrowY = min(max(a.midY, centerY - half + arrowH), centerY + half - arrowH)
                        let onCover = arrowY < coverEdge
                        ZStack(alignment: .topLeading) {
                            LinkPreviewCard(link: link)
                                .fixedSize()
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.30), radius: 20, y: 8)
                                .position(x: centerX, y: centerY)
                            // Cola del bocadillo INTEGRADA: mismo `palette.surface` que el cuerpo de la
                            // tarjeta + borde sutil en los dos lados y sombra, para que se lea como una
                            // extensión de la tarjeta y no como un elemento aparte.
                            ZStack {
                                CalloutArrow(pointsLeft: fitsRight)
                                    .fill(onCover ? Color.white.opacity(0.92) : palette.surface)
                                CalloutArrow(pointsLeft: fitsRight, closed: false)
                                    .stroke(onCover ? .black.opacity(0.12) : .white.opacity(0.12), lineWidth: 0.75)
                            }
                            .frame(width: arrowW, height: arrowH)
                            .shadow(color: .black.opacity(0.30), radius: 8, x: fitsRight ? -3 : 3, y: 1)
                            .position(x: arrowX, y: arrowY)
                        }
                        .transition(.opacity)
                    }
                }
                .allowsHitTesting(false)   // toda la capa es PASANTE: nunca consume un clic
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: presenter.link?.id)
            }
    }
}

extension View {
    /// Vista previa al pasar el ratón sobre este objeto. `enabled: false` la desactiva (lista
    /// perezosa, tarjetas arrastrables). Se omite automáticamente en los enlaces seleccionados.
    func linkHoverPreview(_ link: Bookmark, edge: Edge = .trailing, enabled: Bool = true) -> some View {
        modifier(LinkHoverPreviewModifier(link: link, edge: edge, enabled: enabled))
    }

    /// Capa del preview a nivel de ventana (sin popover): no captura ni consume clics. Aplícala
    /// UNA vez en la ventana raíz, por encima de las vistas que usan `linkHoverPreview`.
    func linkPreviewLayer() -> some View { modifier(LinkPreviewLayerModifier()) }
}
