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

    /// Where the first branch starts (`SunburstHues.first`).
    @available(*, deprecated, renamed: "SunburstHues.first")
    public static var firstHue: Float { SunburstHues.first }
    /// How far round the wheel each next branch's hue is (`SunburstHues.step`).
    @available(*, deprecated, renamed: "SunburstHues.step")
    public static var goldenAngle: Float { SunburstHues.step }
    /// A branch won't take a colour this close to the one before it on the ring (`SunburstHues.neighbourGap`).
    @available(*, deprecated, renamed: "SunburstHues.neighbourGap")
    public static var neighbourGap: Float { SunburstHues.neighbourGap }
    /// What anything without a colour of its own, or quiet, is drawn in: slate.
    public static var quiet: Lab { Lab(lch: 0.38, 0.014, 255) }

    /// The hue of the branch at this place in the order.
    @available(*, deprecated, renamed: "SunburstHues.hue")
    public static func hue(_ index: Int) -> Float { SunburstHues.hue(index) }

    /// How far apart two hues are round the wheel, in degrees.
    @available(*, deprecated, renamed: "SunburstHues.apart")
    public static func apart(_ x: Float, _ y: Float) -> Float { SunburstHues.apart(x, y) }

    /// Nothing painted yet: paint branches yourself. Nothing smaller than `smallest` is painted, since it can't be drawn on
    /// its own: 1/4000 of the node in the middle is about right.
    public init(tree: Tree, smallest: UInt64) {
        self.tree = tree
        self.smallest = smallest
        colours.reserveCapacity(2048)
    }

    /// Every branch in view painted, biggest first: what's directly in the node in the middle, each with the palette's next
    /// colour that isn't close to the one before it. A branch under `quietBelow` of the node in the middle is quiet slate
    /// instead, so the eye goes to the big ones and the ring isn't a rainbow of slivers; 0 gives every branch a colour.
    public init(tree: Tree, focus: UInt32 = 0, palette: SunburstPalette = .spectrum, quietBelow: Double = 0.015) {
        self.init(tree: tree, smallest: tree.size(of: focus) / 4000)
        var previous: Int?
        var next = 0
        let quiet = Double(tree.size(of: focus)) * quietBelow
        for item in RingLayout.visibleChildren(tree: tree, of: focus).kids where tree.size(of: item) > smallest {
            if tree.role(of: item).isSpace { continue }
            if Double(tree.size(of: item)) < quiet {
                paint(item, colour: Lab(lch: 0.46, 0.032, 255))
                continue
            }
            while previous.map({ palette.tooClose(next, $0) }) == true { next += 1 }
            previous = next
            paint(item, palette: palette, index: next)
            next += 1
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

    /// A branch in a set colour: the node in `colour`, and everything in it a little lighter each ring out and drifting a
    /// little around its hue, as `paint(_:hue:)` does, but keeping the colour's own lightness and chroma.
    public mutating func paint(_ id: UInt32, colour: Lab, depth: Int = 0, step: Int = 0) {
        let isFile = !tree.isFolder(id)
        let hue = atan2(colour.b, colour.a) * 180 / .pi
        var lightness = colour.l + 0.022 * Float(depth) + (step % 2 == 0 ? 0.018 : -0.018)
        var strength = max(1 - 0.05 * Float(depth), 0.7)
        if isFile {
            lightness += 0.07
            strength = min(strength * 1.12, 1.03)
        }
        colours[id] = Lab(lch: min(lightness, 0.93), strength * colour.chroma, hue)

        guard !isFile, tree.firstChild(of: id) != 0, depth < branchDrift.count else { return }
        let reach = branchDrift[depth]
        let parentSize = Float(max(tree.size(of: id), 1))
        var before: UInt64 = 0
        var index = 0
        var c = tree.firstChild(of: id)
        while c != 0 {
            let size = tree.size(of: c)
            if size <= smallest { break }
            let middle = (Float(before) + Float(size) / 2) / parentSize
            paint(c, colour: Lab(lch: colour.l, colour.chroma, hue + (middle - 0.5) * 2 * reach), depth: depth + 1, step: index)
            before &+= size
            index += 1
            c = tree.nextSibling(of: c)
        }
    }

    /// A branch in the colour at this place in a palette's order.
    public mutating func paint(_ id: UInt32, palette: SunburstPalette, index: Int) {
        switch palette.kind {
        case .dynamic: paint(id, hue: palette.hue(index))
        case .fixed: paint(id, colour: palette.colour(index))
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

/// The hues branches take, in order round the wheel: each next one a golden angle further on, so branches next to each
/// other in the list are always far apart in colour, and however many there are, they fill the wheel evenly.
public enum SunburstHues {
    /// Where the first branch starts, in degrees.
    public static let first: Float = 298
    /// How far round the wheel each next one is: the golden angle, in degrees.
    public static let step: Float = 137.508
    /// A branch won't take a hue this close to the one before it on the ring.
    public static let neighbourGap: Float = 50

    /// The hue of the branch at this place in the order.
    public static func hue(_ index: Int) -> Float { first + Float(index) * step }

    /// How far apart two hues are round the wheel, in degrees: this far or more reads as different colours.
    public static func apart(_ x: Float, _ y: Float) -> Float {
        let d = abs(x - y).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }
}

/// The colours branches take, in order: generated from a range of hues (dynamic), or a set list of colours (fixed). Depth,
/// drift and the quiet slate of what belongs to the system work the same in every palette.
public struct SunburstPalette: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// Generated: hues spread over `from` through `through` degrees (past 360 to wrap), each at its best lightness.
        case dynamic(from: Float, through: Float)
        /// These colours in order, then again from the first, as OKLab lightness, a and b.
        case fixed([SIMD3<Float>])
    }

    /// A short, stable name, for keeping a choice and for menus.
    public let id: String
    public let name: String
    public let kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    /// A fixed palette of these colours, in order.
    public static func fixed(id: String, name: String, _ colours: [Lab]) -> SunburstPalette {
        SunburstPalette(id: id, name: name, kind: .fixed(colours.map { SIMD3($0.l, $0.a, $0.b) }))
    }

    /// The hue at this place in a dynamic palette's order. The whole wheel steps a golden angle at a time
    /// (`SunburstHues`); a range is filled evenly the same way.
    public func hue(_ index: Int) -> Float {
        switch kind {
        case .dynamic(let from, let through):
            let span = through - from
            if span >= 359.9 { return SunburstHues.hue(index) }
            let place = (0.5 + Float(index) * 0.618034).truncatingRemainder(dividingBy: 1)
            return from + span * place
        case .fixed:
            return atan2(colour(index).b, colour(index).a) * 180 / .pi
        }
    }

    /// The colour at this place in the order, as it's drawn for the first ring.
    public func colour(_ index: Int) -> Lab {
        switch kind {
        case .dynamic:
            let h = hue(index), l = Lab.spectrumLightness(h)
            return Lab(lch: l, 0.95 * Lab.strongestChroma(lightness: l, hue: h), h)
        case .fixed(let colours):
            guard !colours.isEmpty else { return Lab(lch: 0.38, 0.014, 255) }
            let c = colours[((index % colours.count) + colours.count) % colours.count]
            return Lab(l: c.x, a: c.y, b: c.z)
        }
    }

    /// Whether the colours at two places in the order are too alike to sit next to each other on the ring.
    public func tooClose(_ i: Int, _ j: Int) -> Bool {
        switch kind {
        case .dynamic(let from, let through):
            return SunburstHues.apart(hue(i), hue(j)) < min(SunburstHues.neighbourGap, (through - from) * 0.2)
        case .fixed(let colours):
            return colours.count > 1 && (i - j) % colours.count == 0
        }
    }

    /// Each branch its own hue from the whole wheel, a golden angle from the one before: the default.
    public static let spectrum = SunburstPalette(id: "spectrum", name: "Spectrum", kind: .dynamic(from: 0, through: 360))
    /// Teal through blue and violet to magenta.
    public static let cool = SunburstPalette(id: "cool", name: "Cool", kind: .dynamic(from: 165, through: 330))
    /// Rose through red and orange to amber.
    public static let warm = SunburstPalette(id: "warm", name: "Warm", kind: .dynamic(from: 345, through: 455))
    /// Okabe and Ito's colours, told apart with any colour vision.
    public static let colourBlindSafe = fixed(id: "okabe-ito", name: "Colour-Blind Safe", [
        Lab(lch: 0.753, 0.158, 76.8),   // orange
        Lab(lch: 0.735, 0.117, 236.2),  // sky blue
        Lab(lch: 0.621, 0.170, 47.5),   // vermillion
        Lab(lch: 0.620, 0.130, 165.5),  // bluish green
        Lab(lch: 0.679, 0.118, 346.3),  // reddish purple
        Lab(lch: 0.902, 0.172, 105.0),  // yellow
        Lab(lch: 0.532, 0.131, 244.0),  // blue
    ])
    /// Soft, light colours.
    public static let pastel = fixed(id: "pastel", name: "Pastel", [
        Lab(lch: 0.80, 0.085, 20), Lab(lch: 0.82, 0.075, 200), Lab(lch: 0.86, 0.080, 95), Lab(lch: 0.78, 0.085, 300),
        Lab(lch: 0.84, 0.075, 150), Lab(lch: 0.82, 0.080, 60), Lab(lch: 0.78, 0.080, 250),
    ])
    /// One blue, told apart by lightness.
    public static let mono = fixed(id: "mono", name: "Mono", [
        Lab(lch: 0.64, 0.12, 258), Lab(lch: 0.78, 0.09, 252), Lab(lch: 0.54, 0.13, 262), Lab(lch: 0.71, 0.11, 255),
        Lab(lch: 0.85, 0.07, 248), Lab(lch: 0.58, 0.12, 260),
    ])

    /// The palettes the kit comes with, dynamic first.
    public static let all: [SunburstPalette] = [.spectrum, .cool, .warm, .colourBlindSafe, .pastel, .mono]
}

/// Which hue each branch has, by name, kept from one picture to the next so a branch keeps its colour however sizes
/// change. The app keeps `indices` between launches; it's a plain dictionary of name to place in `SunburstHues`' order.
public struct HueMemory: Sendable, Equatable {
    public private(set) var indices: [String: Int]
    /// Whether a branch was given a hue it didn't have, so the memory needs keeping again.
    public private(set) var changed = false
    private var used: Set<Int>

    public init(_ indices: [String: Int] = [:]) {
        self.indices = indices
        used = Set(indices.values)
    }

    /// The hue for a branch called `name`, next on the ring after one in `previous`: the hue it had, or else the first free
    /// one that isn't close to the one before it.
    public mutating func hue(for name: String, after previous: Float?) -> Float {
        if let known = indices[name] { return SunburstHues.hue(known) }
        var next = 0
        while used.contains(next) || previous.map({ SunburstHues.apart(SunburstHues.hue(next), $0) < SunburstHues.neighbourGap }) == true {
            next += 1
        }
        indices[name] = next
        used.insert(next)
        changed = true
        return SunburstHues.hue(next)
    }

    /// The place in a palette's order for a branch called `name`, next on the ring after the one at `previous`: the place it
    /// had, or else the first free one whose colour isn't close to the one before it. Paint it with
    /// `BranchColours.paint(_:palette:index:)`.
    public mutating func index(for name: String, after previous: Int?, in palette: SunburstPalette) -> Int {
        if let known = indices[name] { return known }
        var next = 0
        while used.contains(next) || previous.map({ palette.tooClose(next, $0) }) == true { next += 1 }
        indices[name] = next
        used.insert(next)
        changed = true
        return next
    }
}
