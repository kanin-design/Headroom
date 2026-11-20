import Foundation
import SwiftUI
import simd

/// Colour in OKLab, which mixes and steps the way the eye expects. Everything ends up in linear Display P3.
public struct Lab: Sendable {
    /// Lightness from 0 to 1, and the two colour axes: green to red, and blue to yellow.
    public var l: Float, a: Float, b: Float

    public init(l: Float, a: Float, b: Float) { self.l = l; self.a = a; self.b = b }

    /// Lightness, chroma and hue in degrees.
    public init(lch l: Float, _ c: Float, _ h: Float) {
        self.l = l
        a = c * cos(h * .pi / 180)
        b = c * sin(h * .pi / 180)
    }

    /// How colourful it is: the distance from grey.
    public var chroma: Float { (a * a + b * b).squareRoot() }

    /// The colour in linear Display P3, as a layout's colorer gives it, kept to what a screen can show.
    public var linearP3: SIMD3<Float> {
        let c = unclampedP3
        return SIMD3(max(c.x, 0), max(c.y, 0), max(c.z, 0))
    }

    /// Outside 0...1 means the screen can't show this colour.
    public var unclampedP3: SIMD3<Float> {
        let L = l + 0.3963377774 * a + 0.2158037573 * b
        let M = l - 0.1055613458 * a - 0.0638541728 * b
        let S = l - 0.0894841775 * a - 1.2914855480 * b
        let lc = L * L * L, mc = M * M * M, sc = S * S * S
        let x = 1.2270138511 * lc - 0.5577999807 * mc + 0.2812561490 * sc
        let y = -0.0405801784 * lc + 1.1122568696 * mc - 0.0716766787 * sc
        let z = -0.0763812845 * lc - 0.4214819784 * mc + 1.5861632204 * sc
        let r = 2.4934969 * x - 0.9313836 * y - 0.4027108 * z
        let g = -0.8294890 * x + 1.7626641 * y + 0.0236247 * z
        let bl = 0.0358458 * x - 0.0761724 * y + 0.9568845 * z
        return SIMD3(r, g, bl)
    }

    /// The same colour for SwiftUI, so that panels and the ring match exactly.
    public var swiftUI: Color {
        func encode(_ v: Float) -> Double {
            let x = min(max(v, 0), 1)
            return Double(x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055)
        }
        let c = linearP3
        return Color(.displayP3, red: encode(c.x), green: encode(c.y), blue: encode(c.z))
    }

    /// The colour `t` of the way from `x` to `y`.
    public static func mix(_ x: Lab, _ y: Lab, _ t: Float) -> Lab {
        Lab(l: x.l + (y.l - x.l) * t, a: x.a + (y.a - x.a) * t, b: x.b + (y.b - x.b) * t)
    }
}

public extension Lab {
    /// Around the wheel, each hue at its own best lightness: yellow can only look yellow when it's light, and blue only looks
    /// blue when it's deep.
    static func spectrumLightness(_ hue: Float) -> Float {
        var h = hue.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        let stops = spectrumStops
        var from = stops[stops.count - 1], to = stops[0]
        var position = h < stops[0].h ? h + 360 : h
        var start = from.h
        var end = to.h + 360
        for i in 0..<stops.count - 1 where h >= stops[i].h && h < stops[i + 1].h {
            from = stops[i]
            to = stops[i + 1]
            start = from.h
            end = to.h
            position = h
        }
        return from.l + (to.l - from.l) * (position - start) / (end - start)
    }

    private static let spectrumStops: [(h: Float, l: Float)] = [
        (25, 0.66), (60, 0.74), (95, 0.86), (130, 0.82), (158, 0.80), (195, 0.78), (235, 0.68), (265, 0.58), (298, 0.58),
        (330, 0.62), (355, 0.66),
    ]

    /// The strongest colour a Display P3 screen can show at this lightness and hue.
    static func strongestChroma(lightness l: Float, hue h: Float) -> Float {
        var low: Float = 0, high: Float = 0.4
        for _ in 0..<9 {
            let middle = (low + high) / 2
            let c = Lab(lch: l, middle, h).unclampedP3
            if min(c.x, c.y, c.z) < 0 || max(c.x, c.y, c.z) > 1 { high = middle } else { low = middle }
        }
        return low
    }
}

/// How far hue may drift either way inside a wedge, by depth.
private let branchDrift: [Float] = [20, 12, 7, 4, 3, 2, 2, 2]

/// Colour that shows structure, so a picture can be read at a glance. Each big thing in view gets its own colour from the
/// whole spectrum, and everything inside it stays close to that colour, so one branch reads as one wedge from the middle to
/// the edge. Hue drifts a little around each wedge, and gets lighter going out, so you can see how deep it goes.
///
/// `BranchColours(tree:focus:).colorer` is a good `RingLayout.Colorer` for any tree. A host with rules of its own can paint
/// branches one by one with `paint(_:hue:)`, `paintQuietly(_:)` and `set(_:_:)`.
public struct BranchColours<Tree: SunburstTree> {
    private let tree: Tree
    private var colours: [UInt32: Lab] = [:]
    /// Too small to be drawn on its own, so there's no need to work out a colour.
    private let smallest: UInt64

