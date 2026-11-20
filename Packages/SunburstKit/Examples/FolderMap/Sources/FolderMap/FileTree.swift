import Foundation
import SunburstKit

/// A folder and everything in it, as SunburstKit reads a tree: nodes are numbers, 0 is the top, children biggest first.
struct FileTree: SunburstTree, Sendable {
    struct Node: Sendable {
        var name: String
        var parent: UInt32
        var children: [UInt32] = []
        var own: UInt64 = 0
        var isFolder: Bool
    }

    private(set) var nodes: [Node]
    private var totals: [UInt64] = []

    init(rootName: String) {
        nodes = [Node(name: rootName, parent: 0, isFolder: true)]
    }

    /// Adds something under `parent` and gives back its number.
    mutating func add(_ name: String, in parent: UInt32, size: UInt64 = 0, isFolder: Bool) -> UInt32 {
        let id = UInt32(nodes.count)
        nodes.append(Node(name: name, parent: parent, own: size, isFolder: isFolder))
        nodes[Int(parent)].children.append(id)
        return id
    }

    /// Adds up every folder and puts children biggest first. Call once everything is added.
    mutating func finish() {
        totals = [UInt64](repeating: 0, count: nodes.count)
        // Children always come after their parent, so going backwards adds each one into its parent in one pass.
        for id in nodes.indices.reversed() {
            totals[id] &+= nodes[id].own
            if id != 0 { totals[Int(nodes[id].parent)] &+= totals[id] }
        }
        for id in nodes.indices where !nodes[id].children.isEmpty {
            nodes[id].children.sort { totals[Int($0)] > totals[Int($1)] }
        }
        siblings = [UInt32](repeating: 0, count: nodes.count)
        for node in nodes {
            for (at, child) in node.children.enumerated() where at + 1 < node.children.count {
                siblings[Int(child)] = node.children[at + 1]
            }
        }
    }

    private var siblings: [UInt32] = []

    func name(_ node: UInt32) -> String { nodes[Int(node)].name }

    // MARK: SunburstTree

    func firstChild(of node: UInt32) -> UInt32 { nodes[Int(node)].children.first ?? 0 }
    func nextSibling(of node: UInt32) -> UInt32 { siblings[Int(node)] }
    func parent(of node: UInt32) -> UInt32 { nodes[Int(node)].parent }
    func size(of node: UInt32) -> UInt64 { totals[Int(node)] }
    func ownSize(of node: UInt32) -> UInt64 { nodes[Int(node)].own }
    func isFolder(_ node: UInt32) -> Bool { nodes[Int(node)].isFolder }
    func style(of node: UInt32) -> PieceStyle { nodes[Int(node)].isFolder ? .folder : .file }
    func nameKey(of node: UInt32) -> UInt64 {
        nodes[Int(node)].name.utf8.reduce(0xCBF2_9CE4_8422_2325 as UInt64) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
    }
}

extension FileTree {
    /// Everything in a folder, with the space each file takes on disk. Packages such as apps count as one file.
    static func read(_ url: URL) -> FileTree {
        var tree = FileTree(rootName: url.lastPathComponent)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        var folders: [String: UInt32] = [url.standardizedFileURL.path: 0]
        let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        while let item = walk?.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: Set(keys))
            let parentPath = item.deletingLastPathComponent().standardizedFileURL.path
            guard let parent = folders[parentPath] else { continue }
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            if isFolder {
                folders[item.standardizedFileURL.path] = tree.add(item.lastPathComponent, in: parent, isFolder: true)
            } else {
                if values?.isPackage == true { walk?.skipDescendants() }
                let size = values?.isPackage == true ? Self.packageSize(item) : UInt64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
                _ = tree.add(item.lastPathComponent, in: parent, size: size, isFolder: false)
            }
        }
        tree.finish()
        return tree
    }

    private static func packageSize(_ url: URL) -> UInt64 {
        var total: UInt64 = 0
        let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        while let item = walk?.nextObject() as? URL {
            total &+= UInt64((try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// A made-up home folder, the same every time, for a first look without reading the disk.
    static func sample() -> FileTree {
        var tree = FileTree(rootName: "Home")
        var random = SplitMix(seed: 7)
        let gb: UInt64 = 1_000_000_000, mb: UInt64 = 1_000_000
        func files(_ count: Int, in folder: UInt32, named name: String, ext: String, around size: UInt64) {
            for i in 1...count {
                let jitter = 0.35 + random.next() * 1.3
                _ = tree.add("\(name) \(i).\(ext)", in: folder, size: UInt64(Double(size) * jitter), isFolder: false)
            }
        }
        let movies = tree.add("Movies", in: 0, isFolder: true)
        for (series, episodes) in [("Night Shift", 8), ("Harbour Lights", 6), ("The Long Road", 10)] {
            let folder = tree.add(series, in: movies, isFolder: true)
            for i in 1...episodes {
                let size = UInt64(Double(2 * gb) * (0.35 + random.next() * 1.3))
                _ = tree.add(series + String(format: " S01E%02d.mkv", i), in: folder, size: size, isFolder: false)
            }
        }
        files(5, in: tree.add("Trips", in: movies, isFolder: true), named: "Clip", ext: "mov", around: 900 * mb)

        let photos = tree.add("Pictures", in: 0, isFolder: true)
        for year in 2019...2025 {
            let folder = tree.add("\(year)", in: photos, isFolder: true)
            for album in ["Summer", "Winter", "Family"] {
                files(12, in: tree.add(album, in: folder, isFolder: true), named: "IMG", ext: "heic", around: UInt64(40 + 15 * (year - 2019)) * mb)
            }
        }

        let music = tree.add("Music", in: 0, isFolder: true)
        for artist in ["Aurora Lane", "The Quiet Hours", "Field Notes", "Northbound"] {
            let folder = tree.add(artist, in: music, isFolder: true)
            for album in ["First Light", "Second Wind"] {
                files(10, in: tree.add(album, in: folder, isFolder: true), named: "Track", ext: "flac", around: 35 * mb)
            }
        }

        let code = tree.add("Projects", in: 0, isFolder: true)
        for project in ["atlas", "beacon", "compass"] {
            let folder = tree.add(project, in: code, isFolder: true)
            files(30, in: tree.add("node_modules", in: folder, isFolder: true), named: "module", ext: "js", around: 12 * mb)
            files(20, in: tree.add("build", in: folder, isFolder: true), named: "object", ext: "o", around: 8 * mb)
            files(25, in: tree.add("src", in: folder, isFolder: true), named: "file", ext: "swift", around: 1 * mb)
        }

        let documents = tree.add("Documents", in: 0, isFolder: true)
        files(40, in: tree.add("Scans", in: documents, isFolder: true), named: "Scan", ext: "pdf", around: 25 * mb)
        files(60, in: tree.add("Notes", in: documents, isFolder: true), named: "Note", ext: "md", around: 2 * mb)
        files(8, in: tree.add("Downloads", in: 0, isFolder: true), named: "Installer", ext: "dmg", around: 1500 * mb)
        tree.finish()
        return tree
    }
}

/// Numbers that look random and are the same on every run.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
