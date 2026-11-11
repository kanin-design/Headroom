import Darwin
import Foundation

/// Aliases in your own folders, for Copies: the symbolic links that point at something on the map, at another disk, or at
/// nothing at all. The scan counts the links in every folder as it reads it, and the counts add up the tree, so finding them
/// only opens the folders that hold one. What a link points to is read then, and nowhere else.
enum Aliases {
    struct Found: Sendable, Equatable {
        /// The folder it's in.
        var dir: UInt32
        var name: String
        /// The full path it points to, as written in the link and made whole.
        var target: String
        /// What it points to on the map, when that's big enough to have a piece of its own.
        var node: UInt32?
        var state: State

        enum State: Sendable, Equatable {
            /// On this disk.
            case here
            /// On another disk that's connected.
            case otherDisk(String)
            /// On another disk that isn't connected.
            case diskMissing(String)
            /// Nothing is there.
            case broken
        }

        var isBroken: Bool {
            switch state {
            case .broken, .diskMissing: true
            default: false
            }
        }
    }

    /// The most links looked at, however many there are.
    static let most = 20_000

    static func find(in tree: DiskTree, rules: RuleBook, stop: LockedFlag) -> [Found] {
        let nodes = tree.nodes
        let field = DiskTree.statSymlinks
        let onBoot = tree.home != 0
        var out: [Found] = []
        var looked = 0
        var stack: [UInt32] = [0]
        while let folder = stack.popLast(), !stop.value, looked < most {
            let row = tree.statRow(folder)
            guard row[field] > 0 else { continue }
            var own = Int(row[field])
            var c = nodes[Int(folder)].firstChild
            while c != 0 {
                let inside = Int(tree.statRow(c)[field])
                if inside > 0 {
                    own -= inside
                    if nodes[Int(c)].has(NodeFlag.directory) { stack.append(c) }
                }
                c = nodes[Int(c)].nextSibling
            }
            let n = nodes[Int(folder)]
            guard own > 0, !n.has(NodeFlag.synthetic) else { continue }
            let yours = onBoot ? n.has(NodeFlag.projects) : !Duplicates.isInsidePackage(folder, tree: tree, rules: rules) && !isPackage(folder, tree: tree, rules: rules)
            guard yours, let path = tree.path(folder), !isNoise(path) else { continue }
            for link in read(folder: path) {
                looked += 1
                if let found = classify(link.name, target: link.target, in: folder, path: path, tree: tree) { out.append(found) }
            }
        }
        return out
    }

    private static func isPackage(_ folder: UInt32, tree: DiskTree, rules: RuleBook) -> Bool {
        let n = tree.nodes[Int(folder)]
        return rules.isPackage(UnsafePointer(tree.names + Int(n.nameOffset)), Int(n.nameLength))
    }

    /// Folders full of links that say nothing about where your space went: a project's command shims, git's insides, and a
    /// Python environment's own interpreter.
    static func isNoise(_ path: String) -> Bool {
        path.contains("/node_modules/") || path.hasSuffix("/node_modules") || path.contains("/.git/") || path.hasSuffix("/.git")
            || path.hasSuffix("/bin") && FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent + "/pyvenv.cfg")
    }

    /// The links in one folder, and what each says.
    static func read(folder path: String) -> [(name: String, target: String)] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        let fd = dirfd(dir)
        var out: [(String, String)] = []
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        while let entry = readdir(dir) {
            guard entry.pointee.d_type == UInt8(DT_LNK) else { continue }
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            let length = readlinkat(fd, name, &buffer, buffer.count - 1)
            guard length > 0 else { continue }
            buffer[length] = 0
            out.append((name, String(cString: buffer)))
        }
        return out
    }

    /// The path a link points to, made whole: relative to its folder, with `.` and `..` worked out. Links along the way aren't
    /// followed, as the disk would, because only where it says matters here.
    static func whole(_ target: String, from folder: String) -> String {
        let start = target.hasPrefix("/") ? target : folder + "/" + target
        var parts: [Substring] = []
        for part in start.split(separator: "/") {
            if part == "." || part.isEmpty { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func classify(_ name: String, target: String, in folder: UInt32, path: String, tree: DiskTree) -> Found? {
        let full = whole(target, from: PathMath.visible(path))
        // Next to what it points to: that says nothing about where space went.
        if (full as NSString).deletingLastPathComponent == PathMath.visible(path) { return nil }
        var st = stat()
        let exists = stat(full, &st) == 0
        let disk = full.hasPrefix("/Volumes/") ? full.split(separator: "/").dropFirst().first.map(String.init) : nil
        let onThisDisk = disk == nil ? tree.home != 0 : tree.rootPath == "/Volumes/" + disk!
        guard exists else {
            if let disk, !onThisDisk, !FileManager.default.fileExists(atPath: "/Volumes/" + disk) {
                return Found(dir: folder, name: name, target: full, node: nil, state: .diskMissing(disk))
            }
            return Found(dir: folder, name: name, target: full, node: nil, state: .broken)
        }
        if !onThisDisk, let disk {
            return Found(dir: folder, name: name, target: full, node: nil, state: .otherDisk(disk))
        }
        // On the startup disk the map's paths begin with the data volume's own name.
        let node = tree.find(path: full) ?? tree.find(path: "/System/Volumes/Data" + full)
        // Something too small to have a piece of its own isn't worth a line.
        guard let node, node != 0 else { return nil }
        return Found(dir: folder, name: name, target: full, node: node, state: .here)
    }
}
