import AppKit
import ObjectiveC

/// Barra de desplazamiento de marca, SIEMPRE visible (estilo «legacy», no el
/// overlay transitorio del sistema). El pulgar (knob) se pinta con el ACENTO DEL
/// TEMA ACTIVO, no con un dorado fijo: así la scrollbar sigue al tema elegido
/// (océano → cian, carmesí → rojo, etc.). El acento vive en `GoldenScroller.knobColor`,
/// que `RootWindowView` actualiza vía `ScrollerTint.setAccent(_:)` cuando cambia el tema.
final class GoldenScroller: NSScroller {
    /// Acento actual del pulgar. Por defecto, el dorado de marca (tema Oscuro). Se
    /// actualiza desde la UI al cambiar de tema.
    ///
    /// `nonisolated(unsafe)` justificado: solo se LEE en `drawKnob/drawKnobSlot`
    /// (dibujado de AppKit, siempre en el hilo principal) y solo se ESCRIBE desde
    /// `ScrollerTint.setAccent(_:)`, invocado desde SwiftUI también en el hilo
    /// principal. No hay acceso concurrente real.
    nonisolated(unsafe) static var knobColor: NSColor =
        NSColor(srgbRed: 0.839, green: 0.651, blue: 0.180, alpha: 1.0)

    /// Fuerza que estos scrollers NO sean overlay (siempre visibles).
    override class var isCompatibleWithOverlayScrollers: Bool { false }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.width > 1, knob.height > 1 else { return }
        let inset = knob.insetBy(dx: 2.5, dy: 2.5)
        let radius = min(inset.width, inset.height) / 2
        GoldenScroller.knobColor.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // Pista (canal) muy sutil, teñida con el mismo acento para que la barra se
        // asiente sobre el fondo del tema sin cantar.
        GoldenScroller.knobColor.withAlphaComponent(0.06).setFill()
        let inset = slotRect.insetBy(dx: 4, dy: 1)
        let radius = min(inset.width, inset.height) / 2
        NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius).fill()
    }
}

/// Aplica los scrollers de marca a TODOS los `NSScrollView` de la app interceptando
/// su `tile()` (que se llama al disponer la vista) para forzar estilo legacy +
/// `GoldenScroller`. Se activa una vez al arrancar (`StacklumeApp.init`).
enum ScrollerTint {
    static func apply() {
        guard
            let original = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.tile)),
            let replacement = class_getInstanceMethod(NSScrollView.self, #selector(NSScrollView.stacklumeTileWithGoldenScrollers))
        else { return }
        method_exchangeImplementations(original, replacement)
    }

    /// Actualiza el acento del pulgar y repinta los scrollers visibles. La llama la
    /// ventana principal al arrancar y cada vez que cambia el tema activo, para que
    /// la scrollbar refleje al instante el color del tema.
    @MainActor
    static func setAccent(_ color: NSColor) {
        GoldenScroller.knobColor = color
        refreshVisibleScrollers()
    }

    /// Marca para repintado todos los `GoldenScroller` visibles de todas las ventanas.
    @MainActor
    private static func refreshVisibleScrollers() {
        for window in NSApp.windows {
            guard let root = window.contentView else { continue }
            markScrollers(in: root)
        }
    }

    /// Recorre el árbol de vistas marcando `needsDisplay` en los scrollers de marca.
    @MainActor
    private static func markScrollers(in view: NSView) {
        if let scroll = view as? NSScrollView {
            (scroll.verticalScroller as? GoldenScroller)?.needsDisplay = true
            (scroll.horizontalScroller as? GoldenScroller)?.needsDisplay = true
        }
        for sub in view.subviews { markScrollers(in: sub) }
    }
}

extension NSScrollView {
    @objc func stacklumeTileWithGoldenScrollers() {
        if scrollerStyle != .legacy { scrollerStyle = .legacy }
        if hasVerticalScroller, !(verticalScroller is GoldenScroller) {
            let s = GoldenScroller()
            s.scrollerStyle = .legacy
            verticalScroller = s
        }
        if hasHorizontalScroller, !(horizontalScroller is GoldenScroller) {
            let s = GoldenScroller()
            s.scrollerStyle = .legacy
            horizontalScroller = s
        }
        // Llama a la implementación original (intercambiada).
        stacklumeTileWithGoldenScrollers()
    }
}
