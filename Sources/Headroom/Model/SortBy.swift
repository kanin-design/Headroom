import Foundation

/// How what's in a folder is ordered, on the ring and in the inspector's lists of it: biggest first, or by name as the
/// Finder sorts them, so a season's episodes go round in order.
enum SortBy: String, CaseIterable, Sendable {
    case name
    case size

    var title: String {
        switch self {
        case .name: "Name"
        case .size: "Size"
        }
    }
}

/// Names in the Finder's order by name: capitals or not, and numbers by their value, so "Episode 2" comes before
/// "Episode 10". Worked out on the names' bytes, so a folder of thousands sorts about as fast as by size. Letters beyond A
/// to Z go by their bytes, after Z, as Æ, Ø and Å do in Norwegian.
enum NameOrder {
    /// Below 0 when `a` comes first, above 0 when `b` does, 0 for the same name.
    static func compare(_ a: UnsafePointer<UInt8>, _ aLength: Int, _ b: UnsafePointer<UInt8>, _ bLength: Int) -> Int {
        var i = 0, j = 0
        // For names the same but for capitals or leading zeros: the first such difference.
        var tie = 0
        while i < aLength && j < bLength {
            let x = a[i], y = b[j]
            if isDigit(x) && isDigit(y) {
                // A number against a number by its value: past its leading zeros the longer is bigger, then digit by digit.
                var aStart = i, bStart = j
                while aStart < aLength && a[aStart] == 0x30 { aStart += 1 }
                while bStart < bLength && b[bStart] == 0x30 { bStart += 1 }
                var aEnd = aStart, bEnd = bStart
                while aEnd < aLength && isDigit(a[aEnd]) { aEnd += 1 }
                while bEnd < bLength && isDigit(b[bEnd]) { bEnd += 1 }
                if aEnd - aStart != bEnd - bStart { return aEnd - aStart - (bEnd - bStart) }
                for k in 0..<(aEnd - aStart) where a[aStart + k] != b[bStart + k] { return Int(a[aStart + k]) - Int(b[bStart + k]) }
                if tie == 0 { tie = (aStart - i) - (bStart - j) }
                i = aEnd
                j = bEnd
                continue
            }
            let fx = fold(x), fy = fold(y)
            if fx != fy { return Int(fx) - Int(fy) }
            if tie == 0 { tie = Int(x) - Int(y) }
            i += 1
            j += 1
        }
        if i < aLength { return 1 }
        if j < bLength { return -1 }
        return tie
    }

    static func compare(_ a: String, _ b: String) -> Int {
        var a = a, b = b
        return a.withUTF8 { x in
            b.withUTF8 { y in
                guard let px = x.baseAddress, let py = y.baseAddress else { return x.count - y.count }
                return compare(px, x.count, py, y.count)
            }
        }
    }

    @inline(__always) private static func isDigit(_ c: UInt8) -> Bool { c &- 0x30 < 10 }
    @inline(__always) private static func fold(_ c: UInt8) -> UInt8 { c &- 0x41 < 26 ? c | 0x20 : c }
}

extension DiskTree {
    /// Whether `a` comes before `b` by name, in the Finder's order. The same names go by the order they were read, so no two
    /// are the same.
    func comesFirst(byName a: UInt32, _ b: UInt32) -> Bool {
        let x = nodes[Int(a)], y = nodes[Int(b)]
        let order = NameOrder.compare(
            UnsafePointer(names + Int(x.nameOffset)), Int(x.nameLength), UnsafePointer(names + Int(y.nameOffset)), Int(y.nameLength))
        return order != 0 ? order < 0 : a < b
    }

    /// Nodes in this order: as they come, biggest first, or by name.
    func ordered(_ nodes: [UInt32], by order: SortBy) -> [UInt32] {
        order == .name ? nodes.sorted { comesFirst(byName: $0, $1) } : nodes
    }
}
