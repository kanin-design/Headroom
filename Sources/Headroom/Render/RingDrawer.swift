import AppKit
import IOSurface
import Metal
import QuartzCore

/// A thread of the ring's own, waiting on the display and on work handed to it.
private final class RingThread: Thread {
    private var loop: CFRunLoop?
    private let started = DispatchSemaphore(value: 0)

    override func main() {
        loop = CFRunLoopGetCurrent()
        // A run loop with nothing to wait on returns at once, so this one waits on a port that never sends.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        started.signal()
        while !isCancelled { _ = RunLoop.current.run(mode: .default, before: .distantFuture) }
    }

    func begin() {
        name = "ring"
        qualityOfService = .userInteractive
        start()
        started.wait()
    }

    /// This, on the ring's thread, as soon as it's free.
    func perform(_ work: @escaping () -> Void) {
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(loop)
    }

    func end() {
        guard let loop else { return }
        perform { [self] in
            cancel()
            CFRunLoopStop(loop)
        }
    }
}

/// Draws the ring in step with the display, on a thread of its own, so it keeps moving however busy the main thread is with
/// the rest of the window: a panel being laid out, names being placed, text being drawn. The main thread says what to show,
/// through the engine, and when to start. This draws until nothing moves, then stops, and while the ring is still, the
/// memory its drawing used may be taken back.
final class RingDrawer: NSObject, @unchecked Sendable {
    let engine: MapEngine
    let layer: CAMetalLayer
    private let thread = RingThread()

    // Only ever touched on the ring's thread.
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    // Only while drawing: when everything last moved on, and when the window last drew a frame of its own.
    private var movedAt: CFTimeInterval = 0
    private var windowDrewAt: CFTimeInterval = 0

    /// One frame at a time. The ring's thread draws, and so does the main thread, in step with the rest of the window.
    private let drawing = NSLock()

    /// What both threads read and change: what the screen is like, and the surfaces the picture is drawn into.
    private let lock = NSLock()
    private var scale: CGFloat = 2
    private var headroom: CGFloat = 1
    private var hasRoom = false
    private var running = false
    private var drawn = 0
    private var surfaces: [IOSurfaceRef] = []
    private var surfaceOnScreen: IOSurfaceRef?
    /// Surfaces of the size or format the picture had before, until the new picture is on screen.
    private var retired: [IOSurfaceRef] = []
    private var surfacesAreResting = false
    // kIOSurfacePurgeableNonVolatile, Volatile and Empty, which Swift doesn't get by name.
    private static let mustBeKept: UInt32 = 0, mayBePurged: UInt32 = 1, isEmptied: UInt32 = 2

    /// Called on the main thread a moment after the last frame of a movement is on screen, with that frame's number.
    var stopped: ((Int) -> Void)?

    init(engine: MapEngine, layer: CAMetalLayer) {
        self.engine = engine
        self.layer = layer
        super.init()
        thread.begin()
    }

    // MARK: From the main thread

