import SwiftUI
import SwiftData
import StacklumeCore
import StacklumeDesignSystem

/// Tarjeta visual de un enlace con portada (imagen OG → favicon → degradado de
/// marca), para la vista Cuadrícula. La estrella del rediseño: portada 16:9
/// PROTAGONISTA, badge de tipo en cristal sobre la imagen, acciones rápidas de
/// cristal al hacer hover y, debajo, un bloque de metadatos RICO (título 2 líneas,
/// extracto de descripción, fila favicon+host+fecha relativa y chips de etiqueta)
/// que justifica el modo «visual» frente a la densidad de la Lista. Una elevación
/// y sombra sutil la levantan de la retícula para leerse distinta de un vistazo.
struct LinkCoverCard: View {
    let link: Bookmark
    @Environment(\.themePalette) private var palette
    @Environment(\.modelContext) private var context
    @Environment(LibraryActions.self) private var actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    /// Portadas personalizadas: tienen prioridad sobre la `imageURL` autodetectada.
    @State private var coverStore = CustomCoverStore.shared

    private var host: String {
        URL(string: link.url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? link.url
    }
    private var brand: Color { Color(hex: link.platformColor ?? link.platform.brandColorHex) }

    /// Fecha de guardado en formato relativo y abreviado («hace 3 d», «ayer»…),
    /// localizada. Pista temporal que la Lista no muestra: refuerza la jerarquía.
    private var relativeDate: String {
        link.createdAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    var body: some View {
        // Guarda anti-crash (paridad iPhone): si el enlace ya fue borrado su
        // `modelContext` es nil y SwiftData invalida el @Model; pintar sus
        // propiedades dispararía un fatalError en el repintado tras el borrado.
        if link.modelContext == nil {
            EmptyView()
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            cardBody
        }
        // La PORTADA usa aspecto 16:9 (sigue el ancho de la columna) y el cuerpo tiene
        // altura fija (128): así la tarjeta entera escala con el ancho de columna que fija
        // el «amplificador», y todas las de una misma rejilla (igual ancho) quedan
        // idénticas y alineadas, sin solaparse.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isHovering ? palette.accent.opacity(0.45) : palette.border.opacity(0.5),
                              lineWidth: isHovering ? 1 : 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Elevación premium al pasar el ratón: escala sutil + sombra (Reduce Motion: solo
        // sombra, sin escala). El `zIndex` la pone por encima de las vecinas al elevarse.
        .scaleEffect(isHovering && !reduceMotion ? 1.02 : 1)
        .shadow(color: .black.opacity(isHovering ? 0.28 : 0), radius: isHovering ? 14 : 0, y: isHovering ? 7 : 0)
        .zIndex(isHovering ? 1 : 0)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isHovering)
        // Arrastrable: a una colección del sidebar (mover) o a Finder/otra app (URL).
        .draggable(BookmarkTransfer(from: link))
    }

    /// Portada 16:9 (15:9 en destacada) con skeleton mientras carga; si no hay
    /// imagen, degradado de marca con el icono de la plataforma. Encima: badge de
    /// tipo (siempre) y barra de acciones rápidas en cristal (solo al hacer hover).
    private var cover: some View {
        // Caja de tamaño FIJO (ancho de celda × 156) definida por el Rectangle; la
        // imagen va de OVERLAY y se conforma a la caja, así NUNCA puede ensanchar la
        // tarjeta. CAUSA RAÍZ del solapamiento: `RemoteImage` usa `scaledToFill()`, que
        // a una imagen 2:1 (p.ej. la portada de Swift) le daba un ancho MAYOR que la
        // celda → la tarjeta se ensanchaba y se derramaba sobre la vecina. Con la imagen
        // como overlay recortado de una caja fija, eso es imposible.
        Rectangle()
            .fill(palette.surface)
            .frame(maxWidth: .infinity)
            // Portada a 16:9: su alto sigue al ancho de columna → escala con el «amplificador».
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if let custom = coverStore.image(for: link.id) {
                    // Portada personalizada (prioridad): llena el banner a sangre, nítida.
                    Image(platformImage: custom).resizable().interpolation(.high).scaledToFill()
                } else {
                    // La portada LLENA el banner 16:9 a sangre con alta interpolación
                    // (nítida). El tratamiento pixel-aware se reserva al héroe del detalle.
                    // Sin og:image: NO se estira el favicon a sangre (quedaba borroso) —
                    // se muestra el LOGO del sitio CENTRADO sobre el degradado de marca,
                    // como Raindrop con los enlaces sin imagen.
                    SecureRemoteImage(candidates: HDImage.candidates(link.imageURL),
                                skeleton: { SkeletonView() }) {
                        ZStack {
                            palette.surface
                            RadialGradient(colors: [brand.opacity(0.20), .clear],
                                           center: .top, startRadius: 0, endRadius: 180)
                            SecureRemoteImage(candidates: [link.faviconURL] + PreviewImage.favicon(for: link.url, size: 256).map { Optional($0) }) {
                                Image(systemName: link.platform.sfSymbol)
                                    .scaledFont(32, weight: .regular, scalesWithText: false)
                                    .foregroundStyle(brand.opacity(0.55))
                            }
                            .frame(width: 60, height: 60)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        }
                    }
                }
            }
            .clipped()
        // Hairline inferior: separa limpiamente la portada del cuerpo (clave con
        // portadas CLARAS —p.ej. la de Swift—, que si no «sangran» sobre el navy).
        // El badge de tipo ya NO va flotando sobre la imagen (chocaba con su
        // contenido y se cortaba): vive ahora, alineado, en la fila de metadatos.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.border.opacity(0.6))
                .frame(height: 1)
        }
        .overlay(alignment: .topTrailing) {
            if isHovering { quickActions }
        }
    }

