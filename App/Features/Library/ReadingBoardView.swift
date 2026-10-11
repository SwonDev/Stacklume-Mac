import SwiftUI
import SwiftData
import StacklumeCore
import StacklumePersistence
import StacklumeDesignSystem

/// La «Cola de lectura» con DOS vistas intercambiables: la LISTA de siempre y un TABLERO
/// Kanban por estado de lectura (Pendiente · Leyendo · Leído). Un segmentado arriba alterna
/// entre ambas y la elección se recuerda. El tablero permite ARRASTRAR tarjetas entre
/// columnas para cambiar su estado —el gesto natural para organizar qué leer—, algo que
/// Raindrop no ofrece.
struct ReadingQueueView: View {
    @Binding var selectedLinks: Set<Bookmark.ID>
    @AppStorage("stacklume.readingQueue.board") private var showBoard = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Vista de la cola de lectura", selection: $showBoard) {
                Label("Lista", systemImage: "list.bullet").tag(false)
                Label("Tablero", systemImage: "rectangle.split.3x1").tag(true)
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .fixedSize()
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.top, DesignSystem.Spacing.sm)
            .padding(.bottom, DesignSystem.Spacing.xs)
            .accessibilityLabel(showBoard ? "Vista de tablero" : "Vista de lista")

            if showBoard {
                ReadingBoardView(selectedLinks: $selectedLinks)
            } else {
                LibraryListView(
                    title: "Cola de lectura", icon: "clock",
                    emptyMessage: "Tu cola de lectura está vacía. Guarda enlaces para leerlos con calma más tarde.",
                    baseFilter: LinkFilter(),
                    readingQueueMode: true,
                    viewScope: NavTarget.readingQueue.key,
                    selection: $selectedLinks)
            }
        }
    }
}

/// Tablero Kanban: una columna por `ReadingStatus`, con sus enlaces como tarjetas
/// (`LinkRowView`, reutilizada de la Lista). Arrastrar una tarjeta a otra columna cambia su
/// `readingStatus`; tocarla la abre en el detalle. Las columnas se reparten el ancho y, si
/// no caben, el tablero hace scroll horizontal (estilo Trello).
struct ReadingBoardView: View {
    @Binding var selectedLinks: Set<Bookmark.ID>
    @Environment(\.modelContext) private var context
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Enlaces activos (no borrados ni archivados); se reparten por columnas según su estado.
    @Query(filter: #Predicate<Bookmark> { $0.deletedAt == nil && !$0.isArchived },
           sort: \Bookmark.updatedAt, order: .reverse)
    private var links: [Bookmark]

    /// Columna resaltada como destino de un arrastre en curso (realimentación visual).
    @State private var dropTarget: ReadingStatus?

    private var grouped: [ReadingStatus: [Bookmark]] {
        Dictionary(grouping: links) { $0.readingStatus }
    }

