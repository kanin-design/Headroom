import Darwin
import Foundation
import SunburstKit

/// Where a file is, seen from both sides of Backup: the folder you're in on the Mac and the same folder on the drive.
enum PairPlace: Int, CaseIterable, Codable, Sendable {
    case both, onlyMac, onlyDrive, moved, differs, missing
    /// On this Mac, and not something Backup moves: under `BackupState.smallest`, or part of macOS or an app.
    case leftOut

    func title(drive: String) -> String {
        switch self {
        case .both: "On both"
        case .onlyMac: "Only on this Mac"
        case .onlyDrive: "Only on \(drive)"
        case .moved: "Moved to \(drive)"
        case .differs: "Different on each"
        case .missing: "Missing from \(drive)"
        case .leftOut: "Not for Backup"
        }
    }

    /// Its place in the order things are drawn inside a folder.
    var rank: UInt8 {
        switch self {
        case .both: 0
        case .onlyMac, .onlyDrive: 1
        case .moved: 2
        case .differs, .missing: 3
        case .leftOut: 4
        }
    }

    /// Its colour on the ring, in linear Display P3: green where it's safe on both, amber where only the Mac has it, blue
    /// where only the drive has it, violet for what was moved, red for what doesn't match or is gone, grey for what Backup
    /// doesn't take.
    var colour: SIMD3<Float> {
        switch self {
        case .both: SIMD3(0.10, 0.52, 0.27)
        case .onlyMac: SIMD3(0.92, 0.50, 0.13)
        case .onlyDrive: SIMD3(0.16, 0.36, 0.92)
        case .moved: SIMD3(0.46, 0.30, 0.95)
        case .differs, .missing: SIMD3(0.86, 0.16, 0.16)
        case .leftOut: SIMD3(0.27, 0.28, 0.32)
        }
    }
}

/// A file on the drive's half, selected to copy back, check or delete: where it is, and where it goes on the Mac.
struct DriveFile: Identifiable, Equatable, Codable, Sendable {
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
    /// What's backed up: each file that's on both halves, or was moved to the drive, and each folder that's all such files.
    let backedUp: Set<UInt32>
    /// Files and bytes in each place, for the legend.
    let counts: [PairPlace: (files: Int, bytes: UInt64)]
    /// What each half holds: the Mac's without the files moved off it, which are only drawn there.
    let macBytes: UInt64
    let driveBytes: UInt64
    /// Each file on the drive's half, by its path from the folder, and the other way round.
    let driveRel: [UInt32: String]
    let driveNodes: [String: UInt32]

    /// Each drive file's size in bytes, as the file says it, which is what's compared.
    private let driveSizes: [UInt32: UInt64]
    /// Each file on the Mac's half, by its path from the folder.
    let macRel: [UInt32: String]
    /// Whether the drive was read just now, or its half is what was read there last, and when that was. Never read: nil.
    let online: Bool
    let readAt: Date?

    /// The folder in the map the Mac's half is of, and for each thing on that half the thing in the map it's a copy of.
    let realFolder: UInt32
    let realOf: [UInt32: UInt32]
    /// Where each thing on either half is, from the folder, and what's there on each half.
    private let relOf: [UInt32: String]
    private let macByRel: [String: UInt32]
    private let driveByRel: [String: UInt32]

    /// A path on the Mac, from one from the folder.
    func onMac(_ rel: String) -> String {
        let visible = PathMath.visible(macPath)
        return rel.isEmpty ? visible : (visible == "/" ? "/" + rel : visible + "/" + rel)
    }

    /// The paths on the Mac of the files in one place.
    func macPaths(in place: PairPlace) -> [String] {
        macRel.compactMap { places[$0.key] == place ? onMac($0.value) : nil }
    }

    /// Whether a thing is on the drive's half.
    func isOnDrive(_ node: UInt32) -> Bool { node == driveSide || tree.isInside(node, driveSide) }

    /// The same thing on the other half, when it's there.
    func counterpart(_ node: UInt32) -> UInt32? {
        guard let rel = relOf[node] else { return nil }
        let other = isOnDrive(node) ? macByRel[rel] : driveByRel[rel]
        return other == node ? nil : other
    }

