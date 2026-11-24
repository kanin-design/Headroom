import AppKit
import Foundation
import Metal
import simd

/// How a change of picture moves.
public enum RingTransition: Sendable, Equatable {
    /// The first picture: it unfurls out of the middle.
    case appear
    /// Into a piece: everything scales around it until it fills the ring. Give the piece's place as it was.
    case zoomIn(ZoomMapping?)
    /// Back out: the old picture shrinks into the piece that holds it. Give that piece's place in the new picture.
    case zoomOut(ZoomMapping?)
    /// The same shape in new colours.
    case recolor
    /// New sizes arriving many times a second, as while something is being measured: what's pointed at stays lit.
    case live
    /// A new picture of the same place, as after something changed or was removed.
    case settle
    /// The new picture at once: nothing moves or fades.
    case instant

    /// New sizes arriving: what's pointed at stays lit and pieces glide on.
    public var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    /// At once: nothing moves.
    public var isInstant: Bool {
        if case .instant = self { return true }
        return false
    }

    /// The pieces fly to new places: a first picture, or a zoom.
    var travels: Bool {
        switch self {
        case .appear, .zoomIn, .zoomOut: true
        case .recolor, .live, .settle, .instant: false
        }
    }
}

/// Where a zoom is headed: it maps the old ring to the new one, sliding everything else out of the way.
public struct ZoomMapping: Sendable, Equatable {
    /// The piece's start and end angle, and its outer edge as a share of the radius.
    public var a0: Float, a1: Float, r1: Float

    public init(a0: Float, a1: Float, r1: Float) {
        self.a0 = a0
        self.a1 = a1
        self.r1 = r1
    }

    /// The place of a piece: zooming into it, or out to it.
    public init(_ piece: Piece) {
        self.init(a0: piece.a0, a1: piece.a1, r1: piece.r1)
    }

    /// Where a piece's place (start, end, inner, outer) goes in the zoom.
    public func apply(_ g: SIMD4<Float>) -> SIMD4<Float> {
        let sweep = max(a1 - a0, 0.0001)
        let scale = 2 * Float.pi / sweep
        func angle(_ a: Float) -> Float { min(max((a - a0) * scale, 0), 2 * .pi) }
        let shift = r1 - RingLayout.hole
        func radius(_ r: Float) -> Float { max(r - shift, RingLayout.hole) }
        return SIMD4(angle(g.x), angle(g.y), radius(g.z), radius(g.w))
    }
}

/// Holds the picture on screen and everything that moves. Give it a new `RingLayout` with `apply(_:_:)` and a transition,
/// and it carries every piece from where it is to where it goes. Each transition stores where every piece starts and
/// ends, and each frame only advances one number, so a zoom costs the same however many pieces it moves, and nothing is
/// drawn once it's done.
///
/// Change it on the main actor, as the compiler checks. The ring is drawn on a thread of its own, so everything that moves
/// is changed and read while holding a lock. The picture itself, `layout`, only ever changes on the main thread.
public final class SunburstEngine: @unchecked Sendable {
    /// Nil when there's no GPU to draw with.
    let renderer: SunburstRenderer?
    /// The picture now: what `apply(_:_:)` was last given.
    @MainActor public private(set) var layout = RingLayout()
    private let lock = NSLock()

    private var instances: [SegmentGPU] = []
    private var keys: [UInt64] = []
    private var parents: [Int32] = []
    private var pieceCount = 0

    // One spring carries every transition.
    private var x: Float = 1
    private var velocity: Float = 0
    private var stiffness: Float = 150
    private var damping: Float = 21

