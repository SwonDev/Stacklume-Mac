import SwiftUI
import StacklumeCore
import StacklumeDesignSystem

/// Snapshot de VALORES de una fila: captura, UNA sola vez, todo lo que la fila necesita pintar.
/// Pintar desde aquí —en vez de acceder al `@Model Bookmark` en cada fotograma— evita el faulting
/// de SwiftData y el seguimiento de Observation (hash/comparación de `Set<AnyKeyPath>`) que un
/// `sample` del scroll señaló como el coste DOMINANTE de cada fotograma. Se construye al cambiar
/// el conjunto visible (en `RowItem`, una vez por enlace), NO por fotograma de scroll.
struct LinkRowData: Equatable {
    let id: UUID
    let updatedAt: Date
    let displayTitle: String
    let host: String
    let faviconURL: String?
    let platform: Platform
    let tagChips: [TagChipValue]
    let summary: String?
    let contentTypeSymbol: String
    let contentTypeName: String
    let isFavorite: Bool
    /// El usuario editó a mano el título o la descripción (marca visual sutil + protección).
    let userEdited: Bool

    @MainActor init(link: Bookmark) {
        id = link.id
        updatedAt = link.updatedAt
        userEdited = UserEditLedger.isEdited(link.id)
        let title = link.title
        let url = link.url
        displayTitle = title.isEmpty ? url : title
        if let h = URL(string: url)?.host() {
            host = h.replacingOccurrences(of: "www.", with: "")
        } else {
            host = url
        }
        faviconURL = link.faviconURL
        platform = link.platform
        tagChips = link.tags.prefix(2).map { TagChipValue(id: $0.id, name: $0.name, colorHex: $0.colorHex) }
        let s = link.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        summary = (s?.isEmpty == false) ? s : nil
        contentTypeSymbol = link.contentType.sfSymbol
        contentTypeName = link.contentType.displayName
        isFavorite = link.isFavorite
    }

    // Igualdad por id + última edición: cualquier cambio del enlace bumpea `updatedAt`, así que
    // basta con esos dos para saber si el snapshot cambió (todos los campos derivan del enlace).
    // Evita exigir `Equatable` a `Platform`/campos y es exactamente lo que comparaba el `==` previo.
    static func == (lhs: LinkRowData, rhs: LinkRowData) -> Bool {
        lhs.id == rhs.id && lhs.updatedAt == rhs.updatedAt
    }
}

/// Valor de un chip de etiqueta para el snapshot de la fila (id para el `ForEach`, nombre + color).
struct TagChipValue: Equatable, Identifiable {
    let id: UUID
    let name: String
    let colorHex: String
}

/// Fila premium de un enlace en la lista de la Biblioteca. Densa pero cómoda, con
/// favicon redondeado, título y una segunda línea de host + etiquetas, y a la
/// derecha el estado de favorito y una pista discreta del tipo de contenido.
struct LinkRowView: View, @MainActor Equatable {
    let link: Bookmark
    /// Snapshot de valores PRECOMPUTADO (lista perezosa). Si es `nil` (otros usos: Papelera,
    /// proyecto, cola…), se construye desde `link` al vuelo: esas listas son pequeñas y no es el
    /// camino caliente del scroll, donde sí se inyecta el snapshot ya hecho.
    var data: LinkRowData? = nil
    /// Vista previa al pasar el ratón. Se desactiva en contextos donde estorba (tarjetas
    /// arrastrables del tablero Kanban): el popover rompía el inicio del arrastre.
    var showHoverPreview: Bool = true
    @Environment(\.themePalette) private var palette
    @State private var isHovering = false

    /// `Equatable` para `.equatable()`: SwiftUI se SALTA el reproceso de la fila durante el
    /// scroll si nada relevante ha cambiado. Compara los SNAPSHOTS de VALOR (id · última edición),
    /// NO el `@Model`: antes, comparar `link.id`/`link.updatedAt` faulteaba SwiftData en CADA
    /// comparación del scroll (lo medía el `sample`). El `@State` interno (hover) y los hijos
    /// (favicon async) se actualizan por su cuenta, no a través de esta igualdad.
    @MainActor static func == (lhs: LinkRowView, rhs: LinkRowView) -> Bool {
        // Si el enlace fue borrado (`modelContext` nil), NO los consideres iguales: que se
        // re-renderice (mostrará EmptyView). Acceder a `modelContext` es barato (no es propiedad
        // persistida) y seguro (lo hace también `body`).
        guard lhs.link.modelContext != nil, rhs.link.modelContext != nil else { return false }
        let l = lhs.data ?? LinkRowData(link: lhs.link)
        let r = rhs.data ?? LinkRowData(link: rhs.link)
        return lhs.showHoverPreview == rhs.showHoverPreview && l == r
    }