    /// Draws in step with the display this view is on.
    func attach(to view: NSView) {
        let new = view.displayLink(target: self, selector: #selector(step(_:)))
        new.isPaused = true
        thread.perform { [self] in
            link?.invalidate()
            link = new
            new.add(to: .current, forMode: .default)
        }
    }

    func detach() {
        thread.perform { [self] in
            link?.invalidate()
            link = nil
            lastFrame = 0
            lock.withLock { running = false }
        }
    }

    /// Lets the thread go. Nothing can be drawn after this.
    func end() {
        detach()
        thread.end()
    }

    /// What drawing needs to know about the screen, which only the main thread may ask.
    func screen(scale: CGFloat, headroom: CGFloat, hasRoom: Bool) {
        lock.withLock {
            self.scale = scale
            self.headroom = headroom
            self.hasRoom = hasRoom
        }
    }

    /// Frames from the next one on, until nothing moves.
    func start() {
        thread.perform { [self] in
            guard let link, link.isPaused else { return }
            lastFrame = 0
            lock.withLock { running = true }
            link.isPaused = false
        }
    }

    /// No more frames, as when nobody can see the window.
    func stop() {
        thread.perform { [self] in
            link?.isPaused = true
            lastFrame = 0
            lock.withLock { running = false }
        }
    }

    var framesDrawn: Int { lock.withLock { drawn } }

    /// A frame now, from the main thread, in the same transaction as the rest of the window, so the ring and everything over
    /// it reach the screen together: while the window is being resized, and on each frame of SwiftUI moving the ring. The
    /// ring's own thread leaves those frames to the window until it stops.
    func drawWithWindow() {
        let now = CACurrentMediaTime()
        drawing.withLock { windowDrewAt = now }
        draw(dt: nil, restarted: false, withTransaction: true, target: now)
    }

    /// The size of the picture, in pixels. The frame being drawn finishes first. Only the main thread changes it, so it can
    /// look without waiting.
    func resize(to size: CGSize) {
        guard size != layer.drawableSize else { return }
        drawing.withLock {
            guard size != layer.drawableSize else { return }
            layer.drawableSize = size
            retireSurfaces()
        }
    }

    /// The picture on screen takes half the memory while the screen can show at most 1.5 times white. When it can show more,
    /// it goes back to the format that holds the brighter glow.
    func use(_ format: MTLPixelFormat) {
        guard layer.pixelFormat != format else { return }
        drawing.withLock {
            guard layer.pixelFormat != format else { return }
            if ScriptRunner.path != nil { print("format now \(format == MapRenderer.outputFormat ? "wide" : "narrow")") }
            layer.pixelFormat = format
            layer.colorspace = CGColorSpace(name: format == MapRenderer.outputFormat ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.extendedDisplayP3)
            retireSurfaces()
        }
    }

    /// Once the ring has stopped and its last frame is done, it holds on to nothing but what's on screen.
    func rest(after frame: Int, putAway: Bool) {
        guard lock.withLock({ frame == drawn && !running }) else { return }
        engine.restDrawing()
        // The drawing surfaces behind the one on screen. Their memory can go and they stay where they are, so there's
        // nothing to make again when the ring next moves. The picture on screen stays while the window is only covered,
        // because it can come to the front at any moment and has to be there. Minimized or hidden, it can go too.
        lock.withLock {
            surfacesAreResting = true
            for surface in surfaces where surface !== surfaceOnScreen || putAway {
                IOSurfaceSetPurgeable(surface, Self.mayBePurged, nil)
            }
        }
    }

    /// What was on screen may be gone, so all of it has to stay from now on.
    func wakeSurfaces() {
        lock.withLock { wakeSurfacesLocked() }
    }

    /// For a check: what happens when the Mac is short of memory and really takes what it's allowed to.
    func loseWhatItMayLose() {
        engine.loseDrawing()
        lock.withLock {
            for surface in surfaces where surface !== surfaceOnScreen { IOSurfaceSetPurgeable(surface, Self.isEmptied, nil) }
            surfacesAreResting = true
        }
    }

    // MARK: Surfaces

    /// A new size or format means new surfaces. The layer lets most of the old ones go, but the last one on screen stays in
    /// memory behind the new picture for as long as nothing else is drawn, which can be for good. So once the new picture is
    /// on screen, the old ones are emptied.
    private func retireSurfaces() {
        lock.withLock {
            retired += surfaces
            surfaces = []
            surfaceOnScreen = nil
        }
    }

    private func wakeSurfacesLocked() {
        guard surfacesAreResting else { return }
        surfacesAreResting = false
        for surface in surfaces { IOSurfaceSetPurgeable(surface, Self.mustBeKept, nil) }
    }

    /// The layer doesn't say which surfaces it has, so they're noted as they come. It uses them in turn, and never more than this.
    private func noteLocked(_ surface: IOSurfaceRef) {
        surfaceOnScreen = surface
        if let at = surfaces.firstIndex(where: { $0 === surface }) {
            surfaces.remove(at: at)
        } else {
            // New, or one that was emptied: either way, what's drawn in it now has to stay.
            IOSurfaceSetPurgeable(surface, Self.mustBeKept, nil)
            if surfaces.count > layer.maximumDrawableCount { IOSurfaceSetPurgeable(surfaces.removeFirst(), Self.mustBeKept, nil) }
        }
        surfaces.append(surface)
    }

    // MARK: On the ring's thread

    @objc private func step(_ link: CADisplayLink) {
        let restarted = lastFrame == 0
        let refresh = max(link.targetTimestamp - link.timestamp, 1.0 / 240)
        // By the display's own clock, so every frame moves on by exactly as much as the screen does. The first after a rest
        // moves on by one refresh of this display, whatever its rate.
        let dt = restarted ? refresh : link.timestamp - lastFrame
        lastFrame = link.timestamp
        // While the window draws the ring with each of its own frames, it's left to that.
        if drawing.withLock({ link.timestamp - windowDrewAt < refresh * 1.5 }) { return }
        let moving = draw(dt: dt, restarted: restarted, withTransaction: false, target: link.targetTimestamp)
        if !moving {
            link.isPaused = true
            lastFrame = 0
            lock.withLock { running = false }
        }
    }

    /// One frame: everything moves on by `dt`, or by the time since it last did, and the picture goes to the screen. Says
    /// whether anything is still moving.
    @discardableResult
    private func draw(dt given: Double?, restarted: Bool, withTransaction: Bool, target: CFTimeInterval) -> Bool {
        drawing.lock()
        defer { drawing.unlock() }
        let began = CACurrentMediaTime()
        let dt = given ?? (movedAt == 0 ? 0 : max(began - movedAt, 0))
        movedAt = began
        let (scale, headroom, hasRoom, noting) = lock.withLock { (self.scale, self.headroom, self.hasRoom, notes != nil) }
        guard hasRoom, let renderer = engine.renderer, let drawable = layer.nextDrawable(), let commands = renderer.commandQueue.makeCommandBuffer() else {
            // Nothing to draw into, but time still passes.
            return engine.frame(dt: Float(dt), viewport: .zero, scale: scale, headroom: headroom, encode: nil)
        }
        let (frame, old): (Int, [IOSurfaceRef]) = lock.withLock {
            drawn &+= 1
            wakeSurfacesLocked()
            if let surface = drawable.texture.iosurface { noteLocked(surface) }
            let old = retired
            retired = []
            return (drawn, old)
        }
        if !old.isEmpty {
            drawable.addPresentedHandler { [weak self] _ in
                guard let self else { return }
                // One the layer has started to use again keeps what's drawn in it.
                self.lock.withLock {
                    for surface in old where !self.surfaces.contains(where: { $0 === surface }) {
                        IOSurfaceSetPurgeable(surface, Self.isEmptied, nil)
                    }
                }
            }
        }
        let viewport = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let moving = engine.frame(dt: Float(dt), viewport: viewport, scale: scale, headroom: headroom) { uniforms in
            renderer.encode(into: commands, target: drawable.texture, uniforms: uniforms)
        }
        if !moving, !withTransaction {
            // A moment after it's on screen, so moving the pointer from piece to piece doesn't keep going back and forth.
            commands.addCompletedHandler { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.stopped?(frame) }
            }
        }
        var entry: Int?
        if noting { entry = noteFrame(drawable: drawable, commands: commands, target: target, dt: dt, restarted: restarted) }
        if withTransaction {
            layer.presentsWithTransaction = true
            commands.commit()
            commands.waitUntilScheduled()
            drawable.present()
            layer.presentsWithTransaction = false
        } else {
            commands.present(drawable)
            commands.commit()
        }
        if let entry {
            let cpu = (CACurrentMediaTime() - began) * 1000
            lock.withLock { if let count = notes?.count, entry < count { notes?[entry].cpu = cpu } }
        }
        return moving
    }

