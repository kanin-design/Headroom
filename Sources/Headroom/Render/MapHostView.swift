import AppKit
import IOSurface
import Metal
import QuartzCore
import SwiftUI

/// The ring's window into the display. It draws only while something is moving, and it draws on a thread of its own, so
/// the ring keeps moving whatever the rest of the window is doing.
final class MapHostView: NSView {
    weak var model: AppModel?
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    /// Everything about drawing the ring.
    private(set) var drawer: RingDrawer!
    private var trackingArea: NSTrackingArea?
    private var downPoint: NSPoint?
    /// A press on empty background, which moves the window if the pointer moves.
    private var backgroundDown: NSEvent?
    private var doubleClickWatch: Any?
    /// For a check: how many times the window has been told to follow the pointer.
    private(set) var windowMovesStarted = 0
    private var pinch: CGFloat = 0
    var framesDrawn: Int { drawer.framesDrawn }
    /// A scripted check takes pictures of the window wherever it is, so it keeps drawing.
    static var drawsWhenHidden = ScriptRunner.path != nil
    private var canBeSeen: Bool { Self.drawsWhenHidden || window?.occlusionState.contains(.visible) == true }

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
        // Every Mac can draw this one. The first frame changes it if the narrow one will do.
        l.pixelFormat = MapRenderer.outputFormat
        l.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        l.wantsExtendedDynamicRangeContent = true
        l.framebufferOnly = true
        l.maximumDrawableCount = 3
        l.isOpaque = true
        l.backgroundColor = CGColor(gray: 0.02, alpha: 1)
        drawer = RingDrawer(engine: model.engine, layer: l)
        drawer.stopped = { [weak self] frame in self?.rest(after: frame) }
        model.engine.requestFrame = { [weak self] in self?.startAnimating() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { drawer?.end() }

    private var contentScale: CGFloat { window?.backingScaleFactor ?? 2 }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else {
            drawer.detach()
            return
        }
        watchForDoubleClicksOnTop()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowCameOrWent(_:)), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        center.addObserver(self, selector: #selector(windowCameOrWent(_:)), name: NSWindow.didMiniaturizeNotification, object: window)
        center.addObserver(self, selector: #selector(windowCameOrWent(_:)), name: NSApplication.didHideNotification, object: nil)
        drawer.attach(to: self)
        updateDrawableSize()
        startAnimating()
        // The map has the keyboard from the start, so Esc and Space simply work.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

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
            tellDrawer()
            drawer.drawWithWindow()
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
        drawer.resize(to: CGSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1)))
    }

    /// What drawing needs to know that only the main thread may ask: the screen's scale and how far past white it can go,
    /// and the format of the picture that follows from that.
    private func tellDrawer() {
        let headroom = window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
        drawer.screen(scale: contentScale, headroom: headroom, hasRoom: bounds.width > 1)
        if let renderer = model?.engine.renderer { drawer.use(Self.forcedFormat ?? renderer.screenFormat(headroom: headroom)) }
    }

    func startAnimating() {
        // It starts again when the window can be seen, from where it had got to.
        guard window != nil, canBeSeen else { return }
        tellDrawer()
        drawer.start()
    }

    /// For a check: the picture in one format, whatever the screen can do.
    nonisolated(unsafe) static var forcedFormat: MTLPixelFormat?

    /// Once the ring has stopped and its last frame is done, it holds on to nothing but what's on screen.
    private func rest(after frame: Int) {
        guard !inLiveResize else { return }
        drawer.rest(after: frame, putAway: window?.isMiniaturized == true || NSApp.isHidden)
    }

    /// For a check: what happens when the Mac is short of memory and really takes what it's allowed to.
    func loseWhatItMayLose() {
        drawer.loseWhatItMayLose()
    }

    /// The ring moved with the rest of the window: this frame of it reaches the screen with theirs. While the window is
    /// being resized, each new size draws its own frame.
    func drawWithWindow() {
        guard window != nil, canBeSeen, !inLiveResize else { return }
        tellDrawer()
        drawer.drawWithWindow()
    }

    @objc private func windowCameOrWent(_ note: Notification) {
        let isVisible = window?.occlusionState.contains(.visible) == true
        model?.windowCameOrWent(isVisible: isVisible || Self.drawsWhenHidden)
        if isVisible {
            // What was on screen may be gone, so the ring is always drawn again.
            drawer.wakeSurfaces()
            startAnimating()
            return
        }
        // Nobody can see it, so nothing is drawn. Whatever's still drawing gets a moment to finish.
        if !Self.drawsWhenHidden { drawer.stop() }
        let frame = drawer.framesDrawn
        guard frame > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.rest(after: frame) }
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
        // These moves come whatever is over the ring. What's there says for itself what it lights.
        guard window?.contentView?.superview?.hitTest(event.locationInWindow) === self else {
            model.pointerOffRing()
            return
        }
        model.pointerMoved(to: model.polar(convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        model?.pointerMoved(to: nil)
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        backgroundDown = nil
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if p.y < titleBarHeight {
            downPoint = nil
            moveWindow(with: event)
        } else if event.modifierFlags.contains(.command) {
            // ⌘-click copies the name of what's under it, and that's all it does.
            downPoint = nil
            if let model, let polar = model.polar(p), let thing = model.thing(at: polar) { model.copyName(of: thing) }
        } else if isEmptyBackground(p) {
            backgroundDown = event
        }
    }

    /// Nothing is drawn here. The hole in the ring isn't empty: it holds the numbers, and a click there goes back up.
    private func isEmptyBackground(_ p: CGPoint) -> Bool {
        guard let model else { return false }
        guard let polar = model.polar(p) else { return true }
        return polar.radius >= RingLayout.hole && model.engine.layout.hit(angle: polar.angle, radius: polar.radius) == nil
    }

    /// How far down the window the toolbar reaches. The map goes on under it, and where none of the toolbar's controls are, a
    /// press comes through to the map. So along the top, the map does what a title bar does.
    private var titleBarHeight: CGFloat {
        guard let window else { return 0 }
        return window.frame.height - window.contentLayoutRect.maxY
    }

    /// A double-click along the top, with nothing of the toolbar's under it, is one on a title bar.
    private func watchForDoubleClicksOnTop() {
        guard doubleClickWatch == nil else { return }
        doubleClickWatch = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.clickCount == 2, let window, event.window === window,
                  self.convert(event.locationInWindow, from: nil).y < self.titleBarHeight,
                  window.contentView?.superview?.hitTest(event.locationInWindow) === self else { return event }
            // What you've chosen in System Settings for this. Fill and Zoom both end up filling the screen here.
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "None": break
            case "Minimize": window.performMiniaturize(nil)
            default: window.performZoom(nil)
            }
            return nil
        }
    }

    private func moveWindow(with event: NSEvent) {
        windowMovesStarted += 1
        window?.performDrag(with: event)
    }

    /// A plain click on the background still clears what's selected, so the window only moves once the pointer does.
    override func mouseDragged(with event: NSEvent) {
        guard let start = backgroundDown else { return }
        let dx = event.locationInWindow.x - start.locationInWindow.x, dy = event.locationInWindow.y - start.locationInWindow.y
        guard dx * dx + dy * dy >= 9 else { return }
        backgroundDown = nil
        downPoint = nil
        moveWindow(with: start)
    }

    override func mouseUp(with event: NSEvent) {
        backgroundDown = nil
        defer { downPoint = nil }
        guard let downPoint, let model else { return }
        let dx = event.locationInWindow.x - downPoint.x, dy = event.locationInWindow.y - downPoint.y
        guard dx * dx + dy * dy < 16 else { return }
        model.click(at: pointInRing(event), count: event.clickCount)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let model, let polar = pointInRing(event), let thing = model.thing(at: polar) else { return nil }
        return model.menu(for: thing)
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

    // MARK: VoiceOver

    /// To VoiceOver the map is a group of what's in the folder you're in, biggest first, each with its size and its share
    /// of the folder. Pressing one does what a click does: a folder opens, a file is selected.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityRoleDescription() -> String? { "disk map" }

    override func accessibilityLabel() -> String? {
        guard let model else { return "Disk map" }
        return "Map of " + (model.focus == 0 ? (model.volume?.shownName ?? "the disk") : model.displayName(model.focus))
    }

    /// The same elements while the picture stays the same, so VoiceOver keeps its place among them.
    private var piecesForVoiceOver: (key: String, elements: [Any])?

    override func accessibilityChildren() -> [Any]? {
        guard let model, model.tree != nil, model.ring.radius > 0 else { return [] }
        let layout = model.engine.layout
        let ring = model.ring
        let key = "\(model.focus) \(model.treeVersion) \(layout.pieces.count) \(ring.center) \(ring.radius)"
        if let cached = piecesForVoiceOver, cached.key == key { return cached.elements }
        let inner = layout.pieces.enumerated().filter { $0.element.ring == 0 && $0.element.bytes > 0 }
        let whole = Double(max(inner.reduce(UInt64(0)) { $0 &+ $1.element.bytes }, 1))
        let elements: [Any] = inner.sorted { $0.element.bytes > $1.element.bytes }.map { _, piece in
            let element = RingPieceElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            element.setAccessibilityLabel(model.displayName(piece: piece))
            element.setAccessibilityValue("\(formatBytes(piece.bytes)), \(Int((Double(piece.bytes) / whole * 100).rounded()))%")
            // In the view's own points, so it stays right when the window moves.
            element.setAccessibilityFrameInParentSpace(Self.box(of: piece, in: ring))
            // Found again when pressed: the ring may have changed since VoiceOver was told about this piece, and the same
            // place in it can hold something else by then.
            let node = piece.node, smaller = piece.isSmaller
            element.press = { [weak model] in
                guard let model, let now = model.engine.layout.pieces.firstIndex(where: {
                    $0.node == node && $0.isSmaller == smaller && $0.ring == 0
                }) else { return false }
                model.click(piece: now)
                return true
            }
            return element
        }
        piecesForVoiceOver = (key, elements)
        return elements
    }

    /// The ring has changed: VoiceOver asks again.
    func voiceOverLayoutChanged() {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        piecesForVoiceOver = nil
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// A wedge's bounding box, in the view's points.
    private static func box(of piece: Piece, in ring: RingGeometry) -> CGRect {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        let steps = max(Int((piece.a1 - piece.a0) / 0.05), 1)
        for step in 0...steps {
            let angle = CGFloat(piece.a0 + (piece.a1 - piece.a0) * Float(step) / Float(steps))
            for r in [piece.r0, piece.r1] {
                let x = ring.center.x + sin(angle) * CGFloat(r) * ring.radius
                let y = ring.center.y - cos(angle) * CGFloat(r) * ring.radius
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        // In Free Up the keyboard steps through the list: nothing here does anything until you clean.
        if model.lens == .freeUp, model.handlePlanKey(event) { return }
        switch event.keyCode {
        case 53, 51: model.goUp()                 // escape, delete
        case 49: model.toggleLook()               // space
        default: super.keyDown(with: event)
        }
    }

    // Hold Option to see the disk as it will be after the clean. With ⌘ it's part of a shortcut.
    override func flagsChanged(with event: NSEvent) {
        model?.setPreviewAfter(event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.command))
        super.flagsChanged(with: event)
    }
}

/// One piece of the ring, to VoiceOver.
final class RingPieceElement: NSAccessibilityElement {
    /// False when the piece isn't on the ring any more.
    var press: () -> Bool = { false }

    override func accessibilityPerformPress() -> Bool { press() }
}

struct MapView: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> MapHostView {
        let view = MapHostView(model: model)
        model.mapView = view
        return view
    }

    func updateNSView(_ view: MapHostView, context: Context) {}
}

/// The ring's place in the window, handed to the ring on every frame of whatever animation SwiftUI moves it with, as the
/// panel comes and goes, and at once when nothing animates it, as while the window is resized. So the ring and everything
/// drawn over it, such as the numbers in its middle, move as one. It shows nothing itself.
struct RingPlace: View, Animatable {
    var center: CGPoint
    var radius: CGFloat
    /// The window's size. When it changes, the picture changes size too, and that draws a frame of its own.
    let size: CGSize
    let model: AppModel

    var animatableData: AnimatablePair<CGPoint.AnimatableData, CGFloat> {
        get { AnimatablePair(center.animatableData, radius) }
        set {
            center.animatableData = newValue.first
            radius = newValue.second
        }
    }

    var body: some View {
        if model.engine.setPlace(center: center, radius: radius), let view = model.mapView, view.bounds.size == size { view.drawWithWindow() }
        return Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
    }
}
