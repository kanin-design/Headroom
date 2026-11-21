import Foundation

/// Trees for the layout snapshots, as plain data: the same file feeds the kit as it was and the kit as it is, so the
/// two can be compared piece by piece. Nothing here uses the kit's types.
struct FixtureNode {
    enum Kind: UInt8 { case thing, free, hidden, locked, ghost, shared }
    var name: String
    var parent: UInt32
    var children: [UInt32] = []
    var own: UInt64 = 0
    var folder: Bool
    var kind: Kind = .thing
    /// The place a Backup-like tree sorts it by.
    var group: UInt8?
    var growing = false
    var always = false
    /// Stretches the node is cut into: (size, colour index or nil, marked).
    var cuts: [(size: UInt64, color: Int?, marked: Bool)]?
    var half = false
}

struct FixtureData {
    var nodes: [FixtureNode] = [FixtureNode(name: "", parent: 0, folder: true)]
    var halves = false
    var band = false
    var groups = false
    /// Around the root: lower first (`rootRank`).
    var ranks: [UInt32: Int] = [:]
    var totals: [UInt64] = []
    var free: UInt32 = 0
    var hidden: UInt32 = 0

    @discardableResult
    mutating func add(_ name: String, in parent: UInt32, own: UInt64 = 0, folder: Bool, kind: FixtureNode.Kind = .thing) -> UInt32 {
        let id = UInt32(nodes.count)
        nodes.append(FixtureNode(name: name, parent: parent, own: own, folder: folder, kind: kind))
        nodes[Int(parent)].children.append(id)
        return id
    }

    /// Sizes summed up from the leaves, children listed biggest first, ties in the order they were added.
    mutating func finish() {
        totals = nodes.map(\.own)
        for id in stride(from: nodes.count - 1, to: 0, by: -1) { totals[Int(nodes[id].parent)] &+= totals[id] }
        for i in nodes.indices {
            nodes[i].children = nodes[i].children.enumerated().sorted { a, b in
                totals[Int(a.element)] != totals[Int(b.element)] ? totals[Int(a.element)] > totals[Int(b.element)] : a.offset < b.offset
            }.map(\.element)
        }
    }

    func node(named path: String) -> UInt32 {
        var at: UInt32 = 0
        for part in path.split(separator: "/") {
            guard let found = nodes[Int(at)].children.first(where: { nodes[Int($0)].name == part }) else { fatalError("no \(path)") }
            at = found
        }
        return at
    }
}

/// A seeded generator, so every run makes the same trees.
struct FixtureRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    /// Sizes spread like files on a disk: mostly small, a few huge.
    mutating func bytes(_ scale: Double) -> UInt64 { UInt64(scale * pow(10, unit() * 3)) + 1 }
}

enum Fixtures {
    /// A home folder: branches of different depths, chains, a few huge files and many tiny ones.
    static func home(into data: inout FixtureData, at root: UInt32, seed: UInt64, scale: Double = 1) {
        var r = FixtureRandom(state: seed)
        func grow(_ parent: UInt32, depth: Int, budget: Int) {
            let count = depth > 9 ? 0 : 1 + r.below(budget)
            for i in 0..<count {
                let isFolder = depth < 9 && r.unit() < max(0.15, 0.68 - Double(depth) * 0.06)
                if isFolder {
                    let id = data.add("d\(depth)-\(i)", in: parent, folder: true)
                    // Now and then a folder that's nearly all one subfolder, so chains are drawn.
                    if r.unit() < 0.1 {
                        let inner = data.add("only\(depth)", in: id, folder: true)
                        data.add("tiny", in: id, own: r.bytes(scale * 10), folder: false)
                        grow(inner, depth: depth + 2, budget: max(2, budget - 2))
                    } else {
                        grow(id, depth: depth + 1, budget: max(2, budget - 1))
                    }
                } else {
                    data.add("f\(depth)-\(i)", in: parent, own: r.bytes(scale * (r.unit() < 0.02 ? 1200 : 40)), folder: false)
                }
            }
        }
        for (i, name) in ["Videos", "Photos", "Library", "Projects", "Music", "Documents", "Downloads", "Games"].enumerated() {
            let id = data.add(name, in: root, folder: true)
            grow(id, depth: 1, budget: 8 + i % 3)
        }
        // Hundreds of tiny files in one folder: gathered into "smaller items".
        let many = data.add("Cache", in: root, folder: true)
        for i in 0..<300 { data.add("c\(i)", in: many, own: UInt64(10 + i % 7), folder: false) }
    }

