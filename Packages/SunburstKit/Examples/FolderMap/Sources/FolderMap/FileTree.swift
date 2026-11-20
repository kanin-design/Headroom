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

    /// A made-up home folder, the same every time, for a first look without reading the disk. It's shaped like a real one:
    /// some branches flat, some a few levels deep, and a few that go on and on, with sizes split unevenly at every level.
    static func sample() -> FileTree {
        var tree = FileTree(rootName: "Home")
        var random = SplitMix(seed: 11)
        let gb = 1e9, mb = 1e6
        // Running numbers, so files with made-up names don't repeat.
        var photo = 4100, clip = 0, track = 0, made = 0
        let titles = ["Opening", "Low Light", "Harbour", "Undertow", "Still Water", "Northern", "Glass", "Paper Boats", "Lanterns",
                      "Driftwood", "Slow Signal", "Homeward"]

        /// `count` shares that add up to 1: the first biggest, tailing off, never quite even.
        func shares(_ count: Int, steepness: Double) -> [Double] {
            let weights = (0..<count).map { pow(Double($0 + 1), -steepness) * (0.75 + 0.5 * random.next()) }
            let total = weights.reduce(0, +)
            return weights.map { $0 / total }
        }
        func folder(_ name: String, in parent: UInt32) -> UInt32 { tree.add(name, in: parent, isFolder: true) }
        func file(_ name: String, in parent: UInt32, size: Double) { _ = tree.add(name, in: parent, size: UInt64(size), isFolder: false) }
        func files(_ count: Int, in parent: UInt32, size: Double, steepness: Double = 0.8, name: (Int) -> String) {
            for (i, share) in shares(count, steepness: steepness).enumerated() { file(name(i), in: parent, size: size * share) }
        }

        /// A folder tree `size` big, at most `depth` levels further down: some files of its own, and a few folders that split
        /// what's left unevenly. Most stop after a level or two; about one in three goes on as deep as it may, which is what
        /// gives a real disk its long, thin branches.
        func grow(_ parent: UInt32, size: Double, depth: Int, folders: [String], files fileNames: [String], forks: Int = 3) {
            let own = depth == 0 ? size : size * (0.1 + random.next() * 0.3)
            let start = Int(random.next() * Double(fileNames.count))
            files(1 + Int(random.next() * 3), in: parent, size: own, steepness: 1.2) { i in
                made += 1
                let name = fileNames[(start + i) % fileNames.count]
                let dot = name.lastIndex(of: ".") ?? name.endIndex
                return name[..<dot] + "-\(made)" + name[dot...]
            }
            guard depth > 0 else { return }
            let first = Int(random.next() * Double(folders.count))
            let count = min(1 + Int(random.next() * Double(forks)), folders.count)
            for (i, share) in shares(count, steepness: 1.15).enumerated() {
                let child = folder(folders[(first + i) % folders.count], in: parent)
                let next = random.next() < 0.33 ? depth - 1 : max(depth - 2 - Int(random.next() * 2), 0)
                grow(child, size: (size - own) * share, depth: next, folders: folders, files: fileNames, forks: max(forks - 1, 2))
            }
        }

        // Films side by side, and home movies by year: two levels.
        let videos = folder("Videos", in: 0)
        files(7, in: folder("Films", in: videos), size: 48 * gb, steepness: 0.45) {
            ["Northern Lights", "The Quiet Harbour", "Paper Moons", "Long Way Home", "Saltwater", "Glasshouse", "Midnight Garden"][$0] + ".mkv"
        }
        let movies = folder("Home Movies", in: videos)
        for (i, event) in ["Road Trip", "Holidays", "Birthdays", "Weekends"].enumerated() {
            files(5 - i, in: folder(event, in: movies), size: [14, 9, 6, 4][i] * gb, steepness: 0.9) { _ in
                clip += 1
                return "Clip \(String(format: "%03d", clip)).mov"
            }
        }
        files(4, in: folder("Exports", in: videos), size: 11 * gb, steepness: 0.7) { "Edit \($0 + 1).mp4" }

        // Photos as a phone takes them: hundreds of a few MB in each album, too small to draw one by one, and a few videos.
        let photos = folder("Photos", in: 0)
        let albums = ["Summer", "Trips", "Family", "Weddings", "Winter", "Garden", "City Walks", "Concerts"]
        for (i, year) in ["2025", "2024", "2023", "2022", "2021"].enumerated() {
            let yearFolder = folder(year, in: photos)
            for k in 0..<(4 - i / 2) {
                let album = folder(albums[(i * 3 + k) % albums.count], in: yearFolder)
                for _ in 0..<(80 + Int(random.next() * 220)) {
                    photo += 1 + Int(random.next() * 4)
                    file("IMG_\(photo).heic", in: album, size: (2.5 + random.next() * 5) * mb)
                }
                for _ in 0..<(1 + Int(random.next() * 3)) {
                    photo += 1 + Int(random.next() * 4)
                    file("IMG_\(photo).mov", in: album, size: (0.4 + pow(random.next(), 2) * 4.6) * gb)
                }
            }
        }

        // The Library: app support, caches and containers, many levels deep, as on any Mac.
        let library = folder("Library", in: 0)
        let appFolders = ["Application Support", "Caches", "Containers", "Developer", "Group Containers", "Logs", "Mail"]
        let inner = ["Data", "Cache", "Versions", "Resources", "Models", "Storage", "Blobs", "Index", "Snapshots", "Media", "Shared", "Current"]
        for (k, share) in shares(appFolders.count, steepness: 0.9).enumerated() {
            let part = folder(appFolders[k], in: library)
            let apps = ["Sketchbook", "Waveform", "Tidewater", "Notebook", "Studio", "Atlas", "Lens", "Mapper"]
            for (j, appShare) in shares(3 + k % 4, steepness: 1.0).enumerated() {
                grow(folder(apps[(k * 2 + j) % apps.count], in: part), size: 52 * gb * share * appShare, depth: 5 - (k + j) % 3,
                     folders: inner, files: ["data.db", "cache.bin", "index.store", "blob.dat", "model.mlpackage", "store.sqlite"])
            }
        }

        // Projects: the work itself is small; renders and builds are big; node_modules goes on and on.
        let projects = folder("Projects", in: 0)
        for (p, name) in ["Atlas", "Beacon", "Compass", "Driftwood"].enumerated() {
            let project = folder(name, in: projects)
            let lower = name.lowercased()
            files(3, in: folder("Renders", in: project), size: [9, 6, 4, 2][p] * gb, steepness: 0.7) { "\(lower)_shot_\(($0 + 1) * 10).exr" }
            files(2, in: folder("Builds", in: project), size: [3, 2, 1.4, 0.8][p] * gb, steepness: 0.6) { "\(lower)-1.\($0 + 2).zip" }
            grow(folder("node_modules", in: project), size: [1.6, 1.1, 0.8, 0.5][p] * gb, depth: 6,
                 folders: ["@babel", "core", "lib", "dist", "esm", "vendor", "plugins", "utils", "types", "build"],
                 files: ["index.js", "bundle.js", "types.d.ts", "binding.node", "worker.wasm"], forks: 4)
            grow(folder("Source", in: project), size: 0.3 * gb, depth: 4,
                 folders: ["Sources", "Views", "Model", "Tests", "Resources", "Assets"], files: ["Main.swift", "View.swift", "Model.swift", "Icon.png"])
        }

        // Games: a few big data packs, mods and saves.
        let games = folder("Games", in: 0)
        for (g, name) in ["Tidewater", "Ember Isles", "Skyline Racer"].enumerated() {
            let game = folder(name, in: games)
            let data = folder("Data", in: game)
            for (l, level) in ["Worlds", "Audio", "Textures"].enumerated() {
                files(3, in: folder(level, in: data), size: [20, 12, 8][g] * gb * [0.55, 0.25, 0.2][l], steepness: 0.8) { "\(level.lowercased())_\($0 + 1).pak" }
            }
            files(3, in: folder("Mods", in: game), size: [2, 1, 0.6][g] * gb, steepness: 0.9) { "mod_\($0 + 1).zip" }
        }

        // Music as files are: albums of ten or so tracks, each a few dozen MB.
        let music = folder("Music", in: 0)
        let records = ["First Light", "Low Tide", "Night Drive", "Afterglow", "Blue Hour", "Second Wind"]
        for (i, artist) in ["Aurora Lane", "The Quiet Hours", "Lumen Drift", "Northbound", "Coastal Radio", "Paper Lanterns"].enumerated() {
            let artistFolder = folder(artist, in: music)
            for r in 0..<(1 + (i + 1) % 3) {
                let record = folder(records[(i + r * 2) % records.count], in: artistFolder)
                for n in 0..<(9 + Int(random.next() * 5)) {
                    track += 1
                    file(String(format: "%02d ", n + 1) + titles[track % titles.count] + ".flac", in: record, size: (28 + random.next() * 34) * mb)
                }
            }
        }

        // Documents: some kept flat, some filed away many folders deep.
        let documents = folder("Documents", in: 0)
        grow(documents, size: 16 * gb, depth: 5, folders: ["Work", "Clients", "2024", "2023", "Reports", "Scans", "Studies", "Taxes", "Archive", "Drafts"],
             files: ["Report.pdf", "Proposal.key", "Budget.numbers", "Scan.pdf", "Notes.md", "Slides.pdf", "Dataset.csv"], forks: 5)

        // Downloads: flat, as downloads are.
        files(9, in: folder("Downloads", in: 0), size: 12 * gb, steepness: 0.7) { n in
            ["Installer.dmg", "Archive.zip", "Fonts.zip", "Dataset.csv", "Backup.tar", "Slides.key", "Recording.m4a", "Manual.pdf", "Photos.zip"][n]
        }
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