    var body: some View {
        GeometryReader { geo in
            let spacing = DesignSystem.Spacing.md
            let outerPadding = DesignSystem.Spacing.lg
            let available = geo.size.width - outerPadding * 2 - spacing * CGFloat(ReadingStatus.allCases.count - 1)
            // Reparte el ancho entre las 3 columnas; nunca por debajo de un mínimo legible.
            let columnWidth = max(248, available / CGFloat(ReadingStatus.allCases.count))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(ReadingStatus.allCases) { status in
                        // Altura DEFINIDA (la del visor): así la columna —y su zona de drop— llena
                        // todo el alto aunque tenga pocas tarjetas, y el `ScrollView` interno
                        // desplaza dentro de ese marco en vez de estirarse sin límite.
                        column(for: status, items: grouped[status] ?? [])
                            .frame(width: columnWidth,
                                   height: max(0, geo.size.height - outerPadding * 2))
                    }
                }
                .padding(outerPadding)
                .frame(minWidth: geo.size.width, alignment: .leading)
            }
        }
    }

    // MARK: - Columna

    @ViewBuilder
    private func column(for status: ReadingStatus, items: [Bookmark]) -> some View {
        let isTargeted = dropTarget == status
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: status.sfSymbol)
                    .readableTint(color(for: status), palette: palette, on: [palette.background, palette.surface],
                                  minimumContrast: 3)
                Text(status.displayName)
                    .stacklumeFont(.headline)
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 0)
                Text("\(items.count)")
                    .stacklumeFont(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(palette.surface))
            }
            .padding(DesignSystem.Spacing.sm)

            Divider().opacity(0.4)

            ScrollView {
                LazyVStack(spacing: DesignSystem.Spacing.sm) {
                    if items.isEmpty {
                        emptyColumn
                    } else {
                        ForEach(items) { card($0) }
                    }
                }
                .padding(DesignSystem.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.surface.opacity(isTargeted ? 0.9 : 0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isTargeted ? (palette.readableForeground(color(for: status),
                                                                      on: [palette.background, palette.surface],
                                                                      minimumContrast: 3) ?? palette.textPrimary) : .white.opacity(0.06),
                              lineWidth: isTargeted ? 1.5 : 0.5)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isTargeted)
        // TODA la columna (también el hueco vacío bajo las tarjetas) es zona de soltar: sin un
        // `contentShape` sólido, el `ScrollView` interno se «comía» el drop y la tarjeta no
        // cambiaba de columna. Es la diferencia con el sidebar, cuyo `List` ya da un drop fiable.
        .contentShape(Rectangle())
        // Soltar una tarjeta aquí mueve su enlace a este estado (lee la etiqueta «bm:UUID»
        // que expone `BookmarkTransfer`, el mismo mecanismo que el sidebar).
        .dropDestination(for: String.self) { payloads, _ in
            var moved = false
            for payload in payloads {
                guard let id = BookmarkTransfer.bookmarkID(from: payload),
                      let link = links.first(where: { $0.id == id }) else { continue }
                BookmarkActions.setReadingStatus(status, for: link, in: context)
                moved = true
            }
            return moved
        } isTargeted: { targeted in
            dropTarget = targeted ? status : (dropTarget == status ? nil : dropTarget)
        }
    }

    // MARK: - Tarjeta

    @ViewBuilder
    private func card(_ link: Bookmark) -> some View {
        let isSelected = selectedLinks.count == 1 && selectedLinks.contains(link.id)
        // Sin preview emergente en el tablero: aquí la acción principal es ARRASTRAR, y el
        // popover de hover rompía el inicio del arrastre y entrecortaba el clic.
        LinkRowView(link: link, showHoverPreview: false)
            .padding(.horizontal, DesignSystem.Spacing.xs)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? (palette.readableForeground(palette.accent,
                                                                          on: [palette.background, palette.surface],
                                                                          minimumContrast: 3) ?? palette.textPrimary) : .white.opacity(0.06),
                                  lineWidth: isSelected ? 1.5 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture { selectedLinks = [link.id] }
            // `.onDrag` (puente AppKit) en vez de `.draggable`: dentro del `ScrollView` del
            // tablero, `.draggable` no llegaba a iniciar la sesión de arrastre (lo bloqueaban
            // el `.onTapGesture` y el scroll). Entrega la etiqueta «bm:UUID» como texto, que
            // la columna lee en su `.dropDestination(for: String.self)`.
            .onDrag { NSItemProvider(object: BookmarkTransfer(from: link).tag as NSString) }
            .contextMenu {
                ForEach(ReadingStatus.allCases) { status in
                    Button {
                        BookmarkActions.setReadingStatus(status, for: link, in: context)
                    } label: {
                        Label("Mover a «\(status.displayName)»", systemImage: status.sfSymbol)
                    }
                    .disabled(link.readingStatus == status)
                }
                Divider()
                Button {
                    selectedLinks = [link.id]
                } label: {
                    Label("Ver detalle", systemImage: "sidebar.right")
                }
            }
    }

    private var emptyColumn: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "tray")
                .font(.title3)
                .foregroundStyle(palette.textSecondary.opacity(0.5))
            Text("Arrastra enlaces aquí")
                .stacklumeFont(.caption)
                .foregroundStyle(palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystem.Spacing.lg)
    }

    /// Color distintivo de cada estado para la cabecera y el resaltado de destino.
    private func color(for status: ReadingStatus) -> Color {
        switch status {
        case .inbox: palette.textSecondary
        case .reading: palette.accent
        case .done: .green
        }
    }
}
