import Darwin
import Foundation

/// Where a file is, seen from both sides of Backup: the folder you're in on the Mac and the same folder on the drive.
enum PairPlace: Int, CaseIterable, Sendable {
    case both, onlyMac, onlyDrive, moved, differs, missing

    func title(drive: String) -> String {
        switch self {
        case .both: "On both"
        case .onlyMac: "Only on this Mac"
        case .onlyDrive: "Only on \(drive)"
        case .moved: "Moved to \(drive)"
        case .differs: "Different on each"
        case .missing: "Missing from \(drive)"
        }
    }

    /// Its colour on the ring, in linear Display P3: green where it's safe on both, amber where only the Mac has it, blue
    /// where only the drive has it, violet for what was moved, red for what doesn't match or is gone.
    var colour: SIMD3<Float> {
        switch self {
        case .both: SIMD3(0.10, 0.52, 0.27)
        case .onlyMac: SIMD3(0.92, 0.50, 0.13)
        case .onlyDrive: SIMD3(0.16, 0.36, 0.92)
        case .moved: SIMD3(0.46, 0.30, 0.95)
        case .differs, .missing: SIMD3(0.86, 0.16, 0.16)
        }
    }
}

/// A file on the drive's half, selected to copy back, check or delete: where it is, and where it goes on the Mac.
struct DriveFile: Identifiable, Equatable, Sendable {
    var path: String
    var macPath: String
    var bytes: UInt64
    var place: PairPlace
    var driveName: String
    var id: String { path }
    var title: String { (path as NSString).lastPathComponent }
}

/// Both sides as one ring: the drive's half first, so it's on the right with the drive at the bottom right, and the Mac's
/// on the left with the disk at the bottom left. Each side is drawn at its own size. Files are matched by their path from
/// each side's folder and their size in bytes, and a folder takes the place most of its bytes have.
struct PairPicture {
    let tree: DiskTree
    let macSide: UInt32
    let driveSide: UInt32
    let macPath: String
    let drivePath: String
    let driveName: String
    let places: [UInt32: PairPlace]
    /// Files and bytes in each place, for the legend.
    let counts: [PairPlace: (files: Int, bytes: UInt64)]
    /// What each half holds: the Mac's without the files moved off it, which are only drawn there.
    let macBytes: UInt64
    let driveBytes: UInt64
    /// Each file on the drive's half, by its path from the folder, and the other way round.
    let driveRel: [UInt32: String]
    let driveNodes: [String: UInt32]

    /// Each drive file's size in bytes, as the file says it, which is what's compared.
    let driveSizes: [UInt32: UInt64]

    /// A file on the drive's half, as it's selected.
    func driveFile(_ node: UInt32) -> DriveFile? {
        guard let rel = driveRel[node] else { return nil }
        return DriveFile(path: drivePath + "/" + rel, macPath: macPath + "/" + rel, bytes: driveSizes[node] ?? tree.nodes[Int(node)].bytes,
                         place: places[node] ?? .onlyDrive, driveName: driveName)
    }

    /// The folder both halves are of, by its name.
    var folderName: String { (macPath as NSString).lastPathComponent }

    /// The most nodes either side gets. Past it, a folder is drawn whole, without what's inside it.
    static let most = 400_000

    func colour(_ node: UInt32) -> SIMD3<Float> {
        if let place = places[node] { return place.colour }
        return node == macSide || node == driveSide ? SIMD3(0.30, 0.31, 0.36) : SIMD3(0.20, 0.21, 0.25)
    }

