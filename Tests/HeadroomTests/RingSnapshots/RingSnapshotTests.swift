import Foundation
import Testing

@testable import Headroom

/// Headroom's rings as the app drew them before the kit had parts: the whole disk with its band and wedges, a folder,
/// the disk as it will be after cleaning, Backup's two disks, and what lights up for a set of things. Written once from
/// the app as it was (SNAPSHOT_OUT=<folder>), then compared line for line. Backup's pair at its top was written again on
/// 2026-11-22, when its two sides became a thin split band with a dial for each; zoomed into a side, it's as it was. Both
/// pair cases were written again on 2026-11-23, when the Mac's half took the map's keys: only the keys changed.
@Suite("Ring snapshots")
struct RingSnapshotTests {
    private let baseline = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Baseline")

    private static func bits(_ f: Float) -> String { String(f.bitPattern, radix: 16) }

    /// The look's number as the shaders know it, the same however the kit names it.
    private static func look(_ p: Piece) -> Int {
        if p.isSmaller { return 3 }
        if p.isShared { return 6 }
        switch p.role {
        case .container: return 0
        case .room: return 1
        case .unreadable: return 2
        case .item: return 4
        case .gone: return 5
        }
    }

    /// A disk with a few hundred files in nested folders, a locked folder, hidden space and free space.
    private func disk() -> FakeDisk {
        let disk = FakeDisk(capacity: 900_000_000_000, free: 120_000_000_000)
        var state: UInt64 = 11
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        let tops = ["Movies", "Photos", "Library", "Projects", "Music", "Downloads"]
        for (t, top) in tops.enumerated() {
            for f in 0..<(4 + t) {
                let folder = "/Volumes/Fake/\(top)/F\(f)"
                for i in 0..<(3 + Int(next() % 12)) {
                    let deep = i % 4 == 0 ? "/Sub\(i % 3)/Deeper" : (i % 3 == 0 ? "/Sub\(i % 2)" : "")
                    let bytes = (1 + next() % 900) * 10_000_000 * UInt64(1 + t % 3)
                    disk.file("\(folder)\(deep)/file\(i).bin", bytes, kind: [.video, .image, .audio, .other][i % 4])
                }
            }
        }
        disk.file("/Volumes/Fake/Library/Locked/inside.bin", 40_000_000_000)
        disk.finish()
        disk.tree.nodes[Int(disk.node("/Volumes/Fake/Library/Locked"))].flags |= NodeFlag.locked
        disk.tree.nodes[Int(disk.tree.hidden)].bytes = 60_000_000_000
        disk.tree.finish()
        return disk
    }

    private func dump(_ name: String, layout: RingLayout, tree: DiskTree, sets: [[UInt32]] = []) -> String {
        var out = "case \(name) focus=\(layout.focus) rings=\(layout.rings) reach=\(layout.reach) "
        out += "outer=\(layout.outerSmaller.map(String.init) ?? "-") free=\(layout.roomPiece.map(String.init) ?? "-")\n"
        for (i, p) in layout.pieces.enumerated() {
            out += "P \(i) \(p.node) \(p.tail) \(String(p.key, radix: 16)) \(Self.bits(p.a0)) \(Self.bits(p.a1)) \(Self.bits(p.r0)) "
            out += "\(Self.bits(p.r1)) \(p.ring) \(p.parent) \(p.end) \(p.isSmaller ? 1 : 0) \(p.smallerCount) "
            out += "\(Self.bits(p.color.x)),\(Self.bits(p.color.y)),\(Self.bits(p.color.z)) s\(Self.look(p)) \(p.size) "
            out += "\(Self.bits(p.marked)) \(Self.bits(p.deeper))\n"
        }
        for node in 0..<UInt32(tree.count) {
            out +=
                "N \(node) \(layout.piece(of: node).map(String.init) ?? "-") \(layout.nearestPiece(to: node, tree: tree).map(String.init) ?? "-")\n"
        }
        for a in 0..<72 {
            let angle = Float(a) / 72 * 2 * .pi + 0.011
            out +=
                "H \(a) " + (0..<20).map { r in layout.hit(angle: angle, radius: Float(r) / 18).map(String.init) ?? "-" }.joined(separator: " ")
                + "\n"
        }
        for set in sets {
            let lit = layout.light(set, in: tree)
            out += "LIT \(set) full=\(lit.full.map { "\($0.lowerBound)..<\($0.upperBound)" }) holding=\(lit.holding.sorted())"
            out += " best=\(layout.bestPiece(for: set, in: tree).map(String.init) ?? "-")\n"
        }
        return out
    }