    /// Where the first branch starts. Each next one is a golden angle further on, so branches next to each other in the
    /// list are always far apart in colour, and however many there are, they fill the wheel evenly.
    public static var firstHue: Float { 298 }
    /// How far round the wheel each next branch's hue is: the golden angle, in degrees.
    public static var goldenAngle: Float { 137.508 }
    /// A branch won't take a colour this close to the one before it on the ring.
    public static var neighbourGap: Float { 50 }
    /// What anything without a colour of its own, or quiet, is drawn in: slate.
    public static var quiet: Lab { Lab(lch: 0.38, 0.014, 255) }

    /// The hue of the branch at this place in the order.
    public static func hue(_ index: Int) -> Float { firstHue + Float(index) * goldenAngle }

    /// Hues that are this far apart, or more, read as different colours.
    public static func apart(_ x: Float, _ y: Float) -> Float {
        let d = abs(x - y).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    /// Nothing painted yet: paint branches yourself. Nothing smaller than `smallest` is painted, since it can't be drawn on
    /// its own: 1/4000 of the node in the middle is about right.
    public init(tree: Tree, smallest: UInt64) {
        self.tree = tree
        self.smallest = smallest
        colours.reserveCapacity(2048)
    }

    /// Every branch in view painted, biggest first: what's directly in the node in the middle, each with the next colour that
    /// isn't close to the one before it.
    public init(tree: Tree, focus: UInt32 = 0) {
        self.init(tree: tree, smallest: tree.size(of: focus) / 4000)
        var previous: Float?
        var next = 0
        for item in RingLayout.visibleChildren(tree: tree, of: focus).kids where tree.size(of: item) > smallest {
            if tree.style(of: item) == .free || tree.style(of: item) == .hidden { continue }
            while previous.map({ Self.apart(Self.hue(next), $0) < Self.neighbourGap }) == true { next += 1 }
            let hue = Self.hue(next)
            previous = hue
            next += 1
            paint(item, hue: hue)
        }
    }

    /// The colour of a node. Whatever is too small to have its own takes its folder's.
    public func lab(_ node: UInt32) -> Lab {
        var at = node
        while true {
            if let found = colours[at] { return found }
            if at == 0 { return Self.quiet }
            at = tree.parent(of: at)
        }
    }

    /// The colours as a layout wants them.
    public var colorer: RingLayout.Colorer {
        let colours = self
        return { colours.lab($0).linearP3 }
    }

    /// One colour for a node, and nothing under it.
    public mutating func set(_ node: UInt32, _ colour: Lab) {
        colours[node] = colour
    }

    /// A branch in this hue: the node, and everything in it, each a little lighter than what holds it and drifting a little
    /// around the hue by where it sits.
    public mutating func paint(_ id: UInt32, hue: Float, depth: Int = 0, step: Int = 0) {
        let isFile = !tree.isFolder(id)
        // This is how it looks when it's pointed at. Until then the renderer holds it back a step.
        let base = Lab.spectrumLightness(hue)
        var lightness = base + 0.022 * Float(depth) + (step % 2 == 0 ? 0.018 : -0.018)
        var strength = 0.95 * max(1 - 0.05 * Float(depth), 0.7)
        if isFile {
            // The end of the line, and a big one should jump out.
            lightness += 0.07
            strength = min(strength * 1.12, 0.98)
        }
        // Strength is measured at the hue's own lightness. Measured further out, where the screen has less room for
        // colour, the outer rings would fade to cream.
        colours[id] = Lab(lch: min(lightness, 0.93), strength * Lab.strongestChroma(lightness: base, hue: hue), hue)

        guard !isFile, tree.firstChild(of: id) != 0, depth < branchDrift.count else { return }
        let reach = branchDrift[depth]
        let parentSize = Float(max(tree.size(of: id), 1))
        var before: UInt64 = 0
        var index = 0
        var c = tree.firstChild(of: id)
        while c != 0 {
            let size = tree.size(of: c)
            if size <= smallest { break }       // children are biggest first, so the rest are smaller still
            let middle = (Float(before) + Float(size) / 2) / parentSize
            paint(c, hue: hue + (middle - 0.5) * 2 * reach, depth: depth + 1, step: index)
            before &+= size
            index += 1
            c = tree.nextSibling(of: c)
        }
    }

    /// A branch in quiet slate, with just enough difference to tell the pieces apart, such as what belongs to the system.
    public mutating func paintQuietly(_ id: UInt32, depth: Int = 0) {
        colours[id] = Lab(lch: 0.38 + 0.03 * Float(depth), 0.014, 255)
        var c = tree.firstChild(of: id)
        while c != 0, tree.size(of: c) > smallest {
            paintQuietly(c, depth: depth + 1)
            c = tree.nextSibling(of: c)
        }
    }
}
