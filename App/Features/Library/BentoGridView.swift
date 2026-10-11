import SwiftUI
import SwiftData
import AppKit
import StacklumeCore
import StacklumeDesignSystem

/// Vista Cuadrícula: retícula adaptativa de tarjetas `LinkCoverCard` cover-forward.
/// SwiftUI garantiza con `.adaptive(minimum:maximum:)` que las columnas SIEMPRE caben
/// dentro del contenedor (nunca desbordan ni se solapan). Sin animaciones de aparición
/// (la entrada escalonada dejaba tarjetas «huérfanas» flotando sobre la rejilla): el
/// grid es estático y limpio.
struct BentoGridView: View {
    let links: [Bookmark]
    /// Selección MÚLTIPLE: tap normal selecciona una (reemplaza); ⌘-clic alterna la
    /// pertenencia al conjunto (paridad con la selección nativa de la `List`).
    @Binding var selection: Set<Bookmark.ID>
    /// «Amplificador» de tamaño de portada (Raindrop): 1.0 = base. El ancho de tarjeta
    /// es FIJO (= 210 × coverScale) y se reparten las que quepan: así el deslizador
    /// SIEMPRE cambia el tamaño visible de las portadas, aunque el panel central sea
    /// estrecho y solo quepa una columna a tamaño grande. La portada (16:9) y el cuerpo
    /// escalan con ese ancho.
    var coverScale: Double = 1.0
    // Taxonomía del menú contextual: consultada UNA vez aquí y pasada a cada tarjeta (no un
    // @Query por tarjeta dentro de `LinkContextMenu`, que costaba al hacer scroll).
    @Query(filter: #Predicate<BookmarkCategory> { $0.deletedAt == nil }, sort: \BookmarkCategory.order)
    private var collections: [BookmarkCategory]
    @Query(filter: #Predicate<Tag> { $0.deletedAt == nil }, sort: \Tag.order)
    private var menuTags: [Tag]
    @Query(filter: #Predicate<Project> { $0.deletedAt == nil }, sort: \Project.order)
    private var menuProjects: [Project]

    var body: some View {
        GeometryReader { geo in
            let cols = Self.gridColumns(width: Double(geo.size.width), coverScale: coverScale,
                                        linkCount: links.count)
            ScrollView {
                LazyVGrid(columns: cols, spacing: DesignSystem.Spacing.lg) {
                    ForEach(links) { link in
                        LinkCoverCard(link: link)
                            .modifier(CardInteraction(link: link, selection: $selection,
                                                      collections: collections, tags: menuTags, projects: menuProjects))
                    }
                }
                .padding(DesignSystem.Spacing.lg)
                .modifier(ScrollObservationModifier(session: ScrollDiagnostics.observation, surface: .library))
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .background(WindowBackground())
        }
    }

    /// Columnas de la cuadrícula para un ancho dado. El «amplificador» fija un ancho de
    /// tarjeta objetivo (230 × coverScale): de ahí sale CUÁNTAS columnas caben. Se limita
    /// al nº de enlaces (sin columnas vacías) pero con un mínimo para no agrandar/emborronar
    /// portadas pequeñas (cota ~400 pt). Compartida con la cuadrícula AGRUPADA (Group by).
    static func gridColumns(width: Double, coverScale: Double, linkCount: Int) -> [GridItem] {
        let lg = Double(DesignSystem.Spacing.lg)
        let avail = max(120.0, width - lg * 2)
        let cardWidth = 230.0 * coverScale
        let fit = max(1, Int((avail + lg) / (cardWidth + lg)))
        let minToAvoidHuge = Int(ceil(avail / 400.0))
        let n = max(1, min(8, max(min(fit, max(1, linkCount)), minToAvoidHuge)))
        return Array(repeating: GridItem(.flexible(), spacing: DesignSystem.Spacing.lg), count: n)
    }
}

/// Interacción común de una tarjeta de la cuadrícula: selección al tocar (tap normal
/// reemplaza; ⌘-clic alterna pertenencia), distintivo de selección múltiple y menú
/// contextual (favorito / papelera). Internal para que la cuadrícula AGRUPADA la reutilice.
struct CardInteraction: ViewModifier {
    let link: Bookmark
    @Binding var selection: Set<Bookmark.ID>
    /// Taxonomía inyectada (consultada UNA vez por el contenedor) para no hacer un @Query por
    /// tarjeta dentro de `LinkContextMenu`.
    var collections: [BookmarkCategory] = []
    var tags: [Tag] = []
    var projects: [Project] = []
    @Environment(\.themePalette) private var palette

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) { selectionBadge }
            .contentShape(Rectangle())
            .onTapGesture { tapSelect() }
            // Mismo menú contextual rico que la Lista/Moodboard (abrir, copiar, editar,
            // favorito, archivar, estado de lectura, papelera).
            .contextMenu { LinkContextMenu(link: link, collections: collections, tags: tags, projects: projects) }
    }

    /// Distintivo (círculo dorado con check) cuando esta tarjeta forma parte de una
    /// multiselección (2+). No se muestra con una sola seleccionada (no estorba).
    @ViewBuilder
    private var selectionBadge: some View {
        if selection.count >= 2, selection.contains(link.id) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(palette.accent)
                .background(Circle().fill(palette.surface).padding(2))
                .padding(DesignSystem.Spacing.sm)
        }
    }

    /// ⌘-clic alterna; clic normal reemplaza por solo este enlace.
    private func tapSelect() {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(link.id) { selection.remove(link.id) } else { selection.insert(link.id) }
        } else {
            selection = [link.id]
        }
    }
}
