import AppKit
import IOSurface
import Metal
import QuartzCore
import SwiftUI

/// A point on the ring: the angle clockwise from 12 o'clock in radians, and the distance from the middle as a share of the
/// ring's radius.
public typealias Polar = (angle: Float, radius: Float)

/// The view that draws an engine's ring. It draws only while something is moving, and it draws on a thread of its own, so
/// the ring keeps moving whatever the rest of the window is doing. What the pointer and the keys do is up to the host: the
/// view says where they are on the ring, through the callbacks below. Tell it where the ring is with a `RingPlace`, or call
/// `engine.setPlace(center:radius:)`.
///
/// For a chart with everything wired up, use the SwiftUI view `Sunburst` instead.
public final class SunburstView: NSView {
    /// What it draws.
    public let engine: SunburstEngine
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    /// Everything about drawing the ring.
    @_spi(Diagnostics) public private(set) var drawer: RingDrawer!
    private var trackingArea: NSTrackingArea?
    private var downPoint: NSPoint?
    /// A press on empty background, which moves the window if the pointer moves.
    private var backgroundDown: NSEvent?
    // Only set on the main thread; read once more as the view goes, when nothing else can touch it.
    nonisolated(unsafe) private var doubleClickWatch: Any?
    /// For a check: how many times the window has been told to follow the pointer.
    @_spi(Diagnostics) public private(set) var windowMovesStarted = 0
    private var pinch: CGFloat = 0
    /// For a check: how many frames have been drawn.
    @_spi(Diagnostics) public var framesDrawn: Int { drawer.framesDrawn }
    /// For a check: keep drawing while nobody can see the window, as for pictures taken of it wherever it is.
    @_spi(Diagnostics) nonisolated(unsafe) public static var drawsWhenHidden = false
    private var canBeSeen: Bool { Self.drawsWhenHidden || window?.occlusionState.contains(.visible) == true }

    // MARK: Behaviour

    /// For a window whose content reaches under its title bar: a press along the top or on empty background moves the window,
    /// and a double-click along the top does what System Settings says a title bar's does. Off by default.
    public var movesWindow = false
    /// Whether the view takes the keyboard when it appears in a window, so keys reach `onKey` at once. Off by default; a
    /// click on the view always gives it the keyboard.
    public var takesKeyboardFocus = false

    // MARK: Callbacks

    /// Where a point in the view is on the ring, or nil when the ring has no size. By default from where the engine draws it.
    public var polar: (CGPoint) -> Polar?
    /// The pointer moved over the ring, or left it (nil).
    public var onHover: (Polar?) -> Void = { _ in }
    /// The pointer is over something drawn on top of the ring: to the ring that's nothing.
    public var onHoverCovered: () -> Void = {}
    /// A click, or a double-click, that didn't move. Nil when the ring has no size.
    public var onClick: (Polar?, _ count: Int) -> Void = { _, _ in }
    /// A ⌘-click.
    public var onCommandClick: (Polar) -> Void = { _ in }
    /// The menu for a right-click there, if any.
    public var menuAt: (Polar) -> NSMenu? = { _ in nil }
    /// A pinch: true to open what's under the pointer, false to go back out.
    public var onPinch: (_ opening: Bool, Polar?) -> Void = { _, _ in }
    /// A key. True when the host used it; otherwise it goes on up the responder chain.
    public var onKey: (NSEvent) -> Bool = { _ in false }
    /// The modifier keys changed.
    public var onModifiers: (NSEvent) -> Void = { _ in }
    /// The window was covered, minimised or hidden, or came back.
    public var onVisibility: (Bool) -> Void = { _ in }

    // MARK: VoiceOver

