import Foundation

/// Which colour each folder has in each view, kept between launches, so a folder keeps its colour however sizes change.
@MainActor
final class ColourMemory {
    private var views: [String: [String: Int]]
    private var unsaved = false
    private let file: URL

    init() {
        file = AppData.folder.appendingPathComponent("colours.json")
        views = (try? JSONDecoder().decode([String: [String: Int]].self, from: Data(contentsOf: file))) ?? [:]
    }

    func view(_ key: String) -> [String: Int] { views[key] ?? [:] }

    func set(_ key: String, _ value: [String: Int]) {
        views[key] = value
        unsaved = true
    }

    /// Only a finished scan is saved. While a scan is still running, folders get colours in the order they turn up.
    func saveIfNeeded() {
        guard unsaved else { return }
        unsaved = false
        let copy = views, target = file
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(copy) { try? data.write(to: target, options: .atomic) }
        }
    }
}

/// Colour that shows structure, so you can read the picture at a glance. Each big thing in view has its own colour from
/// the whole spectrum, and everything inside it stays close to that colour, so one group reads as one wedge from the
/// middle to the edge. Hue drifts a little around each wedge, and gets lighter going out, so you can see how deep it goes.
struct RingColours {
    private let tree: DiskTree
    private var colors: [UInt32: Lab] = [:]
    /// Too small to be drawn on its own, so there's no need to work out a colour.
    private let smallest: UInt64

    /// Where the first thing starts. Each next one is a golden angle further on, so things that came one after another are
    /// always far apart in colour, and however many there are, they fill the wheel evenly.
    private static let firstHue: Float = 298
    private static let goldenAngle: Float = 137.508
    /// A new folder won't take a colour this close to the piece before it on the ring.
    private static let neighbourGap: Float = 50
    /// How far hue may drift either way inside a wedge, by depth.
    private static let drift: [Float] = [20, 12, 7, 4, 3, 2, 2, 2]

    @MainActor
    init(tree: DiskTree, focus: UInt32, memory: ColourMemory) {
        self.tree = tree
        let total = tree.totals[Int(focus)]
        smallest = total / 4000
        colors.reserveCapacity(2048)

        var items: [UInt32] = []
        if focus == 0 {
            // On the whole disk, the things you recognise are one level down, in your files. The system stays quiet slate,
            // because none of it is yours to look through.
            for child in tree.children(0) where child != tree.free && child != tree.hidden {
                if child == tree.home || (tree.home == 0 && tree.nodes[Int(child)].has(NodeFlag.directory)) {
                    colors[child] = Lab(lch: 0.50, 0.035, 285)
                    items += tree.children(child)
                } else if tree.nodes[Int(child)].has(NodeFlag.synthetic) {
                    paintQuietly(child, depth: 0)
                } else {
                    items.append(child)
                }
            }
            let totals = tree.totals
            items.sort { totals[Int($0)] > totals[Int($1)] }
        } else {
            items = RingLayout.visibleChildren(tree: tree, of: focus).kids
        }
        // A folder that already has a colour keeps it. A new one takes the next free colour, unless that would nearly match
        // the piece before it. With nothing remembered yet, that gives the biggest thing the first colour, and so on down.
        let key = focus == 0 ? tree.rootPath : (tree.path(focus) ?? tree.name(focus))
        var known = memory.view(key)
        var used = Set(known.values)
        var changed = false
        var previous: Float?
        for item in items where tree.totals[Int(item)] > smallest {
            let n = tree.nodes[Int(item)]
            let name = String(decoding: UnsafeBufferPointer(start: tree.names + Int(n.nameOffset), count: Int(n.nameLength)), as: UTF8.self)
            var index = known[name]
            if index == nil {
                var next = 0
                while used.contains(next) || previous.map({ Self.apart(Self.hue(next), $0) < Self.neighbourGap }) == true { next += 1 }
                index = next
                known[name] = next
                used.insert(next)
                changed = true
            }
            let hue = Self.hue(index ?? 0)
            previous = hue
            paint(item, hue: hue, depth: 0, step: 0)
        }
        if changed { memory.set(key, known) }
        if !tree.isPartial { memory.saveIfNeeded() }
    }

    private static func hue(_ index: Int) -> Float { firstHue + Float(index) * goldenAngle }

    private static func apart(_ x: Float, _ y: Float) -> Float {
        let d = abs(x - y).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    /// The colour of a piece. Whatever is too small to have its own takes its folder's.
    func lab(_ node: UInt32) -> Lab {
        var at = node
        while true {
            if let found = colors[at] { return found }
            if at == 0 { return Palette.color(.system) }
            at = tree.nodes[Int(at)].parent
        }
    }

    private mutating func paint(_ id: UInt32, hue: Float, depth: Int, step: Int) {
        let n = tree.nodes[Int(id)]
        let bytes = tree.totals[Int(id)]
        let isFile = !n.has(NodeFlag.directory)
        // This is how it looks when you point at it. Until then the renderer holds it back a step.
        let base = Palette.spectrumLightness(hue)
        var lightness = base + 0.022 * Float(depth) + (step % 2 == 0 ? 0.018 : -0.018)
        var strength = 0.95 * max(1 - 0.05 * Float(depth), 0.7)
        if isFile {
            // A file is the end of the line, and a big one should jump out.
            lightness += 0.07
            strength = min(strength * 1.12, 0.98)
        }
        // Strength is measured at the hue's own lightness. Measured further out, where the screen has less room for
        // colour, the outer rings would fade to cream.
        colors[id] = Lab(lch: min(lightness, 0.93), strength * Palette.strongestChroma(lightness: base, hue: hue), hue)

        guard !isFile, n.firstChild != 0, depth < Self.drift.count else { return }
        let reach = Self.drift[depth]
        let parentBytes = Float(max(bytes, 1))
        var before: UInt64 = 0
        var index = 0
        var c = n.firstChild
        while c != 0 {
            let size = tree.totals[Int(c)]
            if size <= smallest { break }       // children are sorted, so the rest are smaller still
            let middle = (Float(before) + Float(size) / 2) / parentBytes
            paint(c, hue: hue + (middle - 0.5) * 2 * reach, depth: depth + 1, step: index)
            before &+= size
            index += 1
            c = tree.nodes[Int(c)].nextSibling
        }
    }

    /// macOS and the like: slate, with just enough difference to see the pieces apart.
    private mutating func paintQuietly(_ id: UInt32, depth: Int) {
        colors[id] = Lab(lch: 0.38 + 0.03 * Float(depth), 0.014, 255)
        var c = tree.nodes[Int(id)].firstChild
        while c != 0, tree.totals[Int(c)] > smallest {
            paintQuietly(c, depth: depth + 1)
            c = tree.nodes[Int(c)].nextSibling
        }
    }
}
