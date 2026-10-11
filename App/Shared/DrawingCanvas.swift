import SwiftUI
import StacklumeDesignSystem

/// Un trazo de tinta: lista de puntos (en coordenadas del lienzo, origen arriba-izq como
/// SwiftUI), color (hex) y grosor. Sirve para dibujar en pantalla y para recomponer la
/// imagen anotada al guardar.
struct InkStroke: Identifiable {
    let id = UUID()
    var points: [CGPoint]
    var colorHex: String
    var width: CGFloat
}

/// Lienzo de dibujo a mano alzada en SwiftUI puro (PencilKit `PKCanvasView` no existe en
/// macOS). Captura trazos con `DragGesture` —ratón o trackpad— y los pinta con `Canvas`.
/// El contenedor posee los `strokes` (para deshacer/borrar y recomponer al guardar).
struct DrawingCanvas: View {
    @Binding var strokes: [InkStroke]
    let colorHex: String
    let width: CGFloat
    @State private var current: InkStroke?

    var body: some View {
        Canvas { ctx, _ in
            for stroke in strokes { paint(stroke, in: &ctx) }
            if let current { paint(current, in: &ctx) }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if current == nil {
                        current = InkStroke(points: [value.location], colorHex: colorHex, width: width)
                    } else {
                        current?.points.append(value.location)
                    }
                }
                .onEnded { _ in
                    if let current, current.points.count > 1 { strokes.append(current) }
                    else if let current { strokes.append(InkStroke(points: current.points + [CGPoint(x: current.points[0].x + 0.1, y: current.points[0].y)], colorHex: colorHex, width: width)) }
                    current = nil
                }
        )
    }

    private func paint(_ stroke: InkStroke, in ctx: inout GraphicsContext) {
        guard let first = stroke.points.first else { return }
        var path = Path()
        path.move(to: first)
        for point in stroke.points.dropFirst() { path.addLine(to: point) }
        ctx.stroke(path, with: .color(Color(hex: stroke.colorHex)),
                   style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round))
    }
}