    /// A file on the Mac, on the Mac's half.
    func macNode(for path: String) -> UInt32? {
        let visible = PathMath.visible(path), folder = PathMath.visible(macPath)
        let rel = folder == "/" ? String(visible.dropFirst()) : (visible.hasPrefix(folder + "/") ? String(visible.dropFirst(folder.count + 1)) : nil)
        return rel.flatMap { macByRel[$0] }
    }

    /// A file on the drive's half, as it's selected.
    func driveFile(_ node: UInt32) -> DriveFile? {
        guard let rel = driveRel[node] else { return nil }
        return DriveFile(
            path: drivePath + "/" + rel, macPath: onMac(rel), bytes: driveSizes[node] ?? tree.nodes[Int(node)].bytes,
            place: places[node] ?? .onlyDrive, driveName: driveName)
    }

    /// The folder both halves are of, by its name.
    var folderName: String { (macPath as NSString).lastPathComponent }

    /// The most nodes either side gets. Past it, a folder is drawn whole, without what's inside it.
    static let most = 400_000

    func colour(_ node: UInt32) -> SIMD3<Float> {
        var colour: SIMD3<Float>
        if let place = places[node] {
            colour = place.colour
        } else if node == macSide {
            colour = SIMD3(0.30, 0.31, 0.36)
        } else if node == driveSide {
            colour = SIMD3(0.24, 0.28, 0.36)
        } else {
            colour = SIMD3(0.20, 0.21, 0.25)
        }
        return dimmed(colour, node)
    }

    /// The drive's half, drawn from what was read there last, steps back.
    func dimmed(_ colour: SIMD3<Float>, _ node: UInt32) -> SIMD3<Float> {
        guard !online, node == driveSide || tree.isInside(node, driveSide) else { return colour }
        return colour * 0.45 + SIMD3(0.11, 0.115, 0.13)
    }