    private var emphasisNow: [Float] = []
    private var emphasisGoal: [Float] = []
    /// How much of the tint each piece takes, 0 to 1: all of it, unless only some of what's lit is to take it.
    private var tintShareNow: [Float] = []
    private var tintShareGoal: [Float] = []
    private var dimNow: Float = 0
    private var dimGoal: Float = 0
    /// One colour for what's lit and the way out to it, so things far apart read as one set, and how much of it shows.
    private var tintNow: Float = 0
    private var tintGoal: Float = 0
    private var tintColorNow = SIMD3<Float>(0, 0, 0)
    private var tintColorGoal = SIMD3<Float>(0, 0, 0)
    /// Points: the least a lit piece is drawn across while a tint shows.
    private static let minLitPoints: Float = 4
    /// Whether a lit piece too thin to see is drawn that wide. Not while only some of what's lit takes the tint: then the
    /// tint says how much of what's lit it is, and widening its thin pieces would overstate that.
    private var widensLit = true

    // In points, so the ring is right on any display, and when a window moves between displays.
    private var centerNow = SIMD2<Float>(0, 0)
    private var radiusNow: Float = 0
    /// The window moved the ring since the last frame.
    private var placeChanged = false
    /// Where the ring is drawn now, in the view's points.
    public var place: (center: CGPoint, radius: CGFloat) {
        lock.withLock { (CGPoint(x: CGFloat(centerNow.x), y: CGFloat(centerNow.y)), CGFloat(radiusNow)) }
    }
    /// For a check: where the ring is drawn now, in points.
    @_spi(Diagnostics) public var placeNow: (center: SIMD2<Float>, radius: Float) { lock.withLock { (centerNow, radiusNow) } }
    private var scaleShown = true
    /// How many wholes the scale counts across, from the picture on screen: 0 for no scale.
    private var dialSides = 1

    /// Colour and glow can hold back until something is pointed at. See `setCalm(_:)`.
    private var calmNow: Float = 1
    private var calmGoal: Float = 1
    private var glowNow: Float = 1
    private var glowGoal: Float = 1
    private static let colourAtRest: Float = 0.86
    private static let glowAtRest: Float = 0.25

    /// For a check: a slower clock, for watching motion by eye.
    @_spi(Diagnostics) public var timeScale: Float = 1

    /// Asks the view for frames until nothing moves. The view sets it.
    var requestFrame: () -> Void = {}

    /// Whether Reduce Motion is on. Asked on the main thread each time a picture changes.
    private let reducesMotion: () -> Bool

