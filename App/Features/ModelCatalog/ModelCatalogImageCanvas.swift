import AppKit
import SwiftUI

struct ModelCatalogImageCanvas: NSViewRepresentable {
    let image: NSImage
    @Binding var zoom: Double
    @Binding var zoomRequest: Int
    let fitRequest: Int
    let background: NSColor

    func makeCoordinator() -> Coordinator { Coordinator(zoom: $zoom, zoomRequest: $zoomRequest) }

    func makeNSView(context: Context) -> ModelCatalogCanvasScrollView {
        let view = ModelCatalogCanvasScrollView()
        view.onZoom = { [weak coordinator = context.coordinator] value in
            coordinator?.report(value)
        }
        return view
    }

    func updateNSView(_ view: ModelCatalogCanvasScrollView, context: Context) {
        let appliesInput = context.coordinator.acceptInput($zoom, request: $zoomRequest)
        view.backgroundColor = background
        view.setImage(image)
        if fitRequest == zoomRequest {
            view.requestFit(fitRequest)
        } else if appliesInput {
            view.applyZoom(zoom)
        }
    }

    @MainActor final class Coordinator {
        var zoom: Binding<Double>
        var zoomRequest: Binding<Int>
        private var lastInputRequest = 0
        private var latestValue: Double?
        private var inputGeneration = 0

        init(zoom: Binding<Double>, zoomRequest: Binding<Int>) { self.zoom = zoom; self.zoomRequest = zoomRequest }

        func acceptInput(_ binding: Binding<Double>, request: Binding<Int>) -> Bool {
            zoom = binding; zoomRequest = request
            guard lastInputRequest != request.wrappedValue else { return false }
            lastInputRequest = request.wrappedValue
            inputGeneration &+= 1; latestValue = nil
            return true
        }

        func report(_ value: Double) {
            latestValue = value
            let expectedInput = zoom.wrappedValue, generation = inputGeneration, expectedRequest = zoomRequest.wrappedValue
            Task { @MainActor [weak self] in
                guard let self, self.latestValue == value, self.inputGeneration == generation,
                      self.zoomRequest.wrappedValue == expectedRequest,
                      self.zoom.wrappedValue == expectedInput,
                      abs(self.zoom.wrappedValue - value) > 0.0001 else { return }
                self.zoom.wrappedValue = value
            }
        }
    }
}

final class ModelCatalogCanvasScrollView: NSScrollView {
    var onZoom: ((Double) -> Void)?
    private let imageView = ModelCatalogCanvasImageView()
    private var displayedImage: NSImage?
    private var lastFitRequest: Int?
    private var pendingFit = false

    init() {
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = true
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = false
        allowsMagnification = true
        minMagnification = 0.05
        maxMagnification = 8
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        contentView = ModelCatalogCenteredClipView()
        contentView.drawsBackground = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = false
        imageView.isEditable = false
        imageView.setAccessibilityLabel("Muestra ampliada. Arrastra para explorar la imagen; usa el trackpad para desplazarla o ampliar.")
        documentView = imageView
    }

    required init?(coder: NSCoder) { nil }

    func setImage(_ image: NSImage) {
        guard displayedImage !== image else { return }
        displayedImage = image
        imageView.image = image
        updateImageDimensions()
        pendingFit = true
        needsLayout = true
    }

    private func updateImageDimensions() {
        guard let image = displayedImage else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        // Los decodificadores del catálogo expresan image.size en píxeles. A 100 %
        // cada píxel decodificado ocupa un píxel de pantalla, también en Retina.
        imageView.setFrameSize(NSSize(width: max(1, image.size.width / scale),
                                      height: max(1, image.size.height / scale)))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateImageDimensions()
        recenterIfNeeded()
    }

    func requestFit(_ request: Int) {
        guard lastFitRequest != request else { return }
        lastFitRequest = request
        pendingFit = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if pendingFit, displayedImage != nil, contentSize.width > 1, contentSize.height > 1 {
            pendingFit = false
            let fit = min(contentSize.width / imageView.frame.width,
                          contentSize.height / imageView.frame.height)
            applyZoom(fit)
        }
        recenterIfNeeded()
    }

    func applyZoom(_ value: Double) {
        pendingFit = false
        let center = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(min(maxMagnification, max(minMagnification, value)), centeredAt: center)
        recenterIfNeeded()
        onZoom?(Double(magnification))
    }

    private func recenterIfNeeded() {
        contentView.scroll(to: contentView.constrainBoundsRect(contentView.bounds).origin)
        reflectScrolledClipView(contentView)
    }

    override func magnify(with event: NSEvent) {
        pendingFit = false
        super.magnify(with: event)
        onZoom?(Double(magnification))
    }

    override func smartMagnify(with event: NSEvent) {
        if abs(magnification - 1) > 0.001 { applyZoom(1) }
        else { pendingFit = true; needsLayout = true }
    }
}

private final class ModelCatalogCenteredClipView: NSClipView {
    override var isFlipped: Bool { true }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return bounds }
        if documentView.frame.width < bounds.width {
            bounds.origin.x = (documentView.frame.width - bounds.width) / 2
        }
        if documentView.frame.height < bounds.height {
            bounds.origin.y = (documentView.frame.height - bounds.height) / 2
        }
        return bounds
    }
}

private final class ModelCatalogCanvasImageView: NSImageView {
    override var isFlipped: Bool { true }
    private var dragOrigin: NSPoint?
    private var dragLocation: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let scroll = enclosingScrollView else { return }
        dragOrigin = scroll.contentView.bounds.origin
        dragLocation = event.locationInWindow
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let scroll = enclosingScrollView, let dragOrigin, let dragLocation else { return }
        let delta = NSPoint(x: (event.locationInWindow.x - dragLocation.x) / scroll.magnification,
                            y: (event.locationInWindow.y - dragLocation.y) / scroll.magnification)
        let proposed = NSRect(origin: NSPoint(x: dragOrigin.x - delta.x, y: dragOrigin.y + delta.y),
                              size: scroll.contentView.bounds.size)
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(proposed).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func mouseUp(with event: NSEvent) {
        finishDrag()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishDrag() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { finishDrag() }
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func cancelOperation(_ sender: Any?) { finishDrag() }

    private func finishDrag() {
        if dragOrigin != nil { NSCursor.pop() }
        dragOrigin = nil
        dragLocation = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
