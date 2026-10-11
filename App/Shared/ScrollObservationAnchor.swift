import SwiftUI
import AppKit

/// Sólo dentro del documento; un background exterior de List no se presume válido.
struct ScrollObservationAnchor: NSViewRepresentable {
    let session: NativeScrollObservation
    let surface: ScrollSurface
    func makeNSView(context: Context) -> ScrollObservationAnchorView {
        let view = ScrollObservationAnchorView(frame: .zero)
        view.session = session; view.surface = surface
        return view
    }
    func updateNSView(_ view: ScrollObservationAnchorView, context: Context) {
        let changed = view.session !== session || view.surface != surface
        if changed { view.session?.detach(view.surface, anchor: view) }
        view.session = session; view.surface = surface
        if changed { view.connect() }
    }
    static func dismantleNSView(_ view: ScrollObservationAnchorView, coordinator: Void) {
        view.session?.detach(view.surface, anchor: view)
    }
}
@MainActor final class ScrollObservationAnchorView: NSView {
    weak var session: NativeScrollObservation?
    var surface: ScrollSurface = .library
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connect() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
    func connect() {
        if window == nil { session?.detach(surface, anchor: self) }
        else { session?.attach(surface, anchor: self) }
    }
}
struct ScrollObservationModifier: ViewModifier {
    let session: NativeScrollObservation?
    let surface: ScrollSurface
    @ViewBuilder func body(content: Content) -> some View {
        if let session, session.observes(surface) {
            content.background {
                ScrollObservationAnchor(session: session, surface: surface)
                    .frame(width: 0, height: 0).accessibilityHidden(true)
            }
        } else { content }
    }
}
