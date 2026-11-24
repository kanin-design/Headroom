import Foundation

/// One moment in a disk's life, for the free-space chart.
struct HistoryPoint: Codable, Identifiable, Equatable {
    var id: Date { date }
    var date: Date
    var free: UInt64
    var capacity: UInt64
    var system: UInt64
    var updates: UInt64
    var swap: UInt64
}

/// A compact record of sizes at one moment: every folder over a set size, by a hash of its path.
struct ScanSnapshot {
    var date: Date
    var free: UInt64
    var table: [UInt64: UInt64]
}

/// Where Headroom keeps what it remembers. A scripted check gets its own folder, so it can't touch your real history.
enum AppData {
    static let folder: URL = {
        let name = ScriptRunner.path == nil ? "Headroom" : "Headroom-check"
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}

enum History {
    /// Folders below this aren't recorded, which keeps each snapshot to a few dozen kilobytes.
    static let smallestEntry: UInt64 = 32_000_000

    /// A disk's name as it can be part of a file's name.
    static func safe(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    private static func snapshotsFolder(_ volume: String) -> URL {
        let url = AppData.folder.appendingPathComponent("history-" + safe(volume), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func pointsURL(_ volume: String) -> URL { AppData.folder.appendingPathComponent("points-" + safe(volume) + ".json") }

    static func points(for facts: VolumeFacts) -> [HistoryPoint] {
        guard let data = try? Data(contentsOf: pointsURL(facts.name)) else { return [] }
        return (try? JSONDecoder().decode([HistoryPoint].self, from: data)) ?? []
    }

    /// A hash of each node's path, which stays the same from one scan to the next.
    static func fillKeys(tree: DiskTree, into keys: UnsafeMutablePointer<UInt64>) {
        let nodes = tree.nodes, names = tree.names
        keys[0] = 0xCBF2_9CE4_8422_2325
        for i in 1..<max(tree.count, 1) {
            let n = nodes[i]
            let own = n.nameLength > 0 ? RuleBook.hash(UnsafePointer(names + Int(n.nameOffset)), Int(n.nameLength)) : UInt64(i)
            keys[i] = (keys[Int(n.parent)] &* 0x0000_0100_0000_01B3) ^ own
        }
    }

    /// Adds this scan to the record, and returns the free-space history.
    static func record(tree: DiskTree, facts: VolumeFacts) -> [HistoryPoint] {
        var points = History.points(for: facts)
        let point = HistoryPoint(
            date: Date(), free: facts.free, capacity: facts.capacity, system: facts.system, updates: facts.preboot + facts.update, swap: facts.vm)
        points.append(point)
        if points.count > 1500 { points.removeFirst(points.count - 1500) }
        if let data = try? JSONEncoder().encode(points) { try? data.write(to: pointsURL(facts.name), options: .atomic) }

        let keys = vmAlloc(UInt64.self, max(tree.count, 1))
        defer { vmFree(keys, max(tree.count, 1)) }
        fillKeys(tree: tree, into: keys)
        var body = Data()
        var count: UInt32 = 0
        for i in 0..<tree.count where tree.totals[i] >= smallestEntry {
            withUnsafeBytes(of: keys[i]) { body.append(contentsOf: $0) }
            withUnsafeBytes(of: tree.totals[i]) { body.append(contentsOf: $0) }
            count += 1
        }
        var out = Data()
        var when = Date().timeIntervalSince1970
        var free = facts.free
        withUnsafeBytes(of: &when) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &free) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &count) { out.append(contentsOf: $0) }
        out.append(body)
        let folder = snapshotsFolder(facts.name)
        let name = String(format: "%.0f.snap", when)
        try? out.write(to: folder.appendingPathComponent(name), options: .atomic)
        prune(folder)
        return points
    }

    private static func prune(_ folder: URL) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "snap" }
        let keep = snapshotsToKeep(files.map { Double($0.deletingPathExtension().lastPathComponent) ?? 0 }, now: Date().timeIntervalSince1970)
        for file in files where !keep.contains(Double(file.deletingPathExtension().lastPathComponent) ?? 0) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// The two newest, then what a comparison can use: it looks for one between 0.85 and 2 times the age it wants, and the
    /// longest it wants is 30 days. One every six hours for two days, one a day to two weeks, then one every four days.
    static func snapshotsToKeep(_ times: [Double], now: Double) -> Set<Double> {
        var seen = Set<Int>()
        var keep = Set<Double>()
        // A name that isn't a time from about now, such as one made by hand, is no snapshot of ours.
        for (at, time) in times.filter({ $0.isFinite && $0 >= 0 && $0 < 1e11 }).sorted(by: >).enumerated() {
            let age = now - time
            if at < 2 { keep.insert(time); continue }
            guard age <= 60 * 86_400 else { continue }
            let span: Double = age < 2 * 86_400 ? 21_600 : (age < 14 * 86_400 ? 86_400 : 4 * 86_400)
            // Stretches of different lengths never get the same number.
            if seen.insert(Int(time / span) * 4 + (span == 21_600 ? 0 : (span == 86_400 ? 1 : 2))).inserted { keep.insert(time) }
        }
        return keep
    }

    /// The most recent snapshot at least `olderThan` seconds before this scan, or, for `isLast`, the one before it.
    static func snapshot(forVolume volume: String, olderThan seconds: TimeInterval, isLast: Bool, before date: Date) -> ScanSnapshot? {
        let folder = snapshotsFolder(volume)
        let times = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "snap" }
            .compactMap { Double($0.deletingPathExtension().lastPathComponent) }
            .filter { $0.isFinite && $0 >= 0 && $0 < 1e11 }
            .sorted(by: >)
        let reference = date.timeIntervalSince1970
        let candidates = times.filter { $0 < reference - 60 }
        let chosen: Double?
        if isLast {
            chosen = candidates.first
        } else {
            // Close enough to the window that the comparison means what it says.
            chosen = candidates.first { reference - $0 >= seconds * 0.85 && reference - $0 <= seconds * 2 }
        }
        guard let chosen else { return nil }
        let url = folder.appendingPathComponent(String(format: "%.0f.snap", chosen))
        guard let data = try? Data(contentsOf: url), data.count >= 20 else { return nil }
        return data.withUnsafeBytes { raw -> ScanSnapshot in
            let when = raw.loadUnaligned(fromByteOffset: 0, as: Double.self)
            let free = raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
            // No more than the file holds, whatever a damaged one says.
            let count = min(Int(raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self)), (raw.count - 20) / 16)
            var table = [UInt64: UInt64](minimumCapacity: count)
            for i in 0..<count {
                let at = 20 + i * 16
                guard at + 16 <= raw.count else { break }
                table[raw.loadUnaligned(fromByteOffset: at, as: UInt64.self)] = raw.loadUnaligned(fromByteOffset: at + 8, as: UInt64.self)
            }
            return ScanSnapshot(date: Date(timeIntervalSince1970: when), free: free, table: table)
        }
    }
}
