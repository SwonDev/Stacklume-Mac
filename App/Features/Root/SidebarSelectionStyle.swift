import SwiftUI
import AppKit

/// Suprime el resaltado de selección NATIVO del outline view del sidebar.
///
/// En macOS, el resaltado de la fila seleccionada de un `List(selection:)` usa
/// SIEMPRE el `controlAccentColor` del sistema y NO respeta `.tint()` ni la paleta
/// del tema (confirmado: `.tint` en macOS solo tiñe los iconos del `Label`). Para
/// que la selección siga al tema, apagamos el resaltado nativo
/// (`selectionHighlightStyle = .none`) y dibujamos uno propio con `palette.accent`
/// vía `.listRowBackground`.
///
/// Se monta como fondo de una fila del sidebar: su `NSView` vive DENTRO de la
/// `NSTableView` del sidebar, así que la localizamos subiendo por la jerarquía. De
/// este modo solo afecta a ESA tabla (no a otras listas de la app). Degrada con
/// elegancia: si no encuentra la tabla, el resaltado nativo simplemente permanece.
struct SidebarSelectionSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Diferimos un ciclo: en el primer `updateNSView` la vista puede no estar aún
        // insertada en la jerarquía de la tabla.
        DispatchQueue.main.async {
            var view: NSView? = nsView.superview
            while let current = view {
                if let table = current as? NSTableView {
                    if table.selectionHighlightStyle != .none {
                        table.selectionHighlightStyle = .none
                    }
                    return
                }
                view = current.superview
            }
        }
    }
}

/// Pastilla de selección teñida con el ACENTO DEL TEMA, reutilizable como
/// `.listRowBackground` en cualquier `List` que haya suprimido el resaltado nativo.
/// Sutil y «separada» del borde; transparente cuando la fila no está seleccionada.
struct ThemedSelectionBackground: View {
    let isSelected: Bool
    let accent: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isSelected ? accent.opacity(0.18) : Color.clear)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(accent.opacity(0.30), lineWidth: 1)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
    }
}

extension View {
    /// Monta el supresor del resaltado nativo como fondo invisible. Se aplica a una
    /// fila (o a una fila oculta) de la `List` para que su `NSView` viva dentro de la
    /// tabla y solo afecte a ESA lista.
    func suppressNativeListSelectionHighlight() -> some View {
        background(SidebarSelectionSuppressor().frame(width: 0, height: 0))
    }
}
