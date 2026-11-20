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
        Saves.write(copy, to: target)
    }
}

/// Colour that shows structure, so you can read the picture at a glance: SunburstKit's `BranchColours`, with the disk's own
/// rules. On the whole disk your files come first and the system stays quiet slate, and a folder keeps the colour it had,
/// however sizes change.
struct RingColours {
    private var branches: BranchColours<DiskTree>

    @MainActor
    init(tree: DiskTree, focus: UInt32, memory: ColourMemory) {
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
        typealias Colours = BranchColours<DiskTree>
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
                while used.contains(next) || previous.map({ Colours.apart(Colours.hue(next), $0) < Colours.neighbourGap }) == true { next += 1 }
                index = next
                known[name] = next
                used.insert(next)
                changed = true
            }
            let hue = Colours.hue(index ?? 0)
            previous = hue
            branches.paint(item, hue: hue)
        }
        if changed { memory.set(key, known) }
        if !tree.isPartial { memory.saveIfNeeded() }
    }

    /// The colour of a piece. Whatever is too small to have its own takes its folder's.
    func lab(_ node: UInt32) -> Lab { branches.lab(node) }
}