    /// Barra de acciones rápidas (favorito / editar / papelera) en una píldora de
    /// cristal, visible al pasar el ratón sobre la portada.
    private var quickActions: some View {
        HStack(spacing: 2) {
            quickButton(systemName: link.isFavorite ? "star.fill" : "star",
                        tint: link.isFavorite ? palette.accent : .white,
                        help: link.isFavorite ? "Quitar de favoritos" : "Favorito",
                        symbolValue: link.isFavorite) {
                BookmarkActions.toggleFavorite(link, in: context)
            }
            quickButton(systemName: "pencil", tint: .white, help: "Editar") {
                actions.edit(link)
            }
            quickButton(systemName: "trash", tint: .white, help: "Mover a la papelera") {
                BookmarkActions.moveToTrash(link, in: context)
            }
        }
        .padding(3)
        .glassEffect(.regular.tint(.black.opacity(0.25)), in: .capsule)
        .padding(DesignSystem.Spacing.xs)
        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
    }

    private func quickButton(systemName: String, tint: Color, help: String,
                             symbolValue: Bool? = nil,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .scaledFont(11, weight: .semibold, scalesWithText: false)
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                // Rebote del símbolo al marcar/desmarcar favorito (multiplataforma).
                // Respeta «Reducir movimiento»: si está activo, no rebota.
                .symbolEffect(.bounce, value: reduceMotion ? false : (symbolValue ?? false))
        }
        .buttonStyle(.pressable)
        .themedHelp(help)
        .accessibilityLabel(help)   // VoiceOver: el botón es solo-icono, sin `help` leería el símbolo
    }

    /// Cuerpo enriquecido (la diferencia con la fila de Lista): título a 2 líneas,
    /// extracto de descripción (2 líneas, o 3 en destacada), fila favicon + host +
    /// fecha relativa, y debajo los chips de etiqueta. Más generoso y aireado.
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(link.title.isEmpty ? host : link.title)
                .stacklumeFont(.headline.weight(.semibold))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(2, reservesSpace: true)   // siempre 2 líneas → altura uniforme
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            metaRow

            if !link.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(link.tags.prefix(2)) { TagChip(tag: $0) }
                }
                // Recorta las etiquetas al ancho de la tarjeta: una fila larga NO debe
                // ensanchar la tarjeta ni derramarse sobre la vecina.
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Cuerpo de metadatos de altura FIJA: el `Spacer` empuja la metafila al fondo y
        // todas las tarjetas (igual ancho) quedan idénticas, independientemente del
        // tamaño de portada que fije el «amplificador».
        .frame(height: 104, alignment: .top)
        .padding(DesignSystem.Spacing.sm)
    }

    /// Fila de metadatos: favicon + host a la izquierda; estrella (si favorito) y
    /// fecha relativa de guardado a la derecha. La fecha es un dato propio de este
    /// modo que la Lista no expone.
    private var metaRow: some View {
        HStack(spacing: 6) {
            PlatformBadge(platform: link.platform, size: 16)
                .accessibilityHidden(true)  // Decorativo: el host ya identifica el sitio
            Text(host)
                .stacklumeFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .stacklumeLineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: link.contentType.sfSymbol)
                .font(.caption2)
                .foregroundStyle(palette.textSecondary)
                .themedHelp(link.contentType.displayName)
                .accessibilityLabel(link.contentType.displayName)
            if link.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .readableTint(palette.accent, palette: palette, on: [palette.surface], minimumContrast: 3)
                    .accessibilityLabel("Favorito")
            }
            Text(relativeDate)
                .stacklumeFont(.caption2)
                .monospacedDigit()
                .foregroundStyle(palette.textSecondary)
                .stacklumeLineLimit(1)
                .layoutPriority(-1)
        }
    }
}
