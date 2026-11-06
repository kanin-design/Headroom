import AppKit
import Foundation
import Metal
import QuartzCore
import simd

/// How a change of picture moves.
enum RingTransition {
    case appear                     // the first picture blooms out of the middle
    case zoomIn(ZoomMapping?)       // everything scales around the piece you clicked
    case zoomOut(ZoomMapping?)
    case recolor                    // same geometry, new question
    case live                       // numbers settling during a scan
    case settle                     // a new scan, or something removed
}

/// Where a zoom is headed: it maps the old ring to the new one, sliding everything else out of the way.
struct ZoomMapping {
    var a0: Float, a1: Float, r1: Float

    func apply(_ g: SIMD4<Float>) -> SIMD4<Float> {
        let sweep = max(a1 - a0, 0.0001)
        let scale = 2 * Float.pi / sweep
        func angle(_ a: Float) -> Float { min(max((a - a0) * scale, 0), 2 * .pi) }
        let shift = r1 - RingLayout.hole
        func radius(_ r: Float) -> Float { max(r - shift, RingLayout.hole) }
        return SIMD4(angle(g.x), angle(g.y), radius(g.z), radius(g.w))
    }
}

/// Everything that moves. Each transition stores where every piece starts and ends, and each frame only advances one
/// number, so a zoom costs the same however many pieces it moves, and nothing is drawn once it's done.
@MainActor
final class MapEngine {
    let renderer: MapRenderer?
    private(set) var layout = RingLayout()

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
    private var dimNow: Float = 0
    private var dimGoal: Float = 0

    // In points, so the ring is right on any display, and when a window moves between displays.
    private var centerNow = SIMD2<Float>(0, 0)
    private var radiusNow: Float = 0
    private var centerGoal = SIMD2<Float>(0, 0)
    private var radiusGoal: Float = 0
    private var ghostNow: Float = 0
    private var ghostGoal: Float = 0
    private var ghostSlices: [(end: Float, color: SIMD3<Float>)] = []
    private var previewNow: Float = 0
    private var previewGoal: Float = 0
    private var previewColor: SIMD3<Float> = .zero
    /// How many colours the new free space can have at once.
    static let ghostSliceLimit = 12

    /// In the Map view, colour and glow hold back until you point at something. The other views use both to say something.
    private var calmNow: Float = 1
    private var calmGoal: Float = 1
    private static let colourAtRest: Float = 0.86
    private static let glowAtRest: Float = 0.25

    /// A slower clock for checking motion by eye.
    var timeScale: Float = 1

    var requestFrame: () -> Void = {}

    init() {
        renderer = MapRenderer()
    }

    // MARK: Pictures

    func apply(_ new: RingLayout, _ transition: RingTransition) {
        let t = x
        let colorT = min(max(x, 0), 1)
        var currentIndex = [UInt64: Int](minimumCapacity: keys.count)
        for i in stride(from: keys.count - 1, through: 0, by: -1) { currentIndex[keys[i]] = i }

        func geometryNow(_ i: Int) -> SIMD4<Float> { instances[i].from + (instances[i].to - instances[i].from) * t }
        func colorNow(_ i: Int) -> SIMD4<Float> { instances[i].colorFrom + (instances[i].colorTo - instances[i].colorFrom) * colorT }

        var enterMapping: ZoomMapping?
        var exitMapping: ZoomMapping?
        var appearing = false
        switch transition {
        case .appear: appearing = true
        case .zoomIn(let m): exitMapping = m
        case .zoomOut(let m): enterMapping = m
        default: break
        }

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
            var plannedFrom = p.planned
            if let i = currentIndex[p.key], !appearing {
                from = geometryNow(i)
                colorFrom = colorNow(i)
                plannedFrom = instances[i].plan.x + (instances[i].plan.y - instances[i].plan.x) * colorT
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
            out.append(SegmentGPU(from: from, to: to, colorFrom: colorFrom, colorTo: colorTo, params: SIMD4(p.style, p.seed, p.calm, 0),
                                  plan: SIMD4(plannedFrom, p.planned, 0, 0)))
            outKeys.append(p.key)
            outParents.append(p.parent)
        }
        pieceCount = out.count

        // Whatever isn't in the new picture leaves: into the piece that survives it, or carried off by the zoom.
        if !appearing {
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
                let leaving = instances[i].plan.x + (instances[i].plan.y - instances[i].plan.x) * colorT
                out.append(SegmentGPU(from: g, to: to, colorFrom: nowColor, colorTo: SIMD4(nowColor.x, nowColor.y, nowColor.z, 0), params: instances[i].params,
                                      plan: SIMD4(leaving, leaving, 0, 0)))
                outKeys.append(keys[i])
                outParents.append(-1)
            }
        }

        var isLive = false
        if case .live = transition { isLive = true }
        var nextNow = [Float](repeating: 0, count: out.count)
        var nextGoal = nextNow
        if isLive {
            // New numbers shouldn't disturb what you're pointing at.
            for i in 0..<pieceCount {
                if let old = currentIndex[outKeys[i]], old < emphasisNow.count {
                    nextNow[i] = emphasisNow[old]
                    nextGoal[i] = emphasisGoal[old]
                }
            }
        } else {
            dimGoal = 0
        }

