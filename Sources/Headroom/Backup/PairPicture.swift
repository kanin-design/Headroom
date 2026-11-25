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
    /// Each drive file's size in bytes, as the file says it, which is what's compared: its keys are the drive's files.
    private let driveSizes: [UInt32: UInt64]
    /// The files on the Mac's half.
    let macFiles: [UInt32]
    /// Whether the drive was read just now, or its half is what was read there last, and when that was. Never read: nil.
    let online: Bool
    let readAt: Date?

    /// The folder in the map the Mac's half is of, and for each thing on that half the thing in the map it's a copy of.
    let realFolder: UInt32
    let realOf: NodeTable
    /// What's at each path from the folder, on each half, by a number made from the path. A thing's path itself is worked
    /// out from this picture's tree when it's asked for (`rel(of:)`), so no path is kept as text: kept for every thing, as
    /// they were, they took more memory than the rest of the picture. Only a moved file's, which the tree can't say, is.
    private let macByKey: KeyTable
    private let driveByKey: KeyTable
    private let movedRel: [UInt32: String]

    /// The drive's files.
    var driveFiles: Dictionary<UInt32, UInt64>.Keys { driveSizes.keys }

    /// A thing's path from its half's folder, as `build` found it by: on the Mac's half a folder or file adds its name to
    /// what holds it, a map's anchor is named by its own path, and a group of macOS's own parts adds nothing. Nil for a
    /// group, or what isn't on either half.
    func rel(of node: UInt32) -> String? {
        if let moved = movedRel[node] { return moved }
        return Self.rel(of: node, in: tree, macSide: macSide, driveSide: driveSide, visibleMac: PathMath.visible(macPath))
    }

    /// The same for a tree being built, whose moved files aren't asked about: `build` reads a path this way too, for the
    /// few things it needs one for.
    private static func rel(of node: UInt32, in tree: DiskTree, macSide: UInt32, driveSide: UInt32, visibleMac: String) -> String? {
        if node == macSide || node == driveSide { return "" }
        guard node != 0, Int(node) < tree.count else { return nil }
        let n = tree.nodes[Int(node)]
        if n.has(NodeFlag.anchor) { return relative(PathMath.visible(tree.rawName(node)), to: visibleMac) }
        if n.has(NodeFlag.synthetic) { return nil }
        var names = [tree.rawName(node)]
        var at = n.parent
        var base = ""
        while at != macSide, at != driveSide, at != 0 {
            let up = tree.nodes[Int(at)]
            if up.has(NodeFlag.anchor), let path = relative(PathMath.visible(tree.rawName(at)), to: visibleMac) {
                base = path
                break
            }
            if !up.has(NodeFlag.anchor), !up.has(NodeFlag.synthetic) { names.append(tree.rawName(at)) }
            at = up.parent
        }
        let below = names.reversed().joined(separator: "/")
        return base.isEmpty ? below : base + "/" + below
    }

    private static func relative(_ visible: String, to visibleMac: String) -> String? {
        if visibleMac == "/" { return visible == "/" ? "" : (visible.hasPrefix("/") ? String(visible.dropFirst()) : nil) }
        if visible == visibleMac { return "" }
        return visible.hasPrefix(visibleMac + "/") ? String(visible.dropFirst(visibleMac.count + 1)) : nil
    }

    /// What's at a path from the folder, on the Mac's half or the drive's: the number finds it, its path confirms it.
    func macNode(rel: String) -> UInt32? {
        guard let node = macByKey[RuleBook.hash(rel)], self.rel(of: node) == rel else { return nil }
        return node
    }

    func driveNode(rel: String) -> UInt32? {
        guard let node = driveByKey[RuleBook.hash(rel)], self.rel(of: node) == rel else { return nil }
        return node
    }

    /// A file on the drive's half, by its path on the drive.
    func driveNode(path: String) -> UInt32? {
        guard path.hasPrefix(drivePath + "/"), let node = driveNode(rel: String(path.dropFirst(drivePath.count + 1))) else { return nil }
        return driveSizes[node] != nil ? node : nil
    }

    /// A path on the Mac, from one from the folder.
    func onMac(_ rel: String) -> String {
        let visible = PathMath.visible(macPath)
        return rel.isEmpty ? visible : (visible == "/" ? "/" + rel : visible + "/" + rel)
    }

    /// The paths on the Mac of the files in one place.
    func macPaths(in place: PairPlace) -> [String] {
        macFiles.compactMap { places[$0] == place ? rel(of: $0).map(onMac) : nil }
    }

    /// Whether a thing is on the drive's half.
    func isOnDrive(_ node: UInt32) -> Bool { node == driveSide || tree.isInside(node, driveSide) }

    /// The same thing on the other half, when it's there.
    func counterpart(_ node: UInt32) -> UInt32? {
        guard let rel = rel(of: node) else { return nil }
        let other = isOnDrive(node) ? macNode(rel: rel) : driveNode(rel: rel)
        return other == node ? nil : other
    }

    /// A file on the Mac, on the Mac's half.
    func macNode(for path: String) -> UInt32? {
        let visible = PathMath.visible(path), folder = PathMath.visible(macPath)
        let rel = folder == "/" ? String(visible.dropFirst()) : (visible.hasPrefix(folder + "/") ? String(visible.dropFirst(folder.count + 1)) : nil)
        return rel.flatMap { macNode(rel: $0) }
    }

    /// A file on the drive's half, as it's selected.
    func driveFile(_ node: UInt32) -> DriveFile? {
        guard driveSizes[node] != nil, let rel = rel(of: node) else { return nil }
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
        func relative(_ visible: String) -> String? { Self.relative(visible, to: visibleMac) }

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
        //
        // Things are found by a number made from their path (`RuleBook.hash`), worked out a name at a time as the map is
        // walked, and a path is only written out for the few things that need one: a file the drive may have too, or one
        // Backup could move. With a path kept as text for every thing while this ran, making the picture took about
        // 120 MB more than the picture, for a second, every time a map was read.
        //
        // What's made here and let go at the end is made at its full size once: a table that grows as it fills leaves each
        // smaller one behind, and the 25 MB of those stayed with the app long after.
        let most = min(Int(real.dfsSize[Int(macFolder)]), Self.most) + 16
        var macFiles: [UInt64: (node: UInt32, size: UInt64)] = [:]
        var copied = NodeTable(count: real.count)
        copied[macFolder] = mac
        var macByKey: [UInt64: UInt32] = [:]
        macByKey.reserveCapacity(most)
        macByKey[RuleBook.hash("")] = mac
        let foundKeys = Set(found.keys.map { RuleBook.hash($0) })
        #if DEBUG
            var relOf: [UInt32: String] = [mac: ""]
        #endif
        func copy(_ from: UInt32, into: UInt32, rel: String) {
            var folders: [(real: UInt32, id: UInt32, rel: String)] = []
            let inFolder = RuleBook.PathHash(rel)
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
                let ownPath = n.has(NodeFlag.anchor) ? relative(PathMath.visible(name)) : nil
                let hasPath = n.has(NodeFlag.anchor) ? ownPath != nil : !isGroup
                // The number of its path: `rel`, a slash and its name, or the path an anchor is named by.
                let key = n.has(NodeFlag.anchor) ? RuleBook.hash(ownPath ?? "") : inFolder.adding(name).key
                /// Its path, written out: only where it's needed.
                func written() -> String { ownPath ?? (rel.isEmpty ? name : rel + "/" + name) }
                let kept = n.flags & (NodeFlag.anchor | NodeFlag.synthetic | NodeFlag.hidden | NodeFlag.locked | NodeFlag.alias)
                let id: UInt32
                if n.firstChild != 0, builder.count < Self.most {
                    id = builder.add(
                        parent: into, name: name, flags: kept | NodeFlag.directory, bytes: n.bytes, modTime: n.modTime, files: n.fileCount)
                    folders.append((child, id, hasPath ? written() : rel))
                } else if n.firstChild != 0 || n.has(NodeFlag.directory) || isGroup {
                    // Too much to draw it all, or a part drawn whole: one piece, its size as it is.
                    id = builder.add(
                        parent: into, name: name, flags: kept, bytes: real.totals[Int(child)], kind: real.dominantKind(child),
                        modTime: real.newest[Int(child)])
                } else {
                    id = builder.add(
                        parent: into, name: name, flags: kept, bytes: n.bytes, alias: n.aliasBytes, kind: Kind(rawValue: n.kind) ?? .other,
                        modTime: n.modTime)
                    if hasPath {
                        // Compared by what the file says it holds, read only when the drive has one by the same path. A second path
                        // of a hard link or a clone has its bytes counted elsewhere on the map, and holds them all the same.
                        var size = max(n.bytes, n.aliasBytes)
                        if foundKeys.contains(key) {
                            let path = written()
                            var info = stat()
                            if found[path] != nil, lstat(visibleMac == "/" ? "/" + path : visibleMac + "/" + path, &info) == 0 {
                                size = UInt64(max(info.st_size, 0))
                            }
                        }
                        macFiles[key] = (id, size)
                    }
                }
                if let display = real.displayNames[child] { tree.displayNames[id] = display }
                copied[child] = id
                if hasPath {
                    // The first thing at a path keeps it.
                    if macByKey[key] == nil { macByKey[key] = id }
                    #if DEBUG
                        relOf[id] = written()
                    #endif
                }
            }
            for folder in folders { copy(folder.real, into: folder.id, rel: folder.rel) }
        }
        copy(macFolder, into: mac, rel: "")

        // Files moved off the Mac, from their notes, where they were.
        var movedRel: [String: UInt32] = [:]
        var ghostRel: [UInt32: String] = [:]
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
            ghostRel[id] = rel
            ghostBytes &+= note.size
            if tree.ghostBase == .max { tree.ghostBase = id }
            movedRel[rel] = id
        }

        var driveFiles: [String: (node: UInt32, size: UInt64)] = [:]
        var driveFolders: [String: UInt32] = ["": drive]
        func driveFolder(_ rel: String) -> UInt32 {
            if let id = driveFolders[rel] { return id }
            let parent = driveFolder((rel as NSString).deletingLastPathComponent)
            // Too much to draw it all: what's further in is counted in the folder above.
            guard builder.count < Self.most else { return parent }
            let id = builder.add(parent: parent, name: (rel as NSString).lastPathComponent, flags: NodeFlag.directory)
            driveFolders[rel] = id
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
        }

        // Where each file is. A file on the Mac is found by its path's number, and its path, read from the tree, confirms it.
        func macRel(_ node: UInt32) -> String? { Self.rel(of: node, in: tree, macSide: mac, driveSide: drive, visibleMac: visibleMac) }
        func macFile(at rel: String) -> (node: UInt32, size: UInt64)? {
            guard let mine = macFiles[RuleBook.hash(rel)], macRel(mine.node) == rel else { return nil }
            return mine
        }
        /// The Mac's file that each of the drive's files is, where there's one.
        var twins: [UInt32: (node: UInt32, size: UInt64)] = [:]
        var places: [UInt32: PairPlace] = [:]
        for (rel, theirs) in driveFiles {
            if let mine = macFile(at: rel) {
                twins[mine.node] = theirs
                places[theirs.node] = theirs.size == mine.size ? .both : .differs
            } else {
                places[theirs.node] = movedRel[rel] != nil ? .moved : .onlyDrive
            }
        }
        for mine in macFiles.values {
            if let theirs = twins[mine.node] {
                places[mine.node] = theirs.size == mine.size ? .both : .differs
            } else if mine.size >= BackupState.smallest, let rel = macRel(mine.node) {
                // What Backup wouldn't move isn't missing from the drive: it's left out.
                places[mine.node] = Safety.canTrash(visibleMac == "/" ? "/" + rel : visibleMac + "/" + rel) ? .onlyMac : .leftOut
            } else {
                places[mine.node] = .leftOut
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
        let twinned = Set(twins.values.map(\.node))
        for theirs in driveFiles.values where !twinned.contains(theirs.node) {
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

        // A folder is where most of what's in it is. Seven numbers for every thing, in a mapped table: it's only needed here,
        // and mapped memory goes back when this ends, where 17 MB from the heap stayed with the app.
        let n = tree.count, width = PairPlace.allCases.count
        let byPlace = Mapped<UInt64>(count: n * width)
        for (node, place) in places { byPlace[Int(node) * width + place.rawValue] &+= tree.totals[Int(node)] }
        var i = n - 1
        while i > 2 {
            let p = Int(tree.nodes[i].parent)
            for k in 0..<width { byPlace[p * width + k] &+= byPlace[i * width + k] }
            i -= 1
        }
        /// One thing's numbers, by place.
        func row(_ i: Int) -> UnsafeBufferPointer<UInt64> { UnsafeBufferPointer(start: byPlace.base + i * width, count: width) }
        // Backed up: a file on both halves or moved to the drive, and a folder that's nothing else.
        let kept = [PairPlace.both.rawValue, PairPlace.moved.rawValue]
        var backedUp = Set(places.compactMap { kept.contains($0.value.rawValue) ? $0.key : nil })
        for i in 3..<n where tree.nodes[i].has(NodeFlag.directory) {
            let row = row(i)
            let all = row.reduce(UInt64(0), &+)
            if all > 0, kept.reduce(UInt64(0), { $0 &+ row[$1] }) == all { backedUp.insert(UInt32(i)) }
        }
        for i in 3..<n where tree.nodes[i].has(NodeFlag.directory) && places[UInt32(i)] == nil {
            let row = row(i)
            if let best = row.indices.max(by: { row[$0] < row[$1] }), row[best] > 0 { places[UInt32(i)] = PairPlace(rawValue: best) }
        }
        // Inside each folder: what's on both first, then what's only on one side, then what was moved, then what doesn't match.
        for (node, place) in places { tree.order[node] = place.rank }
        // The Mac's half is the map's folder, so what's in it keeps the map's keys: switching to Backup folds the map into its
        // half of the ring, and back, instead of the ring being replaced. A key is the folder's around it, mixed with its
        // name's, so the half's name key is chosen to make its key the folder's. At the top of the disk the half holds what
        // the map has in two places, its top and the folder of your files: it takes the keys of the one that holds most.
        let realOfNode = copied.turnedRound(count: tree.count)
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
        // The drive's paths, as numbers: the first thing at a path keeps it, as on the Mac's half.
        var driveByKey: [UInt64: UInt32] = [:]
        for (rel, node) in driveFolders.merging(driveFiles.mapValues(\.node), uniquingKeysWith: { a, _ in a })
        where driveByKey[RuleBook.hash(rel)] == nil {
            driveByKey[RuleBook.hash(rel)] = node
        }
        let picture = PairPicture(
            tree: tree, macSide: mac, driveSide: drive, macPath: macPath, drivePath: drivePath, driveName: driveName,
            places: places, backedUp: backedUp, counts: counts, macBytes: macTotal &- min(ghostBytes, macTotal), driveBytes: tree.totals[Int(drive)],
            driveSizes: driveFiles.reduce(into: [:]) { $0[$1.value.node] = $1.value.size }, macFiles: macFiles.values.map(\.node),
            online: online, readAt: readAt, realFolder: macFolder, realOf: realOfNode, macByKey: KeyTable(macByKey), driveByKey: KeyTable(driveByKey),
            movedRel: ghostRel)
        #if DEBUG
            // Every path worked out from the tree is the one the build found the thing by, and its number is that path's.
            relOf.merge(ghostRel) { _, moved in moved }
            for (rel, node) in driveFolders { relOf[node] = rel }
            for (rel, file) in driveFiles { relOf[file.node] = rel }
            for (node, rel) in relOf { assert(picture.rel(of: node) == rel, "\(node): \(picture.rel(of: node) ?? "nil") is not \(rel)") }
            for (key, node) in macByKey { assert(relOf[node].map { RuleBook.hash($0) } == key, "\(node): its path's number is not \(key)") }
        #endif
        return picture
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

/// The thing at each path, by the path's number, once the picture is made and nothing more is added: the numbers in
/// order with their things beside them, 12 bytes each, found by halving. The dictionary they're gathered in, made with
/// room to spare for every thing on the map, took twice that for as long as the picture was kept.
struct KeyTable: Sendable {
    private let keys: [UInt64]
    private let nodes: [UInt32]

    init(_ byKey: [UInt64: UInt32]) {
        let sorted = byKey.keys.sorted()
        keys = sorted
        nodes = sorted.map { byKey[$0] ?? 0 }
    }

    subscript(key: UInt64) -> UInt32? {
        var low = 0, high = keys.count
        while low < high {
            let middle = (low + high) / 2
            if keys[middle] < key { low = middle + 1 } else { high = middle }
        }
        return low < keys.count && keys[low] == key ? nodes[low] : nil
    }
}

/// For each thing in one tree, by its number, a thing in another: a flat table, as the numbers run from 0 up with no gaps.
/// As a dictionary, the one from the Mac's half back to the map took four times the memory.
struct NodeTable: Sendable {
    private var table: [UInt32]

    init(count: Int) { table = [UInt32](repeating: .max, count: count) }

    subscript(node: UInt32) -> UInt32? {
        get { Int(node) < table.count && table[Int(node)] != .max ? table[Int(node)] : nil }
        set { if Int(node) < table.count { table[Int(node)] = newValue ?? .max } }
    }

    /// The other way round, for a tree of `count` things: where two things led to the same one, the later of them.
    func turnedRound(count: Int) -> NodeTable {
        var back = NodeTable(count: count)
        for (from, to) in table.enumerated() where to != .max { back[to] = UInt32(from) }
        return back
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
