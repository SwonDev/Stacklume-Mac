import SwiftUI
import AppKit
import SwiftData
import StacklumeCore
import StacklumeDesignSystem

/// Anotaciones de DIBUJO sobre la página (paridad Raindrop): captura la página renderizada
/// (o usa la portada actual) y permite dibujar encima con lápiz/colores usando ratón o
/// trackpad (lienzo propio en SwiftUI, ya que `PKCanvasView` de PencilKit es iOS-only). Al
/// guardar, compone los trazos sobre la imagen y la fija como portada (se ve en la ficha y
/// la cuadrícula, y persiste). 100 % local: reutiliza `PageSnapshotService` y `CustomCoverStore`.
struct PageAnnotationView: View {
    let link: Bookmark
    /// Se llama tras guardar para que la ficha refresque héroe/cuadrícula/widget.
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.themePalette) private var palette

    @State private var strokes: [InkStroke] = []
    @State private var colorHex = "#FF3B30"
    @State private var width: CGFloat = 4
    @State private var baseImage: NSImage?
    @State private var loading = true

    private let boxW: CGFloat = 880
    private let presetColors = ["#FF3B30", "#FFCC00", "#34C759", "#0A84FF", "#AF52DE", "#000000", "#FFFFFF"]
    private var aspect: CGFloat {
        guard let s = baseImage?.size, s.height > 0 else { return 1280.0 / 832.0 }
        return s.width / s.height
    }
    private var boxH: CGFloat { min(560, max(320, boxW / max(0.5, aspect))) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Anotar la página").stacklumeFont(.headline)
                Spacer()
                Text(URL(string: link.url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? "")
                    .stacklumeFont(.caption).foregroundStyle(palette.textSecondary)
            }
            .padding(DesignSystem.Spacing.md)

            toolbar
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.bottom, DesignSystem.Spacing.xs)

            ZStack {
                if let img = baseImage {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    Color.white
                }
                DrawingCanvas(strokes: $strokes, colorHex: colorHex, width: width)
            }
            .frame(width: boxW, height: boxH)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(palette.border.opacity(0.5), lineWidth: 0.5)
            )
            .overlay { if loading { ProgressView("Capturando la página…") } }
            .padding(.horizontal, DesignSystem.Spacing.md)

            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Guardar") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                    .disabled(loading || strokes.isEmpty)
            }
            .padding(DesignSystem.Spacing.md)
        }
        .frame(width: boxW + DesignSystem.Spacing.md * 2)
        .task { await loadBase() }
    }

    private var toolbar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            ForEach(presetColors, id: \.self) { hex in
                Button { colorHex = hex } label: {
                    Circle().fill(Color(hex: hex))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(colorHex == hex ? palette.accent : palette.border.opacity(0.6),
                                                       lineWidth: colorHex == hex ? 2.5 : 1))
                }
                .buttonStyle(.plain)
                .themedHelp("Color")
            }
            Divider().frame(height: 18)
            Picker("Grosor", selection: $width) {
                Text("Fino").tag(CGFloat(2))
                Text("Medio").tag(CGFloat(4))
                Text("Grueso").tag(CGFloat(8))
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 190)
            Spacer()
            Button("Deshacer", systemImage: "arrow.uturn.backward") {
                if !strokes.isEmpty { strokes.removeLast() }
            }
            .disabled(strokes.isEmpty)
            Button("Borrar todo", systemImage: "trash") { strokes.removeAll() }
                .disabled(strokes.isEmpty)
        }
    }

    /// Carga la imagen base a anotar: portada personalizada actual → captura de la página →
    /// imagen autodetectada → (en último caso) fondo blanco.
    private func loadBase() async {
        if let custom = CustomCoverStore.shared.image(for: link.id) {
            baseImage = custom; loading = false; return
        }
        if let shot = await PageSnapshotService.snapshot(of: link.url) {
            baseImage = shot; loading = false; return
        }
        if let urlStr = link.imageURL, let u = URL(string: urlStr),
           let img = await SecureImageCache.shared.image(for: u) {
            baseImage = img
        }
        loading = false
    }

    /// Compone los trazos sobre la imagen base y lo fija como portada (anotada).
    private func save() {
        let size = CGSize(width: boxW, height: boxH)
        let rect = CGRect(origin: .zero, size: size)
        let result = NSImage(size: size)
        result.lockFocus()
        if let base = baseImage {
            base.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        } else {
            NSColor.white.setFill(); rect.fill()
        }
        // El contexto de `NSImage` tiene origen abajo-izq; el lienzo SwiftUI, arriba-izq →
        // se invierte la Y de cada punto para que los trazos caigan donde se dibujaron.
        for stroke in strokes where stroke.points.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = stroke.width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let flipped = stroke.points.map { CGPoint(x: $0.x, y: size.height - $0.y) }
            path.move(to: flipped[0])
            for point in flipped.dropFirst() { path.line(to: point) }
            NSColor(Color(hex: stroke.colorHex)).setStroke()
            path.stroke()
        }
        result.unlockFocus()

        if CustomCoverStore.shared.set(result, for: link.id) {
            link.updatedAt = Date()
            context.saveLogging()
            onSaved()
        }
        dismiss()
    }
}