    static func build(real: DiskTree, macFolder: UInt32, macPath: String, drivePath: String, driveName: String, notes: [MovedNote],
                      ghosts: Bool, stop: LockedFlag? = nil) -> PairPicture? {
        let builder = Builder()
        let root = builder.add(parent: 0, name: "This Mac and \(driveName)", flags: NodeFlag.synthetic | NodeFlag.directory, isRoot: true)
        let mac = builder.add(parent: root, name: macPath, flags: NodeFlag.anchor | NodeFlag.directory | NodeFlag.projects)
        let drive = builder.add(parent: root, name: drivePath, flags: NodeFlag.anchor | NodeFlag.directory)
        let tree = builder.tree
        tree.displayNames[mac] = "This Mac"
        tree.displayNames[drive] = driveName
        tree.free = builder.add(parent: root, name: "Free", flags: NodeFlag.synthetic | NodeFlag.free)
        tree.hidden = builder.add(parent: root, name: "Hidden", flags: NodeFlag.synthetic | NodeFlag.hidden)
        tree.volumeName = "This Mac and \(driveName)"
        tree.rootPath = macPath
        tree.scanID = UUID()

        // The Mac's side, from the map: nothing on the disk is read again.
        var macFiles: [String: (node: UInt32, size: UInt64)] = [:]
        var copied: [UInt32: UInt32] = [macFolder: mac]
        func copy(_ from: UInt32, into: UInt32, rel: String) {
            for child in real.children(from) {
                if stop?.value == true { return }
                let n = real.nodes[Int(child)]
                if n.flags & (NodeFlag.gone | NodeFlag.synthetic) != 0 || real.isGhost(child) { continue }
                let name = real.rawName(child)
                let path = rel.isEmpty ? name : rel + "/" + name
                if n.has(NodeFlag.directory) {
                    if builder.count >= Self.most {
                        // Too much to draw it all: the folder is one piece, its size as it is.
                        _ = builder.add(parent: into, name: name, flags: 0, bytes: real.totals[Int(child)], kind: real.dominantKind(child), modTime: real.newest[Int(child)])
                        continue
                    }
                    let id = builder.add(parent: into, name: name, flags: NodeFlag.directory, bytes: n.bytes, modTime: n.modTime, files: n.fileCount)
                    copied[child] = id
                    copy(child, into: id, rel: path)
                } else {
                    let id = builder.add(parent: into, name: name, flags: n.flags & NodeFlag.alias, bytes: n.bytes, alias: n.aliasBytes,
                                         kind: Kind(rawValue: n.kind) ?? .other, modTime: n.modTime)
                    var info = stat()
                    let size = lstat(macPath + "/" + path, &info) == 0 ? UInt64(info.st_size) : n.bytes
                    macFiles[path] = (id, size)
                }
            }
        }
        copy(macFolder, into: mac, rel: "")

        // Files moved off the Mac, from their notes, where they were.
        var movedRel: [String: UInt32] = [:]
        var ghostBytes: UInt64 = 0
        for note in notes where PathMath.isInside(note.originalPath, macPath) && note.originalPath != macPath {
            let rel = String(note.originalPath.dropFirst(macPath.count + 1))
            movedRel[rel] = 0
            guard ghosts else { continue }
            let folder = (note.notePath as NSString).deletingLastPathComponent
            let realFolder = real.find(path: folder) ?? real.find(visible: folder)
            guard let into = realFolder.flatMap({ copied[$0] }) else { continue }
            let id = builder.add(parent: into, name: note.name, flags: 0, bytes: note.size, kind: .other, modTime: UInt32(clamping: Int(note.moved.timeIntervalSince1970)))
            tree.ghosts[id] = note
            ghostBytes &+= note.size
            if tree.ghostBase == .max { tree.ghostBase = id }
            movedRel[rel] = id
        }

        // The drive's side, read from the drive.
        var driveFiles: [String: (node: UInt32, size: UInt64)] = [:]
        let skip: Set<String> = [".DS_Store", ".Trashes", ".fseventsd", ".Spotlight-V100", ".TemporaryItems", ".DocumentRevisions-V100"]
        func walk(_ path: String, into: UInt32, rel: String) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
            var own: UInt64 = 0, files: UInt32 = 0
            for name in names {
                if stop?.value == true { return }
                if skip.contains(name) || name.hasPrefix("._") || name.hasSuffix(".hrpart") { continue }
                let full = path + "/" + name
                let inside = rel.isEmpty ? name : rel + "/" + name
                var info = stat()
                guard lstat(full, &info) == 0 else { continue }
                let kind = info.st_mode & S_IFMT
                if kind == S_IFDIR {
                    if builder.count >= Self.most {
                        _ = builder.add(parent: into, name: name, flags: 0, bytes: Walker.size(of: full))
                        continue
                    }
                    let id = builder.add(parent: into, name: name, flags: NodeFlag.directory, modTime: UInt32(clamping: Int(info.st_mtimespec.tv_sec)))
                    walk(full, into: id, rel: inside)
                } else if kind == S_IFREG {
                    let allocated = UInt64(max(info.st_blocks, 0)) * 512
                    files += 1
                    // Small files are counted in their folder, as on the Mac's side.
                    if allocated < 1 << 20 {
                        own &+= allocated
                        continue
                    }
                    let id = builder.add(parent: into, name: name, flags: 0, bytes: allocated,
                                         kind: Array(name.utf8).withUnsafeBufferPointer { Kind(rawValue: ExtensionTable.shared.kind(name: $0.baseAddress!, length: $0.count)) ?? .other },
                                         modTime: UInt32(clamping: Int(info.st_mtimespec.tv_sec)))
                    driveFiles[inside] = (id, UInt64(info.st_size))
                }
            }
            builder.addOwn(own, files: files, to: into)
        }
        walk(drivePath, into: drive, rel: "")
        if stop?.value == true { return nil }

