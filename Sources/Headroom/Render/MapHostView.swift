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
    /// How far down the window its top works as a title bar, whatever is under the pointer.
    private static let titleBarHeight: CGFloat = 52
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
        let p = convert(event.locationInWindow, from: nil)
        // The card covers part of the ring. What's under it can't be pointed at.
        let onCard = model.look != nil && model.lookCardFrame.contains(p)
        model.pointerMoved(to: onCard ? nil : model.polar(p))
    }

    override func mouseExited(with event: NSEvent) {
        model?.pointerMoved(to: nil)
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        backgroundDown = nil
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if p.y < Self.titleBarHeight {
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

    /// A double-click along the top, with nothing else under it, is one on a title bar. It's caught here because the top of
    /// the window is part ours and part macOS's real title bar, and this way the whole of it does the same.
    private func watchForDoubleClicksOnTop() {
        guard doubleClickWatch == nil else { return }
        doubleClickWatch = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.clickCount == 2, let window, event.window === window,
                  self.convert(event.locationInWindow, from: nil).y < Self.titleBarHeight,
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