        instances = out
        keys = outKeys
        parents = outParents
        layout = new
        renderer?.setInstances(instances)
        emphasisNow = nextNow
        emphasisGoal = nextGoal
        renderer?.writeEmphasis(emphasisNow)

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
        case .settle: setSpring(stiffness: 80, dampingRatio: 1)
        }
        velocity = min(carried, stiffness.squareRoot())
        requestFrame()
    }

    private func setSpring(stiffness k: Float, dampingRatio: Float) {
        stiffness = k
        damping = 2 * k.squareRoot() * dampingRatio
    }

    // MARK: Emphasis

    /// Lifts these pieces and lets the rest step back. Pass nothing to bring everything back.
    func setEmphasis(primary: Int?, related: [Range<Int>], ancestors: [Int] = []) {
        guard !emphasisGoal.isEmpty else { return }
        for i in emphasisGoal.indices { emphasisGoal[i] = 0 }
        for range in related {
            for i in range where i < pieceCount { emphasisGoal[i] = 1 }
        }
        for i in ancestors where i < pieceCount { emphasisGoal[i] = max(emphasisGoal[i], 0.62) }
        if let primary, primary < pieceCount { emphasisGoal[primary] = 2 }
        dimGoal = (primary != nil || !related.isEmpty) ? 0.62 : 0
        requestFrame()
    }

    /// How far colour and glow hold back until you point at something, from none to all.
    func setCalm(_ amount: Float) {
        calmGoal = amount
        requestFrame()
    }

    /// The bytes a cleanup would free, shown as a ghost growing out of the free wedge.
    func setGhost(_ share: Float) {
        ghostGoal = share
        requestFrame()
    }

    /// Its colours: where each one ends, as a share of the whole.
    func setGhostColours(_ slices: [(end: Float, color: SIMD3<Float>)]) {
        ghostSlices = Array(slices.prefix(Self.ghostSliceLimit))
        requestFrame()
    }

    /// What the thing you're pointing at would add to it.
    func setPreview(_ share: Float, color: SIMD3<Float>) {
        previewGoal = share
        if share > 0 { previewColor = color }
        requestFrame()
    }

    // MARK: Geometry on screen

    func setGoal(center: CGPoint, radius: CGFloat, animated: Bool) {
        centerGoal = SIMD2(Float(center.x), Float(center.y))
        radiusGoal = Float(radius)
        if !animated || radiusNow == 0 {
            centerNow = centerGoal
            radiusNow = radiusGoal
        }
        requestFrame()
    }

    // MARK: Frames

    /// Moves everything on by `dt` seconds. Returns true while anything is still moving.
    func advance(dt rawDT: Float) -> Bool {
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
                renderer?.setInstances(instances)
                renderer?.writeEmphasis(emphasisNow)
            }
            moving = true
        }

        let rise = 1 - exp(-dt * 34), fall = 1 - exp(-dt * 13)
        var emphasisChanged = false
        for i in emphasisNow.indices {
            let goal = emphasisGoal[i], now = emphasisNow[i]
            if abs(goal - now) > 0.002 {
                emphasisNow[i] = now + (goal - now) * (goal > now ? rise : fall)
                emphasisChanged = true
            } else if now != goal {
                emphasisNow[i] = goal
                emphasisChanged = true
            }
        }
        if emphasisChanged {
            renderer?.writeEmphasis(emphasisNow)
            moving = true
        }

        if abs(dimGoal - dimNow) > 0.002 {
            dimNow += (dimGoal - dimNow) * (dimGoal > dimNow ? rise : fall)
            moving = true
        } else if dimNow != dimGoal {
            dimNow = dimGoal
            moving = true
        }

        let ease = 1 - exp(-dt * 13)
        if abs(radiusGoal - radiusNow) > 0.03 || simd_length(centerGoal - centerNow) > 0.03 {
            radiusNow += (radiusGoal - radiusNow) * ease
            centerNow += (centerGoal - centerNow) * ease
            moving = true
        } else if radiusNow != radiusGoal || centerNow != centerGoal {
            radiusNow = radiusGoal
            centerNow = centerGoal
            moving = true
        }

        if abs(calmGoal - calmNow) > 0.002 {
            calmNow += (calmGoal - calmNow) * ease
            moving = true
        } else if calmNow != calmGoal {
            calmNow = calmGoal
            moving = true
        }

        if abs(previewGoal - previewNow) > 0.0002 {
            previewNow += (previewGoal - previewNow) * ease
            moving = true
        } else if previewNow != previewGoal {
            previewNow = previewGoal
            moving = true
        }
        if abs(ghostGoal - ghostNow) > 0.0002 {
            ghostNow += (ghostGoal - ghostNow) * ease
            moving = true
        } else if ghostNow != ghostGoal {
            ghostNow = ghostGoal
            moving = true
        }
        return moving
    }

    func uniforms(viewport: CGSize, scale: CGFloat, headroom: CGFloat) -> UniformsGPU {
        var u = UniformsGPU()
        u.viewport = SIMD2(Float(viewport.width), Float(viewport.height))
        u.center = centerNow * Float(scale)
        u.radius = radiusNow * Float(scale)
        u.t = x
        u.scale = Float(scale)
        u.dim = dimNow
        u.liftPixels = Float(scale) * 5
        u.bloom = 1
        u.restSaturation = 1 - calmNow * (1 - Self.colourAtRest)
        u.glowAtRest = 1 - calmNow * (1 - Self.glowAtRest)
        u.headroom = Float(headroom)
        if let free = layout.pieces.first(where: { $0.style == 1 }) {
            u.ghost = ghostNow
            u.freeStart = free.a0
            u.freeOuter = free.r1
            u.previewShare = previewNow
            u.previewColor = SIMD4(previewColor, 0)
            u.ghostCount = Float(ghostSlices.count)
            withUnsafeMutableBytes(of: &u.ghostSlices) { raw in
                let slots = raw.bindMemory(to: SIMD4<Float>.self)
                for (at, slice) in ghostSlices.enumerated() where at < slots.count { slots[at] = SIMD4(slice.color, slice.end) }
            }
        }
        return u
    }
}
