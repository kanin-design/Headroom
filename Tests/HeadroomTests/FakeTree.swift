import Foundation
@testable import Headroom

/// A made-up disk, so the advice can be tested with no real files anywhere.
final class FakeDisk {
    let tree = DiskTree()
    private var nameCursor: UInt32 = 0
    private var paths: [String: UInt32] = [:]
    private(set) var count: UInt32 = 0

    init(capacity: UInt64 = 500_000_000_000, free: UInt64 = 50_000_000_000) {
        tree.capacityBytes = capacity
        tree.freeBytes = free
        tree.volumeName = "Fake"
        tree.rootPath = "/Volumes/Fake"
        _ = add(parent: 0, name: "Fake", flags: NodeFlag.synthetic | NodeFlag.directory, isRoot: true)
        let files = add(parent: 0, name: "/Volumes/Fake", flags: NodeFlag.anchor | NodeFlag.directory | NodeFlag.projects)
        paths["/Volumes/Fake"] = files
        tree.hidden = add(parent: 0, name: "Hidden", flags: NodeFlag.synthetic | NodeFlag.hidden)
        tree.free = add(parent: 0, name: "Free", flags: NodeFlag.synthetic | NodeFlag.free, bytes: free)
    }

    private func add(parent: UInt32, name: String, flags: UInt16, bytes: UInt64 = 0, alias: UInt64 = 0, kind: Kind = .other, modTime: UInt32 = 0, isRoot: Bool = false) -> UInt32 {
        let id = count
        count += 1
        var node = Node()
        node.parent = parent
        node.flags = flags
        node.bytes = bytes
        node.aliasBytes = alias
        node.kind = kind.rawValue
        node.modTime = modTime
        let utf8 = Array(name.utf8)
        node.nameOffset = nameCursor
        node.nameLength = UInt16(utf8.count)
        utf8.withUnsafeBufferPointer { (tree.names + Int(nameCursor)).update(from: $0.baseAddress!, count: utf8.count) }
        nameCursor += UInt32(utf8.count)
        if !isRoot {
            node.nextSibling = tree.nodes[Int(parent)].firstChild
            tree.nodes[Int(parent)].firstChild = id
        }
        tree.nodes[Int(id)] = node
        let s = tree.stats + Int(id) * DiskTree.statStride
        if !flags.isDirectory { s[Int(kind.rawValue)] = UInt32(truncatingIfNeeded: bytes >> 14) }
        tree.count = Int(count)
        return id
    }

    private func folder(_ path: String) -> UInt32 {
        if let known = paths[path] { return known }
        let parent = folder((path as NSString).deletingLastPathComponent)
        let id = add(parent: parent, name: (path as NSString).lastPathComponent, flags: NodeFlag.directory | NodeFlag.projects)
        paths[path] = id
        return id
    }

    @discardableResult
    func file(_ path: String, _ bytes: UInt64, kind: Kind = .other, alias: Bool = false, modTime: UInt32 = 0) -> UInt32 {
        let parent = folder((path as NSString).deletingLastPathComponent)
        let flags: UInt16 = alias ? NodeFlag.alias : 0
        let id = add(parent: parent, name: (path as NSString).lastPathComponent, flags: flags, bytes: alias ? 0 : bytes, alias: alias ? bytes : 0, kind: kind, modTime: modTime)
        paths[path] = id
        return id
    }

    /// A file with two paths: it's counted at the first, and the second only links to it.
    func linked(_ first: String, _ second: String, _ bytes: UInt64, kind: Kind = .video) {
        let a = file(first, bytes, kind: kind)
        let b = file(second, bytes, kind: kind, alias: true)
        // As the scanner does: a folder knows how much of it is links to files counted somewhere else.
        tree.nodes[Int(tree.nodes[Int(b)].parent)].aliasBytes &+= bytes
        let key = UInt64(a) + 1000
        tree.links.append(LinkRecord(key: key, bytes: bytes, dir: tree.nodes[Int(a)].parent, file: a, when: 0, kind: kind.rawValue, counted: true))
        tree.links.append(LinkRecord(key: key, bytes: bytes, dir: tree.nodes[Int(b)].parent, file: b, when: 0, kind: kind.rawValue, counted: false))
    }

    func finish() { tree.finish() }
    func node(_ path: String) -> UInt32 { paths[path]! }
}

private extension UInt16 {
    var isDirectory: Bool { self & NodeFlag.directory != 0 }
}
