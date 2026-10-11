import SwiftUI
import StacklumeCore
import StacklumeDesignSystem

/// Icono SF Symbol para cada tipo de contenido. Mapeo único reutilizado por las
/// distintas tarjetas (badge de cristal en la portada de la cuadrícula y pista
/// discreta en la fila de lista). `ContentType` no expone símbolo en el core, así
/// que centralizamos aquí la correspondencia para no duplicarla por toda la UI.
extension ContentType {
    var sfSymbol: String {
        switch self {
        case .video: "play.rectangle.fill"
        case .music: "music.note"
        case .game: "gamecontroller.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .article: "doc.text.fill"
        case .social: "bubble.left.and.bubble.right.fill"
        case .design: "paintpalette.fill"
        case .document: "doc.fill"
        case .commerce: "cart.fill"
        case .website: "globe"
        }
    }
}

/// Badge translúcido del tipo de contenido para superponer sobre la portada de la
/// tarjeta de cuadrícula. Icono + nombre en una píldora de cristal (Liquid Glass),
/// discreto pero legible sobre cualquier imagen.
struct ContentTypeBadge: View {
    let type: ContentType
    /// Si `false`, muestra solo el icono (más compacto). Por defecto icono + texto.
    var showsLabel: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: type.sfSymbol)
                .scaledFont(9, weight: .semibold, scalesWithText: false)
            if showsLabel {
                Text(type.displayName)
                    .stacklumeFont(.caption2.weight(.semibold))
                    .stacklumeLineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, showsLabel ? 7 : 5)
        .padding(.vertical, 4)
        .glassEffect(.regular.tint(.black.opacity(0.25)), in: .capsule)
    }
}
