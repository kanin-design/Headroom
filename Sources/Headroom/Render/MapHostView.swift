import AppKit
import IOSurface
import Metal
import QuartzCore
import QuickLookUI
import SwiftUI

/// The ring's window into the display. It draws only while something is moving.
final class MapHostView: NSView {
    weak var model: AppModel?
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var trackingArea: NSTrackingArea?
    private var downPoint: NSPoint?
    private var pinch: CGFloat = 0
    private var framesDrawn = 0
    private var surfaces: [IOSurfaceRef] = []
    private var surfaceOnScreen: IOSurfaceRef?
    private var surfacesAreResting = false
    // kIOSurfacePurgeableNonVolatile, Volatile and Empty, which Swift doesn't get by name.
    private static let mustBeKept: UInt32 = 0, mayBePurged: UInt32 = 1, isEmptied: UInt32 = 2
    private var engine: MapEngine? { model?.engine }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let l = metalLayer
        l.device = model.engine.renderer?.device
        l.pixelFormat = MapRenderer.outputFormat
        l.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        l.wantsExtendedDynamicRangeContent = true
        l.framebufferOnly = true
        l.maximumDrawableCount = 3
        l.isOpaque = true
        l.backgroundColor = CGColor(gray: 0.02, alpha: 1)
        model.engine.requestFrame = { [weak self] in self?.startAnimating() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var contentScale: CGFloat { window?.backingScaleFactor ?? 2 }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        guard let window else {
            link?.invalidate()
            link = nil
            return
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowCameOrWent(_:)), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        link?.invalidate()
        let l = displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        l.isPaused = true
        link = l
        updateDrawableSize()
        startAnimating()
        // The map has the keyboard from the start, so Esc and Space simply work.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    // macOS's preview panel finds whoever will run it through the responder chain.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = QuickLook.shared }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        startAnimating()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        if inLiveResize {
            // Keep the ring and the window in step while dragging the edge.
            metalLayer.presentsWithTransaction = true
            drawFrame()
            metalLayer.presentsWithTransaction = false
        } else {
            startAnimating()
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        startAnimating()
    }

    private func updateDrawableSize() {
        let scale = contentScale
        metalLayer.contentsScale = scale
        let size = CGSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
        guard size != metalLayer.drawableSize else { return }
        metalLayer.drawableSize = size
        // The layer makes new ones in the new size, and nothing should be keeping the old ones around.
        wakeSurfaces()
        surfaces = []
    }

    func startAnimating() {
        guard let link else { return }
        if link.isPaused {
            lastFrame = 0
            link.isPaused = false
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let engine else { return }
        let now = link.timestamp
        let dt = lastFrame == 0 ? 1.0 / 60 : now - lastFrame
        lastFrame = now
        let moving = engine.advance(dt: Float(dt))
        drawFrame(isLast: !moving)
        if !moving { link.isPaused = true }
    }

    private func drawFrame(isLast: Bool = false) {
        guard let engine, let renderer = engine.renderer, bounds.width > 1, let drawable = metalLayer.nextDrawable(),
              let commands = renderer.commandQueue.makeCommandBuffer() else { return }
        framesDrawn &+= 1
        wakeSurfaces()
        if let surface = drawable.texture.iosurface { note(surface) }
        if isLast {
            let frame = framesDrawn
            // A moment after it's on screen, so moving the pointer from piece to piece doesn't keep going back and forth.
            commands.addCompletedHandler { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.restAfter(frame) }
            }
        }
        let headroom = window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
        let u = engine.uniforms(viewport: metalLayer.drawableSize, scale: contentScale, headroom: headroom)
        renderer.encode(into: commands, target: drawable.texture, uniforms: u)
        if metalLayer.presentsWithTransaction {
            commands.commit()
            commands.waitUntilScheduled()
            drawable.present()
        } else {
            commands.present(drawable)
            commands.commit()
        }
    }

    /// Once the ring has stopped and its last frame is done, it holds on to nothing but what's on screen.
    private func restAfter(_ frame: Int) {
        guard frame == framesDrawn, link?.isPaused ?? true, !inLiveResize else { return }
        engine?.renderer?.rest()
        restSurfaces()
    }

