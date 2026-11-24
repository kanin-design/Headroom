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
    fileprivate func saveIfNeeded() {
        guard unsaved else { return }
        unsaved = false
        let copy = views, target = file
        Saves.write(copy, to: target)
    }
}

/// Colour that shows structure, so you can read the picture at a glance: SunburstKit's `BranchColours`, with the disk's own
/// rules. On the whole disk your files come first and the system stays quiet slate, and a folder keeps the colour it had,
/// however sizes change.
struct RingColours {
    private var branches: BranchColours<DiskTree>

    @MainActor
    init(tree: DiskTree, focus: UInt32, memory: ColourMemory, palette: SunburstPalette = .spectrum) {
        let total = tree.totals[Int(focus)]
        let smallest = total / 4000
        branches = BranchColours(tree: tree, smallest: smallest)

        var items: [UInt32] = []
        if focus == 0 {
            // On the whole disk, the things you recognise are one level down, in your files. The system stays quiet slate,
            // because none of it is yours to look through.
            for child in tree.children(0) where child != tree.free && child != tree.hidden {
                if child == tree.home || (!tree.isBoot && tree.nodes[Int(child)].has(NodeFlag.directory)) {
                    branches.set(child, Lab(lch: 0.50, 0.035, 285))
                    items += tree.children(child)
                } else if tree.nodes[Int(child)].has(NodeFlag.synthetic) {
                    branches.paintQuietly(child)
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
        // Each palette keeps its own: a place in one palette's order means nothing in another's.
        let place = focus == 0 ? tree.rootPath : (tree.path(focus) ?? tree.name(focus))
        let key = palette == .spectrum ? place : place + "|" + palette.id
        var hues = HueMemory(memory.view(key))
        var previous: Int?
        // Branches too small to matter at this level are quiet, in a muted tone of what holds them, so the eye goes to the
        // big ones and the ring isn't a rainbow of slivers. They take no colour from the palette's order.
        let quietBelow = Double(total) * Self.quietShare
        for item in items where tree.totals[Int(item)] > smallest {
            if Double(tree.totals[Int(item)]) < quietBelow {
                let held = branches.lab(tree.nodes[Int(item)].parent)
                let hue = held.chroma > 0.01 ? atan2(held.b, held.a) * 180 / .pi : 255
                branches.paint(item, colour: Lab(lch: 0.46, 0.032, hue))
                continue
            }
            let n = tree.nodes[Int(item)]
            let name = String(decoding: UnsafeBufferPointer(start: tree.names + Int(n.nameOffset), count: Int(n.nameLength)), as: UTF8.self)
            let index = hues.index(for: name, after: previous, in: palette)
            previous = index
            branches.paint(item, palette: palette, index: index)
        }
        if hues.changed { memory.set(key, hues.indices) }
        if !tree.isPartial { memory.saveIfNeeded() }
    }

    /// The colour of a piece. Whatever is too small to have its own takes its folder's.
    func lab(_ node: UInt32) -> Lab { branches.lab(node) }

    /// A branch under this share of what's in the middle is drawn quiet rather than in a colour of its own.
    private static let quietShare = 0.015
}
