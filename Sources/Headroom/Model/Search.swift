import Foundation

enum Search {
    /// Every folder and named file whose name contains the text, biggest first. Capitals don't matter, for any alphabet.
    /// With a folder, only what's inside it, as the ring shows only that. Nothing, once stopped.
    static func run(_ query: String, in tree: DiskTree, within folder: UInt32 = 0, stop: StopFlag? = nil) -> [UInt32] {
        var found = matches(query, in: tree, within: folder, stop: stop)
        sortBySize(&found, in: tree)
        return found
    }

    /// The same, in the map's own order. On its own, so nothing else is compiled into its loop over every node.
    @inline(never)
    private static func matches(_ query: String, in tree: DiskTree, within folder: UInt32, stop: StopFlag?) -> [UInt32] {
        guard let matcher = Matcher(query, in: tree) else { return [] }
        var found: [UInt32] = []
        for i in 1..<max(tree.count, 1) {
            if i & 4095 == 0, stop?.isSet == true { return [] }
            if folder != 0, i == Int(folder) || !tree.isInside(UInt32(i), folder) { continue }
            if matcher.holds(i) { found.append(UInt32(i)) }
        }
        return found
    }

    /// Biggest first, and among the same size in the map's own order. A few thousand are sorted as they are. With more,
    /// comparing two at a time has to look each one's size up again and again all over the table, so they're put in
    /// order a byte of the size at a time, each size read once: a search for one letter took 15 ms, 10 of them sorting.
    /// Apart from the search's own loop: with this written into it, every search was a tenth slower.
    @inline(never)
    static func sortBySize(_ found: inout [UInt32], in tree: DiskTree) {
        let totals = tree.totals, n = found.count
        guard n > 4096 else {
            found.sort { totals[Int($0)] > totals[Int($1)] }
            return
        }
        typealias Sized = (size: UInt64, node: UInt32)
        let a = UnsafeMutablePointer<Sized>.allocate(capacity: n), b = UnsafeMutablePointer<Sized>.allocate(capacity: n)
        defer { a.deallocate(); b.deallocate() }
        var all: UInt64 = 0, any: UInt64 = .max
        for i in 0..<n {
            // The size turned over, so the biggest sorts first.
            let size = ~totals[Int(found[i])]
            a[i] = (size, found[i])
            all |= size
            any &= size
        }
        var from = a, to = b
        var starts = [Int](repeating: 0, count: 257)
        for shift in stride(from: UInt64(0), to: 64, by: 8) where (all ^ any) >> shift & 0xFF != 0 {
            // A byte they all have in common changes nothing.
            for digit in 0..<257 { starts[digit] = 0 }
            for i in 0..<n { starts[Int(from[i].size >> shift & 0xFF) + 1] += 1 }
            for digit in 1..<257 { starts[digit] += starts[digit - 1] }
            for i in 0..<n {
                let digit = Int(from[i].size >> shift & 0xFF)
                to[starts[digit]] = from[i]
                starts[digit] += 1
            }
            swap(&from, &to)
        }
        for i in 0..<n { found[i] = from[i].node }
    }

    /// Only among what an earlier search found, in its order, for text that `narrows` it, on the same map unchanged.
    static func narrow(_ earlier: [UInt32], to query: String, in tree: DiskTree) -> [UInt32] {
        guard let matcher = Matcher(query, in: tree) else { return [] }
        return earlier.filter { Int($0) < tree.count && matcher.holds(Int($0)) }
    }

    /// Whether anything whose name holds the text also holds the earlier text, and so is among what that found. Plain
    /// text is matched as bytes and other text as text, so only other text narrows other text.
    static func narrows(_ query: String, from earlier: String) -> Bool {
        let wanted = fold(query), before = fold(earlier)
        let needle = Array(wanted.utf8), old = Array(before.utf8)
        guard old.allSatisfy({ $0 < 0x80 }) else { return wanted.contains(before) }
        return needle.allSatisfy { $0 < 0x80 } && needle.count >= old.count
            && (0...(needle.count - old.count)).contains { needle[$0..<($0 + old.count)].elementsEqual(old) }
    }

    /// Whether a node's name holds the text, and it's on the disk to be found: not trashed, nor drawn only to fill the ring.
    /// A struct rather than a closure, so its test is inlined into the loop over every node: called through a closure it
    /// made the search 15% slower.
    private struct Matcher {
        let wanted: String
        let needle: [UInt8]
        let first: UInt8
        let upperFirst: UInt8
        let isPlain: Bool
        let nodes: UnsafeMutablePointer<Node>
        let names: UnsafeMutablePointer<UInt8>

        init?(_ query: String, in tree: DiskTree) {
            wanted = Search.fold(query)
            needle = Array(wanted.utf8)
            guard let first = needle.first else { return nil }
            self.first = first
            upperFirst = (first >= 0x61 && first <= 0x7A) ? first - 0x20 : first
            isPlain = needle.allSatisfy { $0 < 0x80 }
            nodes = tree.nodes
            names = tree.names
        }

        @inline(__always) func holds(_ i: Int) -> Bool {
            let n = nodes[i]
            if n.flags & (NodeFlag.anchor | NodeFlag.synthetic | NodeFlag.gone) != 0 { return false }
            let p = UnsafePointer(names + Int(n.nameOffset))
            let length = Int(n.nameLength)
            return isPlain
                ? Search.holdsPlain(needle, first: first, upperFirst: upperFirst, in: p, length: length)
                : Search.holdsWide(wanted, in: p, length: length)
        }
    }

    /// A to Z compare directly as bytes, with no String made per node, so it keeps up with typing on hundreds of thousands of names.
    @inline(__always)
    fileprivate static func holdsPlain(_ needle: [UInt8], first: UInt8, upperFirst: UInt8, in p: UnsafePointer<UInt8>, length: Int) -> Bool {
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
    fileprivate static func holdsWide(_ wanted: String, in p: UnsafePointer<UInt8>, length: Int) -> Bool {
        var at = 0
        while at < length, p[at] < 0x80 { at += 1 }
        guard at < length else { return false }
        return fold(String(decoding: UnsafeBufferPointer(start: p, count: length), as: UTF8.self)).contains(wanted)
    }

    fileprivate static func fold(_ text: String) -> String { text.precomposedStringWithCanonicalMapping.lowercased() }
}