    /// `online` reads the drive; otherwise its half comes from what was read there last, kept under `listingID` with paths
    /// from `mount`, the drive's top.
    static func build(
        real: DiskTree, macFolder: UInt32, macPath: String, drivePath: String, driveName: String, notes: [MovedNote],
        ghosts: Bool, online: Bool = true, listingID: String? = nil, mount: String? = nil, stop: LockedFlag? = nil
    ) -> PairPicture? {
        let builder = Builder()
        let root = builder.add(parent: 0, name: "This Mac and \(driveName)", flags: NodeFlag.synthetic | NodeFlag.directory, isRoot: true)
        // At the top of the disk the Mac's half is the disk itself, named as the map's own top is, so paths read from it are real.
        let mac = builder.add(parent: root, name: macPath == "/" ? "" : macPath, flags: NodeFlag.anchor | NodeFlag.directory | NodeFlag.projects)
        let drive = builder.add(parent: root, name: drivePath, flags: NodeFlag.anchor | NodeFlag.directory)
        let tree = builder.tree
        tree.displayNames[mac] = "This Mac"
        tree.displayNames[drive] = driveName
        tree.free = builder.add(parent: root, name: "Free", flags: NodeFlag.synthetic | NodeFlag.free)
        tree.hidden = builder.add(parent: root, name: "Hidden", flags: NodeFlag.synthetic | NodeFlag.hidden)
        tree.volumeName = "This Mac and \(driveName)"
        tree.rootPath = macPath
        tree.scanID = UUID()

        // Where things are from the folder, by the paths you see: the drive's side is named that way.
        let visibleMac = PathMath.visible(macPath)
        func relative(_ visible: String) -> String? {
            if visibleMac == "/" { return visible == "/" ? "" : (visible.hasPrefix("/") ? String(visible.dropFirst()) : nil) }
            if visible == visibleMac { return "" }
            return visible.hasPrefix(visibleMac + "/") ? String(visible.dropFirst(visibleMac.count + 1)) : nil
        }

        // The drive's side: read from the drive, or while it's unplugged, from what was read there last.
        var found: [String: DriveListing.File] = [:]
        var readAt: Date?
        let fromTop = mount.map { BackupPaths.fromDriveTop(drivePath, mount: $0) }
        if online {
            guard let read = DriveListings.read(drivePath, stop: stop) else { return nil }
            found = read
            readAt = Date()
            if let listingID, let fromTop { DriveListings.record(listingID, folder: fromTop, files: found) }
        } else if let listingID, let fromTop, let listing = DriveListings.load(listingID), let when = listing.readAt(fromTop) {
            found = listing.files(under: fromTop)
            readAt = when
        }
        // The Mac's side, from the map: nothing on the disk is read again but the size of a file the drive has too. Names,
        // groups and anchors are as the map has them, so a path read from this picture is the real one.
        var macFiles: [String: (node: UInt32, size: UInt64)] = [:]
        var copied: [UInt32: UInt32] = [macFolder: mac]
        var relOf: [UInt32: String] = [mac: ""]
        var macByRel: [String: UInt32] = ["": mac]
        func copy(_ from: UInt32, into: UInt32, rel: String) {
            var folders: [(real: UInt32, id: UInt32, rel: String)] = []
            // Everything in a folder first, then what's inside each: the anchors at the top stay among the first nodes.
            for child in real.children(from) {
                if stop?.value == true { return }
                let n = real.nodes[Int(child)]
                if n.flags & (NodeFlag.gone | NodeFlag.free) != 0 || real.isGhost(child) { continue }
                let name = real.rawName(child)
                // The map's own top, where it's the folder itself: what's in it goes straight into the Mac's half.
                if n.has(NodeFlag.anchor), relative(PathMath.visible(name)) == "" {
                    copied[child] = into
                    folders.append((child, into, rel))
                    continue
                }
                let isGroup = n.has(NodeFlag.synthetic) && !n.has(NodeFlag.anchor)
                // An anchor is named by its own path; a group of macOS's own parts adds nothing to the path.
                let path: String? =
                    n.has(NodeFlag.anchor) ? relative(PathMath.visible(name)) : isGroup ? nil : (rel.isEmpty ? name : rel + "/" + name)
                let kept = n.flags & (NodeFlag.anchor | NodeFlag.synthetic | NodeFlag.hidden | NodeFlag.locked | NodeFlag.alias)
                let id: UInt32
                if n.firstChild != 0, builder.count < Self.most {
                    id = builder.add(
                        parent: into, name: name, flags: kept | NodeFlag.directory, bytes: n.bytes, modTime: n.modTime, files: n.fileCount)
                    folders.append((child, id, path ?? rel))
                } else if n.firstChild != 0 || n.has(NodeFlag.directory) || isGroup {
                    // Too much to draw it all, or a part drawn whole: one piece, its size as it is.
                    id = builder.add(
                        parent: into, name: name, flags: kept, bytes: real.totals[Int(child)], kind: real.dominantKind(child),
                        modTime: real.newest[Int(child)])
                } else {
                    id = builder.add(
                        parent: into, name: name, flags: kept, bytes: n.bytes, alias: n.aliasBytes, kind: Kind(rawValue: n.kind) ?? .other,
                        modTime: n.modTime)
                    if let path {
                        // Compared by what the file says it holds, read only when the drive has one by the same path. A second path
                        // of a hard link or a clone has its bytes counted elsewhere on the map, and holds them all the same.
                        var size = max(n.bytes, n.aliasBytes)
                        if found[path] != nil {
                            var info = stat()
                            if lstat(visibleMac == "/" ? "/" + path : visibleMac + "/" + path, &info) == 0 { size = UInt64(max(info.st_size, 0)) }
                        }
                        macFiles[path] = (id, size)
                    }
                }
                if let display = real.displayNames[child] { tree.displayNames[id] = display }
                copied[child] = id
                if let path {
                    relOf[id] = path
                    if macByRel[path] == nil { macByRel[path] = id }
                }
            }
            for folder in folders { copy(folder.real, into: folder.id, rel: folder.rel) }
        }
        copy(macFolder, into: mac, rel: "")

        // Files moved off the Mac, from their notes, where they were.
        var movedRel: [String: UInt32] = [:]
        var ghostBytes: UInt64 = 0
        for note in notes {
            guard let rel = relative(PathMath.visible(note.originalPath)), !rel.isEmpty else { continue }
            movedRel[rel] = 0
            guard ghosts else { continue }
            let folder = (note.notePath as NSString).deletingLastPathComponent
            let realFolder = real.find(path: folder) ?? real.find(visible: folder)
            guard let into = realFolder.flatMap({ copied[$0] }) else { continue }
            let id = builder.add(
                parent: into, name: note.name, flags: 0, bytes: note.size, kind: .other,
                modTime: UInt32(clamping: Int(note.moved.timeIntervalSince1970)))
            tree.ghosts[id] = note
            relOf[id] = rel
            ghostBytes &+= note.size
            if tree.ghostBase == .max { tree.ghostBase = id }
            movedRel[rel] = id
        }

        var driveFiles: [String: (node: UInt32, size: UInt64)] = [:]
        var driveFolders: [String: UInt32] = ["": drive]
        relOf[drive] = ""
        func driveFolder(_ rel: String) -> UInt32 {
            if let id = driveFolders[rel] { return id }
            let parent = driveFolder((rel as NSString).deletingLastPathComponent)
            // Too much to draw it all: what's further in is counted in the folder above.
            guard builder.count < Self.most else { return parent }
            let id = builder.add(parent: parent, name: (rel as NSString).lastPathComponent, flags: NodeFlag.directory)
            driveFolders[rel] = id
            relOf[id] = rel
            return id
        }
        for (rel, file) in found.sorted(by: { $0.key < $1.key }) {
            let into = driveFolder((rel as NSString).deletingLastPathComponent)
            // Small files are counted in their folder, as on the Mac's side.
            if file.allocated < 1 << 20 || builder.count >= Self.most {
                builder.addOwn(file.allocated, files: 1, to: into)
                continue
            }
            let name = (rel as NSString).lastPathComponent
            // A file's name is never empty.
            // swift-format-ignore: NeverForceUnwrap
            let kind = Array(name.utf8).withUnsafeBufferPointer {
                Kind(rawValue: ExtensionTable.shared.kind(name: $0.baseAddress!, length: $0.count)) ?? .other
            }
            let id = builder.add(parent: into, name: name, flags: 0, bytes: file.allocated, kind: kind, modTime: file.modified)
            driveFiles[rel] = (id, file.size)
            relOf[id] = rel
        }

        // Where each file is.
        var places: [UInt32: PairPlace] = [:]
        for (rel, mine) in macFiles {
            if let theirs = driveFiles[rel] {
                places[mine.node] = theirs.size == mine.size ? .both : .differs
            } else {
                // What Backup wouldn't move isn't missing from the drive: it's left out.
                let path = visibleMac == "/" ? "/" + rel : visibleMac + "/" + rel
                places[mine.node] = mine.size >= BackupState.smallest && Safety.canTrash(path) ? .onlyMac : .leftOut
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
        tree.twoSides = true
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
        // Backed up: a file on both halves or moved to the drive, and a folder that's nothing else.
        let kept = [PairPlace.both.rawValue, PairPlace.moved.rawValue], width = PairPlace.allCases.count
        var backedUp = Set(places.compactMap { kept.contains($0.value.rawValue) ? $0.key : nil })
        for i in 3..<n where tree.nodes[i].has(NodeFlag.directory) {
            let row = byPlace[(i * width)..<((i + 1) * width)]
            let all = row.reduce(UInt64(0), &+)
            if all > 0, kept.reduce(UInt64(0), { $0 &+ row[i * width + $1] }) == all { backedUp.insert(UInt32(i)) }
        }
        for i in 3..<n where tree.nodes[i].has(NodeFlag.directory) && places[UInt32(i)] == nil {
            let row = byPlace[(i * PairPlace.allCases.count)..<((i + 1) * PairPlace.allCases.count)]
            if let best = row.indices.max(by: { row[$0] < row[$1] }), row[best] > 0 {
                places[UInt32(i)] = PairPlace(rawValue: best - i * PairPlace.allCases.count)
            }
        }
        // Inside each folder: what's on both first, then what's only on one side, then what was moved, then what doesn't match.
        for (node, place) in places { tree.order[node] = place.rank }
        // The Mac's half is the map's folder, so what's in it keeps the map's keys: switching to Backup folds the map into its
        // half of the ring, and back, instead of the ring being replaced. A key is the folder's around it, mixed with its
        // name's, so the half's name key is chosen to make its key the folder's. At the top of the disk the half holds what
        // the map has in two places, its top and the folder of your files: it takes the keys of the one that holds most.
        let realOfNode = copied.reduce(into: [UInt32: UInt32]()) { $0[$1.value] = $1.key }
        var weight: [UInt32: UInt64] = [:]
        var child = tree.nodes[Int(mac)].firstChild
        while child != 0 {
            if let r = realOfNode[child], Int(r) < real.count { weight[real.nodes[Int(r)].parent, default: 0] += tree.totals[Int(child)] }
            child = tree.nodes[Int(child)].nextSibling
        }
        let standsFor = weight.max { $0.value < $1.value }?.key ?? macFolder
        tree.standIn = (mac, 0)
        let withoutName = RingLayout.pathKey(MapTree(tree), mac)
        tree.standIn = (mac, RingLayout.pathKey(MapTree(real), standsFor) ^ withoutName)
        let macTotal = tree.totals[Int(mac)]
        return PairPicture(
            tree: tree, macSide: mac, driveSide: drive, macPath: macPath, drivePath: drivePath, driveName: driveName,
            places: places, backedUp: backedUp, counts: counts, macBytes: macTotal &- min(ghostBytes, macTotal), driveBytes: tree.totals[Int(drive)],
            driveRel: driveFiles.reduce(into: [:]) { $0[$1.value.node] = $1.key }, driveNodes: driveFiles.mapValues(\.node),
            driveSizes: driveFiles.reduce(into: [:]) { $0[$1.value.node] = $1.value.size },
            macRel: macFiles.reduce(into: [:]) { $0[$1.value.node] = $1.key }, online: online, readAt: readAt,
            realFolder: macFolder, realOf: realOfNode, relOf: relOf, macByRel: macByRel,
            driveByRel: driveFolders.merging(driveFiles.mapValues(\.node)) { a, _ in a })
    }

    /// Writes nodes and their names into a new map, as a scan would.
    private final class Builder {
        let tree = DiskTree()
        private var nameCursor: UInt32 = 0
        private(set) var count = 0

        func add(
            parent: UInt32, name: String, flags: UInt16, bytes: UInt64 = 0, alias: UInt64 = 0, kind: Kind = .other, modTime: UInt32 = 0,
            files: UInt32 = 0, isRoot: Bool = false
        ) -> UInt32 {
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
            // Only when there are bytes, which have an address.
            // swift-format-ignore: NeverForceUnwrap
            if !utf8.isEmpty { utf8.withUnsafeBufferPointer { (tree.names + Int(nameCursor)).update(from: $0.baseAddress!, count: utf8.count) } }
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

/// Which folder both disks are shown at: the folder in the map, and its path on each side.
struct PairPlaceOnDisks: Equatable {
    var folder: UInt32
    var macPath: String
    var drivePath: String
}

/// A picture of both disks and what it was made from, to tell whether it still shows what Backup would.
struct ReadyPair {
    let real: DiskTree
    let place: PairPlaceOnDisks
    let online: Bool
    let ghosts: Bool
    /// The moved files' notes it drew, by where each note is.
    let notes: [String]
    let picture: PairPicture

    func fits(real other: DiskTree, place: PairPlaceOnDisks, online: Bool, ghosts: Bool, notes: [MovedNote]) -> Bool {
        real === other && self.place == place && self.online == online && self.ghosts == ghosts && self.notes == notes.map(\.notePath)
    }
}
