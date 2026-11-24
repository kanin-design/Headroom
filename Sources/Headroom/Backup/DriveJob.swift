import Foundation

/// One run of Backup's work, as the panel shows it while it goes and after: every file with what became of it, how far
/// the whole run has got in bytes, and how fast it's going.
@MainActor
@Observable
final class DriveJob {
    enum Kind: Equatable { case move, copy, bringBack, copyToMac, verify, deleteFromDrive }

    enum Step: Equatable {
        case waiting
        case copying
        case checking
        case done(String)
        case failed(String)
        case stopped

        var isOver: Bool {
            switch self {
            case .done, .failed, .stopped: true
            default: false
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        var id: String
        var title: String
        var bytes: UInt64
        var step: Step = .waiting
    }

    let kind: Kind
    let title: String
    let driveName: String
    let started = Date()
    private(set) var entries: [Entry]
    private(set) var finished: Date?
    private(set) var current: Int?
    /// How many times a file is read: once to copy it and once more to check the copy, or once to check it.
    let passes: UInt64
    /// Everything that's read, for all the files.
    let work: UInt64
    private(set) var workDone: UInt64 = 0
    /// Bytes a second, smoothed, so the time left doesn't jump about.
    private(set) var speed: Double = 0
    let stop = LockedFlag()
    /// Where a move or a copy goes, and the drive's room when it began, for the bar that fills as files land.
    struct Room: Equatable {
        var place: String
        var capacity: UInt64
        var free: UInt64
    }
    var room: Room?
    /// What frees nothing on the Mac when it's moved: a hard link or a clone whose other copy stays. By entry.
    var freesNothing: Set<String> = []
    /// Who picked what's being moved, when an agent did.
    var agent: String?
    /// What's been written to where it goes so far: every file copied there, and as much as has gone of the one it's on.
    private(set) var landed: UInt64 = 0
    @ObservationIgnored private var landedBefore: UInt64 = 0
    @ObservationIgnored private var doneBeforeCurrent: UInt64 = 0
    @ObservationIgnored private var lastSample: (time: Date, work: UInt64)?

    init(kind: Kind, title: String, driveName: String, entries: [Entry]) {
        self.kind = kind
        self.title = title
        self.driveName = driveName
        self.entries = entries
        passes = kind == .verify || kind == .deleteFromDrive ? 1 : 2
        work = max(entries.reduce(0) { $0 &+ $1.bytes } * passes, 1)
    }

    var isRunning: Bool { finished == nil }
    var fraction: Double { min(Double(workDone) / Double(work), 1) }
    var doneCount: Int { entries.filter { if case .done = $0.step { true } else { false } }.count }
    var failedCount: Int { entries.filter { if case .failed = $0.step { true } else { false } }.count }
    var doneBytes: UInt64 { entries.reduce(0) { if case .done = $1.step { $0 &+ $1.bytes } else { $0 } } }
    private var wasStopped: Bool { stop.value }
    /// What's been freed on the Mac so far: what's moved, less what had another copy that stays.
    var freed: UInt64 {
        guard kind == .move else { return 0 }
        return entries.reduce(0) { sum, entry in
            if case .done = entry.step, !freesNothing.contains(entry.id) { sum &+ entry.bytes } else { sum }
        }
    }

    /// Seconds left at the speed it's going, once there's a speed to go by.
    var timeLeft: TimeInterval? {
        guard isRunning, speed > 1_000_000, Date().timeIntervalSince(started) > 2 else { return nil }
        return Double(work &- min(workDone, work)) / speed
    }

    func begin(_ index: Int) {
        guard index < entries.count else { return }
        current = index
        doneBeforeCurrent = workDone
        entries[index].step = kind == .verify ? .checking : .copying
    }

    /// How far the file it's on has got: copying is the first read, checking the copy the second.
    func progress(_ index: Int, phase: DriveMover.Progress.Phase, bytes: UInt64, of size: UInt64) {
        guard index < entries.count, !entries[index].step.isOver else { return }
        let inFile = kind == .verify ? bytes : (phase == .copying ? bytes : size &+ bytes)
        workDone = doneBeforeCurrent &+ min(inFile, size &* passes)
        if kind != .verify { landed = landedBefore &+ (phase == .copying ? min(bytes, size) : size) }
        let step: Step = kind == .verify || phase == .checking ? .checking : .copying
        if entries[index].step != step { entries[index].step = step }
        sample()
    }

    func finish(_ index: Int, _ step: Step) {
        guard index < entries.count else { return }
        entries[index].step = step
        workDone = doneBeforeCurrent &+ entries[index].bytes &* passes
        doneBeforeCurrent = workDone
        // A copy that failed is taken away again, so only what's done stays landed.
        if case .done = step, kind != .verify { landedBefore &+= entries[index].bytes }
        landed = landedBefore
        sample()
    }

    func end() {
        for i in entries.indices where !entries[i].step.isOver { entries[i].step = .stopped }
        current = nil
        finished = Date()
    }

    private func sample() {
        let now = Date()
        guard let last = lastSample else {
            lastSample = (now, workDone)
            return
        }
        let seconds = now.timeIntervalSince(last.time)
        guard seconds >= 0.5 else { return }
        let instant = Double(workDone &- min(last.work, workDone)) / seconds
        speed = speed == 0 ? instant : speed * 0.8 + instant * 0.2
        lastSample = (now, workDone)
    }

    /// One line on how it's going: how many, how fast and how long is left; afterwards, how long it took and how fast.
    var status: String {
        // Afterwards the title says how it ended, so this says how long it took.
        if let finished {
            let seconds = finished.timeIntervalSince(started)
            var parts = ["Took " + Self.duration(seconds)]
            if kind != .deleteFromDrive, seconds >= 1, doneBytes > 0 {
                parts.append("\(formatBytes(UInt64(Double(doneBytes) / seconds)))/s")
            }
            return parts.joined(separator: " · ")
        }
        let done = entries.filter(\.step.isOver).count
        var parts = ["\(done) of \(entries.count)"]
        if speed > 0 { parts.append("\(formatBytes(UInt64(speed)))/s") }
        if let left = timeLeft { parts.append(Self.duration(left) + " left") }
        return parts.joined(separator: " · ")
    }

    /// 12 s, 4 min, 1 h 5 min.
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(max(s, 1)) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }

    /// One line on how it ended.
    var summary: String {
        let n = doneCount, failed = failedCount
        let files = counted(n, "file")
        let what =
            switch kind {
            case .move: "\(files) moved to \(driveName)"
            case .copy: "\(files) copied to \(driveName)"
            case .bringBack: "\(files) back on this Mac"
            case .copyToMac: "\(files) copied to this Mac"
            case .verify: "\(files) verified"
            case .deleteFromDrive: "\(files) moved to \(driveName)'s Trash"
            }
        var parts = [what]
        if kind != .verify, n > 0 { parts.append(formatBytes(doneBytes)) }
        if failed > 0 { parts.append(failed == 1 ? "1 failed" : "\(failed) failed") }
        if wasStopped { parts.append("stopped") }
        return parts.joined(separator: " · ")
    }
}