    /// The drawing surfaces behind the one on screen, or all of them when the window can't be seen. Their memory can go and
    /// they stay where they are, so there's nothing to make again when the ring next moves.
    private func restSurfaces() {
        surfacesAreResting = true
        let isVisible = window?.occlusionState.contains(.visible) ?? false
        for surface in surfaces where surface !== surfaceOnScreen || !isVisible {
            IOSurfaceSetPurgeable(surface, Self.mayBePurged, nil)
        }
    }

    private func wakeSurfaces() {
        guard surfacesAreResting else { return }
        surfacesAreResting = false
        for surface in surfaces { IOSurfaceSetPurgeable(surface, Self.mustBeKept, nil) }
    }

    /// The layer doesn't say which surfaces it has, so they're noted as they come. It uses them in turn, and never more than this.
    private func note(_ surface: IOSurfaceRef) {
        surfaceOnScreen = surface
        if let at = surfaces.firstIndex(where: { $0 === surface }) {
            surfaces.remove(at: at)
        } else if surfaces.count > metalLayer.maximumDrawableCount {
            IOSurfaceSetPurgeable(surfaces.removeFirst(), Self.mustBeKept, nil)
        }
        surfaces.append(surface)
    }

    /// For a check: what happens when the Mac is short of memory and really takes what it's allowed to.
    func loseWhatItMayLose() {
        engine?.renderer?.rest()
        engine?.renderer?.loseTargets()
        for surface in surfaces where surface !== surfaceOnScreen { IOSurfaceSetPurgeable(surface, Self.isEmptied, nil) }
        surfacesAreResting = true
    }

    @objc private func windowCameOrWent(_ note: Notification) {
        if window?.occlusionState.contains(.visible) == true {
            // What was on screen may be gone, so the ring is always drawn again.
            wakeSurfaces()
            startAnimating()
        } else if link?.isPaused ?? true, framesDrawn > 0 {
            restSurfaces()
        }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func pointInRing(_ event: NSEvent) -> (angle: Float, radius: Float)? {
        guard let model else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        return model.polar(p)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let model else { return }
        let p = convert(event.locationInWindow, from: nil)
        model.pointerMoved(to: model.polar(p))
    }

    override func mouseExited(with event: NSEvent) {
        model?.pointerMoved(to: nil)
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        window?.makeFirstResponder(self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil }
        guard let downPoint, let model else { return }
        let dx = event.locationInWindow.x - downPoint.x, dy = event.locationInWindow.y - downPoint.y
        guard dx * dx + dy * dy < 16 else { return }
        model.click(at: pointInRing(event), count: event.clickCount)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let model, let polar = pointInRing(event), let index = model.engine.layout.hit(angle: polar.angle, radius: polar.radius),
              let menu = model.contextMenu(forPiece: index) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func magnify(with event: NSEvent) {
        pinch += event.magnification
        if event.phase == .began { pinch = event.magnification }
        if pinch > 0.25 {
            pinch = 0
            model?.click(at: pointInRing(event))
        } else if pinch < -0.25 {
            pinch = 0
            model?.goUp()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        // In Free Up the keyboard steps through the list: nothing here does anything until you clean.
        if model.lens == .freeUp, model.handlePlanKey(event) { return }
        switch event.keyCode {
        case 53, 51: model.goUp()                 // escape, delete
        case 49: model.quickLookHovered()         // space
        default: super.keyDown(with: event)
        }
    }

    // Hold Option to see the disk as it will be after the clean.
    override func flagsChanged(with event: NSEvent) {
        model?.setPreviewAfter(event.modifierFlags.contains(.option))
        super.flagsChanged(with: event)
    }
}

struct MapView: NSViewRepresentable {
    let model: AppModel
    let ring: RingGeometry

    func makeNSView(context: Context) -> MapHostView {
        let view = MapHostView(model: model)
        model.mapView = view
        return view
    }

    func updateNSView(_ view: MapHostView, context: Context) {
        model.engine.setGoal(center: ring.center, radius: ring.radius, animated: !view.inLiveResize)
    }
}
