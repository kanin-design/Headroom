import Foundation

enum Search {
    /// Every folder and named file whose name contains the text, biggest first. Capitals don't matter, for any alphabet.
    /// With a folder, only what's inside it, as the ring shows only that.
    static func run(_ query: String, in tree: DiskTree, within folder: UInt32 = 0) -> [UInt32] {
        let wanted = fold(query)
        let needle = Array(wanted.utf8)
        guard let first = needle.first else { return [] }
        let upperFirst = (first >= 0x61 && first <= 0x7A) ? first - 0x20 : first
        let isPlain = needle.allSatisfy { $0 < 0x80 }
        let nodes = tree.nodes, names = tree.names
        var found: [UInt32] = []
        for i in 1..<max(tree.count, 1) {
            let n = nodes[i]
            // What's been sent to the Trash isn't on the disk to be found.
            if n.flags & (NodeFlag.anchor | NodeFlag.synthetic | NodeFlag.gone) != 0 { continue }
            if folder != 0, i == Int(folder) || !tree.isInside(UInt32(i), folder) { continue }
            let p = UnsafePointer(names + Int(n.nameOffset))
            let length = Int(n.nameLength)
            let holds =
                isPlain ? holdsPlain(needle, first: first, upperFirst: upperFirst, in: p, length: length) : holdsWide(wanted, in: p, length: length)
            if holds { found.append(UInt32(i)) }
        }
        found.sort { tree.totals[Int($0)] > tree.totals[Int($1)] }
        return found
    }

    /// A to Z compare directly as bytes, with no String made per node, so it keeps up with typing on hundreds of thousands of names.
    @inline(__always)
    private static func holdsPlain(_ needle: [UInt8], first: UInt8, upperFirst: UInt8, in p: UnsafePointer<UInt8>, length: Int) -> Bool {
        var at = 0
        let last = length - needle.count
        while at <= last {
            let c = p[at]
            if c == first || c == upperFirst {
                var j = 1
                while j < needle.count {
                    var x = p[at + j]
                    if x >= 0x41 && x <= 0x5A { x |= 0x20 }
                    if x != needle[j] { break }
                    j += 1
                }
                if j == needle.count { return true }
            }
            at += 1
        }
        return false
    }

    /// Any other letter needs the text itself: Ø and ø have no simple rule in bytes, and å can be stored as one character or as
    /// an a followed by its ring. Only a name with such a letter in it can match, and those are few, so the rest cost one look.
    private static func holdsWide(_ wanted: String, in p: UnsafePointer<UInt8>, length: Int) -> Bool {
        var at = 0
        while at < length, p[at] < 0x80 { at += 1 }
        guard at < length else { return false }
        return fold(String(decoding: UnsafeBufferPointer(start: p, count: length), as: UTF8.self)).contains(wanted)
    }

    private static func fold(_ text: String) -> String { text.precomposedStringWithCanonicalMapping.lowercased() }
}