    /// `reducesMotion` says whether pictures should dissolve in place instead of travel; by default, as System Settings says.
    /// `shaders` is a file of the shaders' source to draw with instead of the ones built in, for working on them.
    public init(reducesMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }, shaders: URL? = nil) {
        renderer = SunburstRenderer(shaders: shaders)
        self.reducesMotion = reducesMotion
    }

    /// Whether there's a GPU to draw with. Without one, pictures are still laid out and moved, but nothing is drawn.
    public var canDraw: Bool { renderer != nil }

    // MARK: Pictures

    /// Shows a new picture, moving to it as `transition` says.
    @MainActor public func apply(_ new: RingLayout, _ transition: RingTransition) {
        // Asked here, on the main thread, where System Settings can be.
        let reduceMotion = reducesMotion()
        lock.withLock {
            dialSides = new.dialSides
            applyLocked(new, transition, reduceMotion: reduceMotion)
        }
        requestFrame()
    }

    @MainActor private func applyLocked(_ new: RingLayout, _ transition: RingTransition, reduceMotion: Bool) {
        let t = x
        let colorT = min(max(x, 0), 1)
        var currentIndex = [UInt64: Int](minimumCapacity: keys.count)
        for i in stride(from: keys.count - 1, through: 0, by: -1) { currentIndex[keys[i]] = i }

        func geometryNow(_ i: Int) -> SIMD4<Float> { instances[i].from + (instances[i].to - instances[i].from) * t }
        func colorNow(_ i: Int) -> SIMD4<Float> { instances[i].colorFrom + (instances[i].colorTo - instances[i].colorFrom) * colorT }

        var enterMapping: ZoomMapping?
        var exitMapping: ZoomMapping?
        var appearing = false
        let instant = transition.isInstant
        switch transition {
        case .appear: appearing = true
        case .zoomIn(let m): exitMapping = m
        case .zoomOut(let m): enterMapping = m
        default: break
        }
        // With Reduce Motion nothing travels: the old picture fades out where it is, and the new one fades in where it ends up.
        let dissolve = reduceMotion && transition.travels

        var out: [SegmentGPU] = []
        out.reserveCapacity(new.pieces.count + keys.count / 2)
        var outKeys: [UInt64] = []
        outKeys.reserveCapacity(out.capacity)
        var outParents: [Int32] = []
        outParents.reserveCapacity(out.capacity)
        var used = [Bool](repeating: false, count: keys.count)
        var newIndex = [UInt64: Int](minimumCapacity: new.pieces.count)

        for (index, p) in new.pieces.enumerated() {
            let to = SIMD4<Float>(p.a0, p.a1, p.r0, p.r1)
            let colorTo = SIMD4<Float>(p.color.x, p.color.y, p.color.z, 1)
            var from = to
            var colorFrom = SIMD4<Float>(p.color.x, p.color.y, p.color.z, 0)
            var markedFrom = p.marked
            if instant {
                // Where it ends up, as it is there.
                colorFrom = colorTo
            } else if dissolve {
                // Where it ends up, fading in.
            } else if let i = currentIndex[p.key], !appearing {
                from = geometryNow(i)
                colorFrom = colorNow(i)
                markedFrom = instances[i].plan.x + (instances[i].plan.y - instances[i].plan.x) * colorT
                used[i] = true
            } else if appearing {
                // Unfurls out of the middle, like something opening.
                let h = RingLayout.hole
                from = SIMD4(p.a0 * 0.72, p.a1 * 0.72, h, h + (p.r1 - p.r0) * 0.15)
            } else if p.parent >= 0 {
                // Grows out of the outer edge of the piece it sits on, wherever that is right now.
                let q = out[Int(p.parent)]
                let sweep = q.to.y - q.to.x
                let f0 = sweep > 0 ? (p.a0 - q.to.x) / sweep : 0
                let f1 = sweep > 0 ? (p.a1 - q.to.x) / sweep : 1
                let span = q.from.y - q.from.x
                from = SIMD4(q.from.x + f0 * span, q.from.x + f1 * span, q.from.w, q.from.w)
            } else if let m = enterMapping {
                from = m.apply(to)
            }
            newIndex[p.key] = index
            out.append(
                SegmentGPU(
                    from: from, to: to, colorFrom: colorFrom, colorTo: colorTo, params: SIMD4(p.look, p.seed, p.calm, p.deeper),
                    plan: SIMD4(markedFrom, p.marked, p.isShared ? 1 : 0, 0)))
            outKeys.append(p.key)
            outParents.append(p.parent)
        }
        pieceCount = out.count

        // Whatever isn't in the new picture leaves: into the piece that survives it, or carried off by the zoom.
        if !appearing && !instant {
            for i in keys.indices where !used[i] {
                let nowColor = colorNow(i)
                if nowColor.w < 0.01 { continue }
                let g = geometryNow(i)
                var to = SIMD4<Float>(g.x, g.y, g.z, g.z)
                var a = i < parents.count ? parents[i] : -1
                var survivor = -1
                var survivorOld = -1
                while a >= 0 {
                    if let found = newIndex[keys[Int(a)]] { survivor = found; survivorOld = Int(a); break }
                    a = parents[Int(a)]
                }
                if survivor >= 0 {
                    let old = instances[survivorOld].to
                    let target = out[survivor].to
                    let sweep = old.y - old.x
                    let f0 = sweep > 0 ? (instances[i].to.x - old.x) / sweep : 0
                    let f1 = sweep > 0 ? (instances[i].to.y - old.x) / sweep : 1
                    let span = target.y - target.x
                    to = SIMD4(target.x + f0 * span, target.x + f1 * span, target.w, target.w)
                } else if let m = exitMapping {
                    to = m.apply(g)
                }
                if dissolve { to = g }
                let leaving = instances[i].plan.x + (instances[i].plan.y - instances[i].plan.x) * colorT
                out.append(
                    SegmentGPU(
                        from: g, to: to, colorFrom: nowColor, colorTo: SIMD4(nowColor.x, nowColor.y, nowColor.z, 0), params: instances[i].params,
                        plan: SIMD4(leaving, leaving, instances[i].plan.z, 0)))
                outKeys.append(keys[i])
                outParents.append(-1)
            }
        }

        let isLive = transition.isLive
        var nextNow = [Float](repeating: 0, count: out.count)
        var nextGoal = nextNow
        var nextShareNow = [Float](repeating: 1, count: out.count)
        var nextShareGoal = nextShareNow
        if isLive {
            // New numbers shouldn't disturb what you're pointing at.
            for i in 0..<pieceCount {
                if let old = currentIndex[outKeys[i]], old < emphasisNow.count {
                    nextNow[i] = emphasisNow[old]
                    nextGoal[i] = emphasisGoal[old]
                    nextShareNow[i] = tintShareNow[old]
                    nextShareGoal[i] = tintShareGoal[old]
                }
            }
        } else {
            dimGoal = 0
            tintGoal = 0
            renderer?.liftLit = false
        }

        instances = out
        keys = outKeys
        parents = outParents
        layout = new
        renderer?.setInstances(instances)
        emphasisNow = nextNow
        emphasisGoal = nextGoal
        tintShareNow = nextShareNow
        tintShareGoal = nextShareGoal
        emphasisChangedSinceDrawn = true

        // Every piece now starts from where it is, with less far to go. Scaling the speed up to match keeps anything still
        // heading the same way moving at the same pace, so new numbers arriving many times a second don't make it stutter.
        let carried = isLive && x < 0.999 ? max(velocity, 0) / (1 - x) : 0
        x = 0
        velocity = 0
        switch transition {
        case .appear: setSpring(stiffness: 52, dampingRatio: 0.88)
        case .zoomIn, .zoomOut: setSpring(stiffness: 120, dampingRatio: 0.92)
        case .recolor: setSpring(stiffness: 70, dampingRatio: 1)
        case .live: setSpring(stiffness: 60, dampingRatio: 1)
        case .settle, .instant: setSpring(stiffness: 80, dampingRatio: 1)
        }
        if dissolve { setSpring(stiffness: 90, dampingRatio: 1) }
        velocity = min(carried, stiffness.squareRoot())
        // Already there.
        if instant { x = 1 }
    }

    private func setSpring(stiffness k: Float, dampingRatio: Float) {
        stiffness = k
        damping = 2 * k.squareRoot() * dampingRatio
    }

    // MARK: Emphasis

    /// Lights what an emphasis says and lets the rest step back; nil, or an empty one, brings everything back. With a tint,
    /// what's lit takes on that colour, the way out part of it, and a lit piece too small to see is drawn a few points
    /// across; with `tinted`, only those pieces take it, and the rest keep their own colours.
    @MainActor public func setEmphasis(_ emphasis: RingEmphasis?) {
        let emphasis = emphasis ?? RingEmphasis()
        setEmphasis(
            primary: emphasis.primary, related: emphasis.light.full, ancestors: emphasis.light.holding, tint: emphasis.tint,
            tinted: emphasis.tinted)
    }

    /// The same, piece by piece: `primary` lifted, `related` lit whole, `ancestors` lit less.
    @MainActor public func setEmphasis(
        primary: Int?, related: [Range<Int>], ancestors: [Int] = [], tint: SIMD3<Float>? = nil,
        tinted: [Range<Int>]? = nil
    ) {
        lock.lock()
        guard !emphasisGoal.isEmpty else { lock.unlock(); return }
        for i in emphasisGoal.indices { emphasisGoal[i] = 0 }
        for range in related {
            for i in range where i < pieceCount { emphasisGoal[i] = 1 }
        }
        for i in ancestors where i < pieceCount { emphasisGoal[i] = max(emphasisGoal[i], 0.62) }
        if let primary, primary < pieceCount { emphasisGoal[primary] = 2 }
        dimGoal = (primary != nil || !related.isEmpty) ? 0.62 : 0
        if let tint, dimGoal > 0 {
            // All of what's lit takes the tint, or only what's said to.
            let share: Float = tinted == nil ? 1 : 0
            for i in tintShareGoal.indices { tintShareGoal[i] = share }
            for range in tinted ?? [] {
                for i in range where i < pieceCount { tintShareGoal[i] = 1 }
            }
            widensLit = tinted == nil
            // From no tint, it starts in its own colour rather than passing through the last one, and on the pieces that
            // take it rather than gliding there from the ones that last did.
            if tintNow < 0.01 {
                tintColorNow = tint
                tintShareNow = tintShareGoal
            }
            tintColorGoal = tint
            tintGoal = 1
        } else {
            // The tint fades from the pieces that had it: who takes it stays as it was until the next one.
            tintGoal = 0
        }
        renderer?.liftLit = tintGoal > 0 && widensLit
        lock.unlock()
        requestFrame()
    }

    /// How far colour and glow hold back until something is pointed at, from 0 (not at all) to 1 (all the way, the default).
    /// At 1, pieces at rest sit a step below full colour with a faint glow, so whatever is pointed at stands out.
    @MainActor public func setCalm(_ amount: Float) {
        lock.withLock { calmGoal = amount }
        requestFrame()
    }

    /// How much the ring glows, from 0 to 1 (the default). Lower keeps what's lit reading as a shape.
    @MainActor public func setGlow(_ amount: Float) {
        lock.withLock { glowGoal = amount }
        requestFrame()
    }

    /// Whether a fine scale is drawn around the ring: a mark for every 1%, a longer one for every 10%. On by default.
    @MainActor public var showsScale: Bool {
        get { lock.withLock { scaleShown } }
        set {
            lock.withLock { scaleShown = newValue }
            requestFrame()
        }
    }

    // MARK: Geometry on screen

    /// Where the ring is in the window now. SwiftUI says so on every frame of an animation that moves it, so the ring moves
    /// exactly as everything drawn over it does. The last half second of a spring moves by hundredths of a point, which
    /// nobody can see, so that isn't drawn.
    @discardableResult
    @MainActor public func setPlace(center: CGPoint, radius: CGFloat) -> Bool {
        let changed = lock.withLock {
            let place = SIMD2(Float(center.x), Float(center.y)), size = Float(radius)
            let moved = max(abs(place.x - centerNow.x), abs(place.y - centerNow.y), abs(size - radiusNow))
            guard moved > 0.02 || (radiusNow == 0 && size > 0) else { return false }
            centerNow = place
            radiusNow = size
            placeChanged = true
            return true
        }
        if changed { requestFrame() }
        return changed
    }

    /// For a check: how many pieces are lit, or on their way to being.
    @_spi(Diagnostics) public var litPieces: Int { lock.withLock { emphasisGoal.filter { $0 > 0.5 }.count } }
    /// Which pieces are lit, and how: 2 pointed at, 1 lit whole, 0.62 on the way out.
    @_spi(Diagnostics) public var emphasis: [Float] { lock.withLock { Array(emphasisGoal.prefix(pieceCount)) } }
    /// How much of the tint each piece is to take.
    @_spi(Diagnostics) public var tintShares: [Float] { lock.withLock { Array(tintShareGoal.prefix(pieceCount)) } }
    /// How much of the tint each piece takes in the frame being drawn now.
    @_spi(Diagnostics) public var tintSharesShown: [Float] { lock.withLock { Array(tintShareNow.prefix(pieceCount)) } }

    // MARK: Frames

    /// How lit each piece is has changed since the renderer was last given it.
    private var emphasisChangedSinceDrawn = false

    /// One frame, on the ring's thread: everything moves on by `dt` seconds, and `encode` gets what the shaders need to draw
    /// it, while nothing else can change it. Returns true while anything is still moving.
    func frame(dt: Float, viewport: CGSize, scale: CGFloat, headroom: CGFloat, encode: ((UniformsGPU) -> Void)?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let moving = advance(dt: dt)
        // Once a frame at most, and only for a frame that's drawn: each write takes the next of three places in a buffer
        // the GPU may still be reading the last two frames from.
        if emphasisChangedSinceDrawn, encode != nil {
            renderer?.writeEmphasis(emphasisNow, tintShares: tintShareNow, top: emphasisGoal.firstIndex { $0 > 1 })
            emphasisChangedSinceDrawn = false
        }
        encode?(uniforms(viewport: viewport, scale: scale, headroom: headroom))
        return moving
    }

    /// For a check: everything that moves, moved to where it's going, as after a few seconds of frames. A window that isn't
    /// on screen draws none, so without this a picture of it shows where things were when it last did.
    @_spi(Diagnostics) public func settle() {
        lock.withLock {
            var steps = 0
            while advance(dt: 1 / 30), steps < 240 { steps += 1 }
            emphasisChangedSinceDrawn = true
        }
        requestFrame()
    }

    /// While the ring is still, the memory its drawing used may be taken back.
    func restDrawing() {
        lock.withLock { renderer?.rest() }
    }

    /// For a check: as if the Mac had taken that memory.
    func loseDrawing() {
        lock.withLock {
            renderer?.rest()
            renderer?.loseTargets()
        }
    }

    // MARK: A picture of it

    /// The ring as it is now, settled, in an image of `width` by `height` pixels with the ring in the middle: Display P3, 8 bits
    /// a channel. Names and anything else drawn over the ring aren't in it. Nil without a GPU. Works without a window.
    /// Without `dithered`, the faint noise that keeps dark gradients smooth is left out, for a PNG about half the size.
    /// `inPlace` draws the ring where it is in its view (`place`), for a picture of a view of that size, in place of in the
    /// middle.
    @MainActor public func picture(width: Int, height: Int, scale: CGFloat = 2, dithered: Bool = true, inPlace: Bool = false) -> CGImage? {
        guard let renderer, width > 0, height > 0 else { return nil }
        let device = renderer.device
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: SunburstRenderer.outputFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let target = device.makeTexture(descriptor: d), let commands = renderer.commandQueue.makeCommandBuffer() else { return nil }
        lock.withLock {
            var u = uniforms(viewport: CGSize(width: width, height: height), scale: scale, headroom: 1)
            // Settled, in the middle, with room around it for the scale.
            u.t = 1
            if inPlace, radiusNow > 0 {
                u.center = centerNow * Float(scale)
                u.radius = radiusNow * Float(scale)
            } else {
                u.center = SIMD2(Float(width), Float(height)) * 0.5
                u.radius = max(Float(min(width, height)) * 0.5 - Float(scale) * 22, 1)
            }
            u.dither = dithered ? 1 : 0
            renderer.writeEmphasis(emphasisNow, tintShares: tintShareNow, top: emphasisGoal.firstIndex { $0 > 1 })
            renderer.encode(into: commands, target: target, uniforms: u)
        }
        if target.storageMode == .managed, let blit = commands.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        commands.commit()
        commands.waitUntilCompleted()
        // The next frame on screen draws into textures of its own size again.
        requestFrame()

        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        target.getBytes(&pixels, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3), let p3 = CGColorSpace(name: CGColorSpace.displayP3),
            let provider = CGDataProvider(data: Data(bytes: pixels, count: pixels.count * 2) as CFData),
            let wide = CGImage(
                width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8, space: linear,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                        | CGBitmapInfo.byteOrder16Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: p3,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(wide, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// For a check: what the GPU holds for the ring.
    @_spi(Diagnostics) public func allocations() -> String {
        lock.withLock { renderer?.allocations() ?? "no renderer" }
    }

    /// Moves everything on by `dt` seconds. Returns true while anything is still moving.
    private func advance(dt rawDT: Float) -> Bool {
        let dt = min(rawDT, 1 / 30) * timeScale
        var moving = false

        if abs(x - 1) > 0.0004 || abs(velocity) > 0.002 {
            // A few short steps keep the spring stable whatever the frame rate.
            let steps = 4
            let h = dt / Float(steps)
            for _ in 0..<steps {
                velocity += (-stiffness * (x - 1) - damping * velocity) * h
                x += velocity * h
            }
            moving = true
        } else if x != 1 || velocity != 0 || instances.count != pieceCount {
            x = 1
            velocity = 0
            // Pieces that were leaving are gone now.
            if instances.count != pieceCount {
                instances.removeLast(instances.count - pieceCount)
                keys.removeLast(keys.count - pieceCount)
                parents.removeLast(parents.count - pieceCount)
                emphasisNow.removeLast(emphasisNow.count - pieceCount)
                emphasisGoal.removeLast(emphasisGoal.count - pieceCount)
                tintShareNow.removeLast(tintShareNow.count - pieceCount)
                tintShareGoal.removeLast(tintShareGoal.count - pieceCount)
                renderer?.setInstances(instances)
                emphasisChangedSinceDrawn = true
            }
            moving = true
        }

        let rise = 1 - exp(-dt * 34), fall = 1 - exp(-dt * 13)
        var emphasisChanged = false
        for i in emphasisNow.indices {
            if let now = Self.eased(emphasisNow[i], toward: emphasisGoal[i], rise: rise, fall: fall) {
                emphasisNow[i] = now
                emphasisChanged = true
            }
            if let now = Self.eased(tintShareNow[i], toward: tintShareGoal[i], rise: rise, fall: fall) {
                tintShareNow[i] = now
                emphasisChanged = true
            }
        }
        if emphasisChanged {
            emphasisChangedSinceDrawn = true
            moving = true
        }

        if let now = Self.eased(dimNow, toward: dimGoal, rise: rise, fall: fall) {
            dimNow = now
            moving = true
        }
        if let now = Self.eased(tintNow, toward: tintGoal, rise: rise, fall: fall) {
            tintNow = now
            moving = true
        }
        // From one set to the next, the colour glides as the old set lets go and the new one lights.
        let toward = tintColorGoal - tintColorNow
        if simd_length(toward) > 0.002 {
            tintColorNow += toward * rise
            moving = true
        } else if tintColorNow != tintColorGoal {
            tintColorNow = tintColorGoal
            moving = true
        }

        // The window keeps saying where the ring is while it moves it, so there's a next frame.
        if placeChanged {
            placeChanged = false
            moving = true
        }

        let ease = 1 - exp(-dt * 13)
        if let now = Self.eased(calmNow, toward: calmGoal, rise: ease, fall: ease) {
            calmNow = now
            moving = true
        }
        if let now = Self.eased(glowNow, toward: glowGoal, rise: ease, fall: ease) {
            glowNow = now
            moving = true
        }

        return moving
    }

    /// One frame's step of a value easing toward its goal: `rise` of the way there while it climbs, `fall` while it drops,
    /// and the goal itself once it's that close. Nil when it's there already.
    @inline(__always)
    private static func eased(_ now: Float, toward goal: Float, rise: Float, fall: Float) -> Float? {
        if abs(goal - now) > 0.002 { return now + (goal - now) * (goal > now ? rise : fall) }
        return now != goal ? goal : nil
    }

    private func uniforms(viewport: CGSize, scale: CGFloat, headroom: CGFloat) -> UniformsGPU {
        var u = UniformsGPU()
        u.viewport = SIMD2(Float(viewport.width), Float(viewport.height))
        u.center = centerNow * Float(scale)
        u.radius = radiusNow * Float(scale)
        u.t = x
        u.scale = Float(scale)
        u.dim = dimNow
        u.liftPixels = Float(scale) * 5
        u.tint = SIMD4(tintColorNow, tintNow)
        u.minLit = widensLit ? Self.minLitPoints : 0
        u.bloom = glowNow
        u.restSaturation = 1 - calmNow * (1 - Self.colourAtRest)
        u.glowAtRest = 1 - calmNow * (1 - Self.glowAtRest)
        u.headroom = Float(headroom)
        u.hideScale = scaleShown && dialSides > 0 ? 0 : 1
        u.dialSides = Float(max(dialSides, 1))
        return u
    }
}