    /// A whole disk: your files, apps, the system, what's hidden and what's free, with the thin band around the middle.
    static func disk(partial: Bool = false) -> FixtureData {
        var d = FixtureData()
        d.band = true
        let you = d.add("Your files", in: 0, folder: true)
        home(into: &d, at: you, seed: 7)
        let apps = d.add("Apps", in: 0, folder: true)
        for i in 0..<12 { d.add("App\(i)", in: apps, own: UInt64(20_000 + i * 7_919), folder: false) }
        let system = d.add("System", in: 0, folder: true)
        d.add("macOS", in: system, own: 900_000, folder: false)
        d.add("Updates", in: system, own: 120_000, folder: false)
        // A locked folder deep inside: hatched in its ring, not a wedge.
        let library = d.node(named: "Your files/Library")
        d.add("Locked", in: library, own: 60_000, folder: true, kind: .locked)
        // A file that moved away, drawn from its note; one that's shared.
        let videos = d.node(named: "Your files/Videos")
        d.add("Moved.mov", in: videos, own: 300_000, folder: false, kind: .ghost)
        d.add("Seeding.mkv", in: videos, own: 250_000, folder: false, kind: .shared)
        // Free a quarter of what's used and hidden a twentieth, as on a typical disk.
        let used = d.nodes.reduce(UInt64(0)) { $0 &+ $1.own }
        d.hidden = d.add("Hidden", in: 0, own: used / 20, folder: false, kind: .hidden)
        d.free = d.add("Free", in: 0, own: used / 4, folder: false, kind: .free)
        d.ranks = [d.free: 5, d.hidden: 4]
        if partial {
            d.ranks[you] = 0
            d.ranks[system] = 1
            d.ranks[apps] = 2
            d.nodes[Int(d.node(named: "Your files/Photos"))].growing = true
            d.nodes[Int(you)].growing = true
        }
        d.finish()
        return d
    }

    /// Backup's two disks: this Mac and a drive, each half the ring, sorted and cut by place.
    static func pair() -> FixtureData {
        var d = FixtureData()
        d.halves = true
        d.groups = true
        var r = FixtureRandom(state: 99)
        let drive = d.add("Drive", in: 0, folder: true)
        let mac = d.add("This Mac", in: 0, folder: true)
        d.nodes[Int(drive)].half = true
        d.nodes[Int(mac)].half = true
        for (side, scale) in [(mac, 3.0), (drive, 1.0)] {
            for name in ["Movies", "Pictures", "Music", "Downloads", "Old"] {
                let folder = d.add(name, in: side, folder: true)
                for i in 0..<(6 + r.below(14)) {
                    let id = d.add("\(name)-\(i)", in: folder, own: r.bytes(scale * 300), folder: false)
                    d.nodes[Int(id)].group = UInt8(r.below(5))
                }
                let sub = d.add("Clips", in: folder, folder: true)
                for i in 0..<(3 + r.below(5)) {
                    let id = d.add("clip\(i)", in: sub, own: r.bytes(scale * 100), folder: false)
                    d.nodes[Int(id)].group = UInt8(r.below(3))
                }
            }
        }
        d.hidden = d.add("Hidden", in: 0, own: 50_000, folder: false, kind: .hidden)
        d.free = d.add("Free", in: 0, own: 900_000, folder: false, kind: .free)
        // A folder takes the place most of what's in it has; a side is in none.
        d.finish()
        for i in d.nodes.indices.reversed() where d.nodes[i].folder && !d.nodes[i].half && i != 0 {
            var by: [UInt8: UInt64] = [:]
            for c in d.nodes[i].children { if let g = d.nodes[Int(c)].group { by[g, default: 0] &+= d.totals[Int(c)] } }
            d.nodes[i].group = by.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        }
        return d
    }

    /// A media library: titles cut into stretches by place and selection, episodes always drawn however small.
    static func library() -> FixtureData {
        var d = FixtureData()
        var r = FixtureRandom(state: 5)
        let tv = d.add("TV", in: 0, folder: true)
        let films = d.add("Movies", in: 0, folder: true)
        for s in 0..<9 {
            let show = d.add("Show\(s)", in: tv, folder: true)
            for season in 0..<(1 + r.below(5)) {
                let se = d.add("Season \(season)", in: show, folder: true)
                for e in 0..<(4 + r.below(10)) {
                    let ep = d.add("E\(e)", in: se, own: r.bytes(200), folder: false)
                    if r.unit() < 0.4 { d.nodes[Int(ep)].always = true }
                }
            }
        }
        for f in 0..<40 { d.add("Film\(f)", in: films, own: r.bytes(3000), folder: false) }
        d.finish()
        for i in d.nodes.indices where i > 2 && d.nodes[i].folder && r.unit() < 0.5 {
            let t = d.totals[i]
            let a = t / 3, b = t / 4
            d.nodes[i].cuts = [(a, 1, false), (b, nil, true), (t - a - b, 3, false)]
        }
        return d
    }
}
