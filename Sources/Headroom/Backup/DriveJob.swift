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
    /// Everything a file is read for: once to copy it and once more to check the copy, or once to check it.
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
        let passes: UInt64 = kind == .verify || kind == .deleteFromDrive ? 1 : 2
        work = max(entries.reduce(0) { $0 &+ $1.bytes } * passes, 1)
    }

    var isRunning: Bool { finished == nil }
    var fraction: Double { min(Double(workDone) / Double(work), 1) }
    var doneCount: Int { entries.filter { if case .done = $0.step { true } else { false } }.count }
    var failedCount: Int { entries.filter { if case .failed = $0.step { true } else { false } }.count }
    var doneBytes: UInt64 { entries.reduce(0) { if case .done = $1.step { $0 &+ $1.bytes } else { $0 } } }
    var wasStopped: Bool { stop.value }
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
        let passes: UInt64 = kind == .verify || kind == .deleteFromDrive ? 1 : 2
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
        let passes: UInt64 = kind == .verify || kind == .deleteFromDrive ? 1 : 2
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

    /// One line on how it ended.
    var summary: String {
        let n = doneCount, failed = failedCount
        let what: String
        switch kind {
        case .move: what = n == 1 ? "1 file moved to \(driveName)" : "\(n) files moved to \(driveName)"
        case .copy: what = n == 1 ? "1 file copied to \(driveName)" : "\(n) files copied to \(driveName)"
        case .bringBack: what = n == 1 ? "1 file back on this Mac" : "\(n) files back on this Mac"
        case .copyToMac: what = n == 1 ? "1 file copied to this Mac" : "\(n) files copied to this Mac"
        case .verify: what = n == 1 ? "1 file verified" : "\(n) files verified"
        case .deleteFromDrive: what = n == 1 ? "1 file moved to \(driveName)'s Trash" : "\(n) files moved to \(driveName)'s Trash"
        }
        var parts = [what]
        if kind != .verify, n > 0 { parts.append(formatBytes(doneBytes)) }
        if failed > 0 { parts.append(failed == 1 ? "1 failed" : "\(failed) failed") }
        if wasStopped { parts.append("stopped") }
        return parts.joined(separator: " · ")
    }
}