        // Where each file is.
        var places: [UInt32: PairPlace] = [:]
        for (rel, mine) in macFiles {
            if let theirs = driveFiles[rel] {
                places[mine.node] = theirs.size == mine.size ? .both : .differs
            } else {
                places[mine.node] = .onlyMac
            }
        }
        for (rel, theirs) in driveFiles {
            if let mine = macFiles[rel] {
                places[theirs.node] = theirs.size == mine.size ? .both : .differs
            } else {
                places[theirs.node] = movedRel[rel] != nil ? .moved : .onlyDrive
            }
        }
        for (rel, ghost) in movedRel where ghost != 0 {
            places[ghost] = driveFiles[rel] != nil ? .moved : .missing
        }
        // Each file counted once: a file on both sides is one file, the Mac's. At the space it takes, as the ring draws it, so the
        // legend and the ring agree; a file still downloading can say it's bigger than that.
        var counts: [PairPlace: (files: Int, bytes: UInt64)] = [:]
        for mine in macFiles.values {
            guard let place = places[mine.node] else { continue }
            counts[place, default: (0, 0)].files += 1
            counts[place, default: (0, 0)].bytes &+= tree.nodes[Int(mine.node)].bytes
        }
        for (rel, theirs) in driveFiles where macFiles[rel] == nil {
            guard let place = places[theirs.node] else { continue }
            counts[place, default: (0, 0)].files += 1
            counts[place, default: (0, 0)].bytes &+= tree.nodes[Int(theirs.node)].bytes
        }
        for (rel, ghost) in movedRel where ghost != 0 && driveFiles[rel] == nil {
            counts[.missing, default: (0, 0)].files += 1
            counts[.missing, default: (0, 0)].bytes &+= tree.nodes[Int(ghost)].bytes
        }

        builder.finish()
        // The drive's half first, from twelve o'clock round to the right; the Mac's after it, on the left.
        tree.nodes[Int(root)].firstChild = drive
        tree.nodes[Int(drive)].nextSibling = mac
        tree.nodes[Int(mac)].nextSibling = tree.free
        tree.nodes[Int(tree.free)].nextSibling = tree.hidden
        tree.nodes[Int(tree.hidden)].nextSibling = 0
        tree.keepsTopOrder = true
        tree.numberSubtrees()

        // A folder is where most of what's in it is.
        let n = tree.count
        var byPlace = [UInt64](repeating: 0, count: n * PairPlace.allCases.count)
        for (node, place) in places { byPlace[Int(node) * PairPlace.allCases.count + place.rawValue] &+= tree.totals[Int(node)] }
        var i = n - 1
        while i > 2 {
            let p = Int(tree.nodes[i].parent)
            for k in 0..<PairPlace.allCases.count { byPlace[p * PairPlace.allCases.count + k] &+= byPlace[i * PairPlace.allCases.count + k] }
            i -= 1
        }
        for i in 3..<n where tree.nodes[i].has(NodeFlag.directory) && places[UInt32(i)] == nil {
            let row = byPlace[(i * PairPlace.allCases.count)..<((i + 1) * PairPlace.allCases.count)]
            if let best = row.indices.max(by: { row[$0] < row[$1] }), row[best] > 0 {
                places[UInt32(i)] = PairPlace(rawValue: best - i * PairPlace.allCases.count)
            }
        }
        let macTotal = tree.totals[Int(mac)]
        return PairPicture(tree: tree, macSide: mac, driveSide: drive, macPath: macPath, drivePath: drivePath, driveName: driveName,
                           places: places, counts: counts, macBytes: macTotal &- min(ghostBytes, macTotal), driveBytes: tree.totals[Int(drive)],
                           driveRel: driveFiles.reduce(into: [:]) { $0[$1.value.node] = $1.key }, driveNodes: driveFiles.mapValues(\.node),
                           driveSizes: driveFiles.reduce(into: [:]) { $0[$1.value.node] = $1.value.size })
    }

    /// Writes nodes and their names into a new map, as a scan would.
    private final class Builder {
        let tree = DiskTree()
        private var nameCursor: UInt32 = 0
        private(set) var count = 0

        func add(parent: UInt32, name: String, flags: UInt16, bytes: UInt64 = 0, alias: UInt64 = 0, kind: Kind = .other, modTime: UInt32 = 0,
                 files: UInt32 = 0, isRoot: Bool = false) -> UInt32 {
            let id = UInt32(count)
            var node = Node()
            node.parent = parent
            node.flags = flags
            node.bytes = bytes
            node.aliasBytes = alias
            node.kind = kind.rawValue
            node.modTime = modTime
            node.fileCount = files
            let utf8 = Array(name.utf8.prefix(Int(UInt16.max)))
            node.nameOffset = nameCursor
            node.nameLength = UInt16(utf8.count)
            utf8.withUnsafeBufferPointer { (tree.names + Int(nameCursor)).update(from: $0.baseAddress!, count: utf8.count) }
            nameCursor += UInt32(utf8.count)
            if !isRoot {
                node.nextSibling = tree.nodes[Int(parent)].firstChild
                tree.nodes[Int(parent)].firstChild = id
            }
            tree.nodes[Int(id)] = node
            if flags & NodeFlag.directory == 0, flags & NodeFlag.synthetic == 0 {
                let row = tree.statTable + Int(id) * DiskTree.statStride
                row[Int(kind.rawValue)] = UInt32(truncatingIfNeeded: bytes >> 14)
                node.fileCount = 0
            }
            count += 1
            tree.count = count
            return id
        }

        func addOwn(_ bytes: UInt64, files: UInt32, to id: UInt32) {
            tree.nodes[Int(id)].bytes &+= bytes
            tree.nodes[Int(id)].fileCount &+= files
        }

        func finish() {
            tree.finish()
            tree.compactStats()
        }
    }
}