    private func colour(_ node: UInt32) -> SIMD3<Float> { SIMD3(Float(node % 7) / 7, Float(node % 11) / 11, Float(node % 13) / 13) }

    /// Real files for Backup's drive and the Mac's folder, always at the same place so names and keys stay the same.
    private func pair(_ disk: FakeDisk) throws -> PairPicture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-ring-snapshot").path
        try? FileManager.default.removeItem(atPath: base)
        let drive = base + "/Drive", mac = "/Volumes/Fake/Movies"
        func make(_ path: String, _ bytes: UInt64) throws {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: nil)
            let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try h.truncate(atOffset: bytes)
            try h.close()
        }
        try make(drive + "/F0/file0.bin", 10_000_000)
        try make(drive + "/F1/extra.bin", 300_000_000)
        try make(drive + "/Elsewhere/only-drive.bin", 900_000_000)
        try make(drive + "/Elsewhere/more/deep.bin", 120_000_000)
        return try #require(
            PairPicture.build(
                real: disk.tree, macFolder: disk.node(mac), macPath: mac, drivePath: drive, driveName: "Spare",
                notes: [], ghosts: true))
    }

    private func cases() throws -> [(String, String)] {
        let disk = disk()
        let tree = disk.tree
        var out: [(String, String)] = []
        let marked: RingLayout.Marker = { $0 % 13 == 5 }
        let movies = disk.node("/Volumes/Fake/Movies"), lib = disk.node("/Volumes/Fake/Library")
        let tiny = disk.node("/Volumes/Fake/Photos/F0/file1.bin")
        let sets: [[UInt32]] = [[movies], [tiny], [tree.free], [lib, tiny], [disk.node("/Volumes/Fake/Library/Locked")]]
        for sizes in [RingSizes(), RingSizes(depth: 9, style: .adaptive), RingSizes(depth: 4, style: .standard)] {
            let layout = RingLayout.build(tree: tree, focus: 0, colorer: colour, marked: marked, after: nil, sizes: sizes)
            out.append(("map-\(sizes.depth)\(sizes.style)", dump("map", layout: layout, tree: tree, sets: sets)))
        }
        let files = disk.node("/Volumes/Fake")
        let zoomed = RingLayout.build(tree: tree, focus: files, colorer: colour, marked: marked, after: nil)
        out.append(("map-files", dump("map-files", layout: zoomed, tree: tree, sets: sets)))
        let ids = [disk.node("/Volumes/Fake/Projects"), disk.node("/Volumes/Fake/Photos/F1")]
        let after = AfterPlan(tree: tree, ids: ids, excluded: [], effect: Accounting.effect(of: ids, except: [], in: tree))
        let afterLayout = RingLayout.build(tree: tree, focus: 0, colorer: colour, after: after)
        out.append(("after", dump("after", layout: afterLayout, tree: tree, sets: sets)))
        let pair = try pair(disk)
        let pt = pair.tree
        let pairLayout = RingLayout.build(tree: pt, focus: 0, colorer: colour, marked: marked, after: nil)
        let pairSets: [[UInt32]] = [[pair.macSide], [pair.driveSide], [UInt32(pt.count - 1)]]
        out.append(("pair", dump("pair", layout: pairLayout, tree: pt, sets: pairSets)))
        let pairMac = RingLayout.build(tree: pt, focus: pair.macSide, colorer: colour, after: nil)
        out.append(("pair-mac", dump("pair-mac", layout: pairMac, tree: pt, sets: pairSets)))
        return out
    }

    @Test("The ring is drawn as before")
    func drawnAsBefore() throws {
        let all = try cases()
        if let folder = ProcessInfo.processInfo.environment["SNAPSHOT_OUT"] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            for (name, text) in all { try text.write(toFile: folder + "/\(name).txt", atomically: true, encoding: .utf8) }
            return
        }
        var differ: [String] = []
        for (name, text) in all {
            let expected = try String(contentsOf: baseline.appendingPathComponent("\(name).txt"), encoding: .utf8)
            let a = expected.split(separator: "\n"), b = text.split(separator: "\n")
            if let i = (0..<min(a.count, b.count)).first(where: { a[$0] != b[$0] }) ?? (a.count != b.count ? min(a.count, b.count) : nil) {
                differ.append(
                    "\(name) line \(i + 1):\n  was: \(i < a.count ? String(a[i].prefix(200)) : "(end)")\n  now: \(i < b.count ? String(b[i].prefix(200)) : "(end)")"
                )
            }
        }
        #expect(differ.isEmpty, Comment(rawValue: differ.joined(separator: "\n")))
    }
}