    // MARK: For a check

    /// Each frame of the ring, when it was meant to reach the screen and when it did, and what it cost.
    struct FrameNote {
        var target: CFTimeInterval
        var dt: Double
        var restarted: Bool
        var cpu: Double = 0
        var gpu: Double = 0
        var presented: CFTimeInterval = 0
    }
    private var notes: [FrameNote]?

    func beginNotes() { lock.withLock { notes = [] } }
    func endNotes() -> [FrameNote] { lock.withLock { defer { notes = nil }; return notes ?? [] } }

    private func noteFrame(drawable: CAMetalDrawable, commands: MTLCommandBuffer, target: CFTimeInterval, dt: Double, restarted: Bool) -> Int? {
        let entry: Int? = lock.withLock {
            guard notes != nil else { return nil }
            notes?.append(FrameNote(target: target, dt: dt, restarted: restarted))
            return (notes?.count ?? 1) - 1
        }
        guard let entry else { return nil }
        drawable.addPresentedHandler { [weak self] shown in
            let at = shown.presentedTime
            self?.lock.withLock { if let count = self?.notes?.count, entry < count { self?.notes?[entry].presented = at } }
        }
        commands.addCompletedHandler { [weak self] done in
            let gpu = (done.gpuEndTime - done.gpuStartTime) * 1000
            self?.lock.withLock { if let count = self?.notes?.count, entry < count { self?.notes?[entry].gpu = gpu } }
        }
        return entry
    }
}