    var body: some View {
        // Guarda anti-crash (paridad iPhone): si el enlace ya fue borrado su `modelContext` es nil
        // y SwiftData invalida el @Model; pintar sus propiedades dispararía un fatalError. Con el
        // snapshot, `content` ya no toca propiedades persistidas, pero mantenemos la guarda.
        if link.modelContext == nil {
            EmptyView()
        } else {
            content
        }
    }

    private var content: some View {
        // Snapshot: precomputado (lista perezosa) o construido aquí UNA vez por render (otros usos).
        let d = data ?? LinkRowData(link: link)
        return HStack(spacing: DesignSystem.Spacing.sm) {
            // Cascada de favicon (como la cuadrícula/detalle): no depende de un único candidato
            // que a veces falta o da 404 → así no aparece el globo. Si NADA carga, cae a un
            // mosaico con la inicial del dominio (no al globo genérico).
            SecureRemoteImage(candidates: [d.faviconURL] + PreviewImage.favicon(for: "https://\(d.host)").map { Optional($0) }) {
                if d.platform == .generic {
                    MonogramTile(text: d.host, size: 38)
                } else {
                    PlatformBadge(platform: d.platform, size: 38)
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            )
            .accessibilityHidden(true)  // Decorativo: VoiceOver ya lee el título del enlace

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(d.displayTitle)
                        .stacklumeFont(.body.weight(.semibold))
                        .foregroundStyle(palette.textPrimary)
                        .stacklumeLineLimit(1)
                    // Marca MUY sutil (sin texto): un punto con el color de acento indica que el
                    // título/descripción los editaste tú y el enriquecido no los toca.
                    if d.userEdited {
                        Circle()
                            .fill(palette.accent.opacity(0.9))
                            .frame(width: 5, height: 5)
                            .themedHelp("Editado por ti")
                            .accessibilityLabel("Editado por ti")
                    }
                }
                HStack(spacing: 6) {
                    Text(d.host)
                        .stacklumeFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .stacklumeLineLimit(1)
                    ForEach(d.tagChips) { TagChip(name: $0.name, colorHex: $0.colorHex) }
                }
                // TL;DR generado por la IA (campo `summary`): escanea la idea sin abrirlo.
                if let summary = d.summary {
                    Text(summary)
                        .stacklumeFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .stacklumeLineLimit(1)
                }
            }

            Spacer(minLength: DesignSystem.Spacing.xs)

            // Pista discreta del tipo de contenido (solo icono, sin cristal: no es
            // un control, basta el símbolo en color secundario para escanear).
            Image(systemName: d.contentTypeSymbol)
                .font(.caption)
                .foregroundStyle(palette.textSecondary)
                .themedHelp(d.contentTypeName)
                .accessibilityLabel(d.contentTypeName)

            if d.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .readableTint(palette.accent, palette: palette,
                                  on: [palette.background, palette.surface, palette.popover], minimumContrast: 3)
                    .accessibilityLabel("Favorito")
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, DesignSystem.Spacing.xs)
        .contentShape(Rectangle())
        // SIN `.onHover` de resaltado: dispararse en CADA fila al pasar el cursor durante el
        // scroll (cambio de estado + render por fila por fotograma) era un cuello de botella
        // medido. El resaltado de selección lo da el fondo de la fila; la selección activa basta.
        // Vista previa rica al pasar el ratón (portada + descripción + etiquetas), tras un
        // breve retardo. Anclada al borde derecho, junto a la fila densa de la Lista.
        .linkHoverPreview(link, enabled: showHoverPreview)
        // El arrastre de la fila (a colección/Finder, o el reordenado en modo manual) lo
        // decide la `List` según el orden activo (ver `LibraryListView.listView`).
    }
}