    /// What VoiceOver calls the view, and the whole of what it shows.
    public var accessibilityKind = "chart"
    /// What VoiceOver calls the chart as a whole.
    public var accessibilityName: () -> String = { "Chart" }
    /// What the pieces of the first ring are now, by a key that changes when they do, and where the ring is in the view.
    /// Nil while there's nothing to describe.
    public var accessibilityPicture: () -> (key: String, center: CGPoint, radius: CGFloat)? = { nil }
    /// A piece's name, and what it holds, given its share of the ring (0 to 1).
    public var describePiece: (Piece, _ share: Double) -> (label: String, value: String) = { _, _ in ("", "") }
    /// VoiceOver pressed a piece of the first ring: its index now.
    public var onPress: (Int) -> Void = { _ in }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }

    /// An engine is drawn by one view at a time: a new view takes it over from the one before.
    public init(engine: SunburstEngine) {
        self.engine = engine
        polar = { _ in nil }
        super.init(frame: .zero)
        polar = { [weak engine] p in
            guard let place = engine?.placeNow, place.radius > 0 else { return nil }
            let dx = Float(p.x) - place.center.x, dy = Float(p.y) - place.center.y
            var angle = atan2(dx, -dy)
            if angle < 0 { angle += 2 * .pi }
            return (angle, (dx * dx + dy * dy).squareRoot() / place.radius)
        }
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let l = metalLayer
        l.device = engine.renderer?.device
        // Every Mac can draw this one. The first frame changes it if the narrow one will do.
        l.pixelFormat = SunburstRenderer.outputFormat
        l.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        l.wantsExtendedDynamicRangeContent = true
        l.framebufferOnly = true
        l.maximumDrawableCount = 3
        l.isOpaque = true
        l.backgroundColor = CGColor(gray: 0.02, alpha: 1)
        drawer = RingDrawer(engine: engine, layer: l)
        drawer.stopped = { [weak self] frame in self?.rest(after: frame) }
        engine.requestFrame = { [weak self] in self?.startAnimating() }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        drawer?.end()
        if let doubleClickWatch { NSEvent.removeMonitor(doubleClickWatch) }
    }

    private var contentScale: CGFloat { window?.backingScaleFactor ?? 2 }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else {
            drawer.detach()
            return
        }
        if movesWindow { watchForDoubleClicksOnTop() }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowCameOrWent(_:)), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        center.addObserver(self, selector: #selector(windowCameOrWent(_:)), name: NSWindow.didMiniaturizeNotification, object: window)
        center.addObserver(self, selector: #selector(windowCameOrWent(_:)), name: NSApplication.didHideNotification, object: nil)
        drawer.attach(to: self)
        updateDrawableSize()
        startAnimating()
        // With the keyboard from the start, keys simply work.
        if takesKeyboardFocus {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        startAnimating()
    }

    public override func setFrameSize(_ newSize: NSSize) {
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

    public override func viewDidEndLiveResize() {
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
        if let renderer = engine.renderer { drawer.use(Self.forcedFormat ?? renderer.screenFormat(headroom: headroom)) }
    }

    /// Draws frames again until nothing moves, as after the picture changed. The engine asks for this itself.
    public func startAnimating() {
        // It starts again when the window can be seen, from where it had got to.
        guard window != nil, canBeSeen else { return }
        tellDrawer()
        drawer.start()
    }

    /// For a check: the picture in one format, whatever the screen can do.
    @_spi(Diagnostics) nonisolated(unsafe) public static var forcedFormat: MTLPixelFormat?

    /// Once the ring has stopped and its last frame is done, it holds on to nothing but what's on screen.
    private func rest(after frame: Int) {
        guard !inLiveResize else { return }
        drawer.rest(after: frame, putAway: window?.isMiniaturized == true || NSApp.isHidden)
    }

    /// For a check: what happens when the Mac is short of memory and really takes what it's allowed to.
    @_spi(Diagnostics) public func loseWhatItMayLose() {
        drawer.loseWhatItMayLose()
    }

    /// The ring moved with the rest of the window: this frame of it reaches the screen with theirs. While the window is
    /// being resized, each new size draws its own frame.
    public func drawWithWindow() {
        guard window != nil, canBeSeen, !inLiveResize else { return }
        tellDrawer()
        drawer.drawWithWindow()
    }

    @objc private func windowCameOrWent(_ note: Notification) {
        let isVisible = window?.occlusionState.contains(.visible) == true
        onVisibility(isVisible || Self.drawsWhenHidden)
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

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func pointInRing(_ event: NSEvent) -> Polar? {
        polar(convert(event.locationInWindow, from: nil))
    }

    public override func mouseMoved(with event: NSEvent) {
        // These moves come whatever is over the ring. What's there says for itself what it lights.
        guard window?.contentView?.superview?.hitTest(event.locationInWindow) === self else {
            onHoverCovered()
            return
        }
        onHover(polar(convert(event.locationInWindow, from: nil)))
    }

    public override func mouseExited(with event: NSEvent) {
        onHover(nil)
    }

    public override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        backgroundDown = nil
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if movesWindow, p.y < titleBarHeight {
            downPoint = nil
            moveWindow(with: event)
        } else if event.modifierFlags.contains(.command) {
            // ⌘-click is the host's, and that's all it does.
            downPoint = nil
            if let polar = polar(p) { onCommandClick(polar) }
        } else if movesWindow, isEmptyBackground(p) {
            backgroundDown = event
        }
    }

    /// Nothing is drawn here. The hole in the ring isn't empty: it holds the numbers, and a click there goes back up.
    private func isEmptyBackground(_ p: CGPoint) -> Bool {
        guard let polar = polar(p) else { return true }
        return polar.radius >= RingLayout.hole && engine.layout.hit(angle: polar.angle, radius: polar.radius) == nil
    }

    /// How far down the window the toolbar reaches. With `movesWindow`, the chart goes on under it, and where none of the
    /// toolbar's controls are, a press comes through to the chart. So along the top, the chart does what a title bar does.
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
    public override func mouseDragged(with event: NSEvent) {
        guard let start = backgroundDown else { return }
        let dx = event.locationInWindow.x - start.locationInWindow.x, dy = event.locationInWindow.y - start.locationInWindow.y
        guard dx * dx + dy * dy >= 9 else { return }
        backgroundDown = nil
        downPoint = nil
        moveWindow(with: start)
    }

    public override func mouseUp(with event: NSEvent) {
        backgroundDown = nil
        defer { downPoint = nil }
        guard let downPoint else { return }
        let dx = event.locationInWindow.x - downPoint.x, dy = event.locationInWindow.y - downPoint.y
        guard dx * dx + dy * dy < 16 else { return }
        onClick(pointInRing(event), event.clickCount)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        guard let polar = pointInRing(event) else { return nil }
        return menuAt(polar)
    }

    public override func magnify(with event: NSEvent) {
        pinch += event.magnification
        if event.phase == .began { pinch = event.magnification }
        if pinch > 0.25 {
            pinch = 0
            onPinch(true, pointInRing(event))
        } else if pinch < -0.25 {
            pinch = 0
            onPinch(false, pointInRing(event))
        }
    }

    // MARK: VoiceOver

    /// To VoiceOver the view is a group of the pieces of the first ring, biggest first, each with its size and its share.
    /// Pressing one does what the host says.
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .group }
    public override func accessibilityRoleDescription() -> String? { accessibilityKind }

    public override func accessibilityLabel() -> String? { accessibilityName() }

    /// The same elements while the picture stays the same, so VoiceOver keeps its place among them.
    private var piecesForVoiceOver: (key: String, elements: [Any])?

    public override func accessibilityChildren() -> [Any]? {
        guard let picture = accessibilityPicture() else { return [] }
        let layout = engine.layout
        let key = "\(picture.key) \(layout.pieces.count) \(picture.center) \(picture.radius)"
        if let cached = piecesForVoiceOver, cached.key == key { return cached.elements }
        let inner = layout.pieces.enumerated().filter { $0.element.ring == 0 && $0.element.size > 0 }
        let whole = Double(max(inner.reduce(UInt64(0)) { $0 &+ $1.element.size }, 1))
        let elements: [Any] = inner.sorted { $0.element.size > $1.element.size }.map { _, piece in
            let element = RingPieceElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityRole(.button)
            let said = describePiece(piece, Double(piece.size) / whole)
            element.setAccessibilityLabel(said.label)
            element.setAccessibilityValue(said.value)
            // In the view's own points, so it stays right when the window moves.
            element.setAccessibilityFrameInParentSpace(Self.box(of: piece, center: picture.center, radius: picture.radius))
            // Found again when pressed: the ring may have changed since VoiceOver was told about this piece, and the same
            // place in it can hold something else by then.
            let node = piece.node, smaller = piece.isSmaller
            element.press = { [weak self] in
                guard let self, let now = self.engine.layout.pieces.firstIndex(where: {
                    $0.node == node && $0.isSmaller == smaller && $0.ring == 0
                }) else { return false }
                self.onPress(now)
                return true
            }
            return element
        }
        piecesForVoiceOver = (key, elements)
        return elements
    }

    /// The ring has changed: VoiceOver asks again.
    public func voiceOverLayoutChanged() {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        piecesForVoiceOver = nil
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// A wedge's bounding box, in the view's points.
    private static func box(of piece: Piece, center: CGPoint, radius: CGFloat) -> CGRect {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        let steps = max(Int((piece.a1 - piece.a0) / 0.05), 1)
        for step in 0...steps {
            let angle = CGFloat(piece.a0 + (piece.a1 - piece.a0) * Float(step) / Float(steps))
            for r in [piece.r0, piece.r1] {
                let x = center.x + sin(angle) * CGFloat(r) * radius
                let y = center.y - cos(angle) * CGFloat(r) * radius
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Keys

    public override func keyDown(with event: NSEvent) {
        if onKey(event) { return }
        super.keyDown(with: event)
    }

    public override func flagsChanged(with event: NSEvent) {
        onModifiers(event)
        super.flagsChanged(with: event)
    }
}

/// One piece of the ring, to VoiceOver.
final class RingPieceElement: NSAccessibilityElement {
    /// False when the piece isn't on the ring any more.
    var press: () -> Bool = { false }

    override func accessibilityPerformPress() -> Bool { press() }
}

/// The ring's place in the window, handed to the ring on every frame of whatever animation SwiftUI moves it with, and at
/// once when nothing animates it, as while the window is resized. So the ring and everything drawn over it, such as numbers
/// in its middle, move as one. It shows nothing itself.
public struct RingPlace: View, Animatable {
    /// The ring's middle and radius, in the `SunburstView`'s points.
    public var center: CGPoint
    public var radius: CGFloat
    /// The window's size. When it changes, the picture changes size too, and that draws a frame of its own.
    let size: CGSize
    let engine: SunburstEngine
    let view: () -> SunburstView?

    /// `size` is the size of the `SunburstView`; `view` finds it, so each frame of an animation can draw with the window's.
    public init(center: CGPoint, radius: CGFloat, size: CGSize, engine: SunburstEngine, view: @escaping () -> SunburstView?) {
        self.center = center
        self.radius = radius
        self.size = size
        self.engine = engine
        self.view = view
    }

    public nonisolated var animatableData: AnimatablePair<CGPoint.AnimatableData, CGFloat> {
        get { AnimatablePair(center.animatableData, radius) }
        set {
            center.animatableData = newValue.first
            radius = newValue.second
        }
    }

    public var body: some View {
        if engine.setPlace(center: center, radius: radius), let view = view(), view.bounds.size == size { view.drawWithWindow() }
        return Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
    }
}
