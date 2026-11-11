import AppKit
import CryptoKit
import Darwin
import Foundation

/// Who has what open right now, from the system's own list. It takes about 20 ms for the whole Mac.
struct OpenFiles: Sendable {
    struct Holder: Sendable, Equatable {
        var process: String
        var pid: pid_t
    }

    private var open: [(path: String, holder: Holder)] = []
    private var running: [(path: String, holder: Holder)] = []

    static func snapshot() -> OpenFiles {
        var out = OpenFiles()
        let me = getpid()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return out }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard found > 0 else { return out }
        for pid in pids.prefix(Int(found)) where pid > 0 && pid != me {
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let executable = String(cString: buffer)
            let holder = Holder(process: Self.name(of: executable), pid: pid)
            out.running.append((executable, holder))
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
            let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
            guard used > 0 else { continue }
            for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { continue }
                let path = withUnsafePointer(to: &info.pvip.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
                if path.hasPrefix("/Users/") || path.hasPrefix("/Volumes/") || path.hasPrefix("/Applications/") { out.open.append((path, holder)) }
            }
        }
        out.open.sort { $0.path < $1.path }
        out.running.sort { $0.path < $1.path }
        return out
    }

    /// A process goes by the app it's part of, not its helper's name.
    private static func name(of executable: String) -> String {
        for part in executable.split(separator: "/") where part.hasSuffix(".app") {
            return String(part.dropLast(4))
        }
        return (executable as NSString).lastPathComponent
    }

    private static func visible(_ path: String) -> String {
        path.hasPrefix("/System/Volumes/Data/") ? String(path.dropFirst("/System/Volumes/Data".count)) : path
    }

    struct Users: Sendable {
        var first: Holder
        /// How many more programs, as well as the first.
        var others: Int
        var runFromHere: Bool
    }

    /// Who's using this folder. What runs from it comes first, because that's what would stop working.
    func users(of path: String) -> Users? {
        let runners = all(in: running, under: path)
        let everyone = runners + all(in: open, under: path)
        guard let first = everyone.first else { return nil }
        return Users(first: first, others: Set(everyone.map(\.pid)).count - 1, runFromHere: !runners.isEmpty)
    }

    private func all(in list: [(path: String, holder: Holder)], under folder: String) -> [Holder] {
        let target = Self.visible(folder)
        var low = 0, high = list.count
        while low < high {
            let middle = (low + high) / 2
            if list[middle].path < target { low = middle + 1 } else { high = middle }
        }
        var found: [Holder] = []
        var at = low
        while at < list.count, list[at].path.hasPrefix(target) {
            if PathMath.isInside(list[at].path, target) { found.append(list[at].holder) }
            at += 1
        }
        return found
    }

    /// Anything running whose path has this text in it: a maker's helpers live outside the app they belong to.
    func running(containing text: String) -> Holder? {
        running.first { $0.path.contains(text) }?.holder
    }
}

enum CheckProblem: Equatable {
    case gone
    case someGone(Int)
    case protected
    case appOpen(name: String, bundleID: String)
    case inUse(process: String, pid: pid_t, others: Int = 0, runFromHere: Bool = false)
    case someInUse(Int, process: String)
    case changed(Date)
    case noGain(other: String)
    case linkedOutOfSight(UInt64)
    case diskMissing(String)
    case differentDisk(String)
    case alreadyThere
    case noRoom(needed: UInt64, free: UInt64)
    case tooBigForDisk(String)
    /// It isn't yours to move, so macOS will ask for your password when it goes.
    case needsPassword
    /// The last clean tried and it didn't go. It waits for you to say try again, so one stubborn thing can't keep failing.
    case couldntGo(String, askSettings: Bool)

    /// Whether this stops it for now. It stays planned, and everything else goes ahead.
    var holdsBack: Bool {
        switch self {
        case .gone, .someGone, .someInUse, .noGain, .linkedOutOfSight, .needsPassword: false
        default: true
        }
    }

    var text: String {
        switch self {
        case .gone: "Not found."
        case .someGone(let n): "\(n) not found."
        case .protected: "Protected by macOS."
        case .appOpen(let name, _): "\(name) is open."
        case .inUse(let process, _, let others, let runFromHere): Self.inUseText(process, others: others, runFromHere: runFromHere)
        case .someInUse(let n, let process): "\(n) in use by \(process), skipped for now."
        case .changed(let date): "Changed \(Self.ago(date)), after it was selected."
        case .noGain(let other): "Frees nothing: hardlinked or cloned with \(other)."
        case .linkedOutOfSight(let bytes): "\(formatBytes(bytes)) is hardlinked where Headroom can't read, so less may be freed."
        case .diskMissing(let name): "\(name) isn't connected."
        case .differentDisk(let name): "A different disk named \(name) is connected. Nothing on it will be touched."
        case .alreadyThere: "Already in that folder."
        case .noRoom(let needed, let free): "Needs \(formatBytes(needed)). That disk has \(formatBytes(free)) free."
        case .tooBigForDisk(let name): "\(name) can't hold files over 4 GB."
        case .needsPassword: "Requires your password."
        case .couldntGo(let why, _): why
        }
    }

    private static func inUseText(_ process: String, others: Int, runFromHere: Bool) -> String {
        let who = others == 0 ? process : "\(process) and \(others) more"
        let doing = runFromHere ? (others == 0 ? "is running from here" : "are running from here") : (others == 0 ? "has a file open here" : "have files open here")
        return "\(who) \(doing)."
    }

    private static func ago(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// What the last look found for one planned thing.
struct ItemCheck: Equatable {
    var problems: [CheckProblem] = []
    /// Paths that stay this time, because something is using them.
    var heldPaths: [String] = []
    var canGo: Bool { !problems.contains { $0.holdsBack } && !problems.contains(.gone) }
    var isGone: Bool { problems.contains(.gone) }
}

enum PlanChecks {
    struct RunningApp: Sendable {
        var bundleID: String
        var name: String
    }

    /// Looks at every planned thing as it is right now. Nothing is changed.
    /// `otherCopy` names what else holds the same files, and how much.
    /// A `fresh` check looks at everything again. The rest are for while you're ticking things, when a look from a moment ago is
    /// as good as a new one.
    static func run(items: [PlanItem], trueBytes: [String: UInt64], otherCopy: [String: (title: String, bytes: UInt64)], runningApps: [RunningApp], fullAccess: Bool = true, fresh: Bool = true) -> [String: ItemCheck] {
        let open = OpenFiles.snapshot()
        var out: [String: ItemCheck] = [:]
        let fm = FileManager.default
        let maxAge: TimeInterval = fresh ? 0 : 60
        for item in items {
            // Nobody is waiting for this one any more.
            if Task.isCancelled { break }
            var check = ItemCheck()
            if item.isEmptyTrash {
                out[item.id] = check
                continue
            }
            // A disk that isn't plugged in doesn't mean what's on it is gone.
            if let path = item.paths.first {
                let mount = PathMath.mount(of: path)
                if mount != "/", !fm.fileExists(atPath: mount) {
                    check.problems.append(.diskMissing((mount as NSString).lastPathComponent))
                    out[item.id] = check
                    continue
                }
            }
            var missing = 0
            var present: [String] = []
            for path in item.paths {
                var info = stat()
                if lstat(path, &info) == 0 { present.append(path) } else { missing += 1 }
            }
            if present.isEmpty {
                check.problems.append(.gone)
                out[item.id] = check
                continue
            }
            if missing > 0 { check.problems.append(.someGone(missing)) }
            // The same name doesn't make it the same disk.
            if let wanted = item.diskID, let found = Cleaner.diskID(of: present[0]), wanted != found {
                check.problems.append(.differentDisk(Cleaner.diskName(of: present[0])))
                out[item.id] = check
                continue
            }
            let isAllowed: (String) -> Bool = item.step == .uninstall ? Safety.canUninstall : Safety.canTrash
            if !present.allSatisfy(isAllowed) {
                check.problems.append(.protected)
            } else if present.contains(where: Cleaner.takesPassword) {
                check.problems.append(.needsPassword)
            }
            if let id = item.bundleID, let app = runningApps.first(where: { $0.bundleID == id }) {
                check.problems.append(.appOpen(name: app.name, bundleID: id))
            } else if !item.acceptsInUse {
                // Busy things stay until you say otherwise. In a list of many, the rest still go.
                var busy: [(path: String, users: OpenFiles.Users)] = []
                for path in present {
                    if let users = open.users(of: path) { busy.append((path, users)) }
                }
                if let users = busy.first?.users {
                    if busy.count == present.count {
                        check.problems.append(.inUse(process: users.first.process, pid: users.first.pid, others: users.others, runFromHere: users.runFromHere))
                    } else {
                        check.problems.append(.someInUse(busy.count, process: users.first.process))
                    }
                    check.heldPaths = busy.map(\.path)
                }
            }
            // What rebuilds itself changes all the time. Anything else that changed since you planned it might be back in use.
            if item.tier >= .redownload || item.byHand {
                var newest: Date?
                for path in present { newest = max(newest ?? .distantPast, Walker.recentLook(at: path, limit: item.isMove ? 2_000_000 : 40_000, maxAge: maxAge).newestDate) }
                if let newest, newest > item.addedAt.addingTimeInterval(120), newest > (item.acceptedChange ?? .distantPast) {
                    check.problems.append(.changed(newest))
                }
            }
            if case .move(let folder) = item.step {
                // Moving something onto itself would end with it in the Trash and nowhere else.
                if present.contains(where: { Cleaner.moveIsOntoItself($0, into: folder) }) {
                    check.problems.append(.alreadyThere)
                }
                let mount = PathMath.mount(of: folder)
                if mount != "/", !fm.fileExists(atPath: mount) {
                    check.problems.append(.diskMissing((mount as NSString).lastPathComponent))
                } else if let facts = VolumeFacts.read(path: mount) {
                    let needed = present.reduce(UInt64(0)) { $0 &+ Walker.recentLook(at: $1, limit: 2_000_000, maxAge: max(maxAge, 1)).size }
                    if facts.free < needed { check.problems.append(.noRoom(needed: needed, free: facts.free)) }
                    var info = statfs()
                    if statfs(mount, &info) == 0 {
                        let type = withUnsafePointer(to: &info.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
                        if type == "msdos", present.contains(where: { Walker.recentLook(at: $0, limit: 2_000_000, maxAge: max(maxAge, 1)).largestFile >= 4 << 30 }) {
                            check.problems.append(.tooBigForDisk((mount as NSString).lastPathComponent))
                        }
                    }
                }
            }
            if let other = otherCopy[item.id], let bytes = trueBytes[item.id], Double(bytes) < Double(other.bytes) * 0.02 {
                check.problems.append(.noGain(other: other.title))
            }
            // Without Full Disk Access the other copy may be in a folder that couldn't be read, so the map can't know.
            // A planned other copy has its links by definition: it's the one half of a pair the map already knows about.
            if !fullAccess, otherCopy[item.id] == nil, !item.id.hasSuffix(":other-copy") {
                let linked = present.reduce(UInt64(0)) { $0 &+ Walker.recentLook(at: $1, limit: 40_000, maxAge: max(maxAge, 1)).linkedBytes }
                if linked >= 50_000_000 { check.problems.append(.linkedOutOfSight(linked)) }
            }
            out[item.id] = check
        }
        return out
    }
}

/// Some things only the Finder may move. macOS keeps apps to itself, and what belongs to the system takes a password, which
/// the Finder asks for when it has to. The first time, macOS asks whether Headroom may ask the Finder at all. Only `Cleaner`
/// calls this, after its own checks.
enum FinderAsk {
    enum Failure: Error, Equatable {
        case notAllowed
        case cancelled
        case failed(String)
    }

    /// Says where it ended up.
    fileprivate static func moveToTrash(_ path: String, stop: LockedFlag?) throws -> String {
        var place = try run([
            "on run argv",
            "set thing to POSIX file (item 1 of argv) as alias",
            "with timeout of 600 seconds",
            "tell application \"Finder\" to set place to (delete thing) as alias",
            "end timeout",
            "return POSIX path of place",
            "end run",
        ], [path], stop: stop)
        // A package is a folder, and its path comes back like one.
        if place.count > 1, place.hasSuffix("/") { place.removeLast() }
        return place
    }

    fileprivate static func move(_ path: String, into folder: String, named name: String) throws {
        _ = try run([
            "on run argv",
            "set thing to POSIX file (item 1 of argv) as alias",
            "set destination to POSIX file (item 2 of argv) as alias",
            "with timeout of 600 seconds",
            "tell application \"Finder\"",
            "set moved to move thing to destination",
            // The Trash may have renamed it, if it already held something with the same name.
            "set name of moved to (item 3 of argv)",
            "end tell",
            "end timeout",
            "end run",
        ], [path, folder, name])
    }

    /// Waits on its own thread, so a password box never holds up the window.
    private static func run(_ lines: [String], _ arguments: [String], stop: LockedFlag? = nil) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = lines.flatMap { ["-e", $0] } + arguments
        return try runToEnd(task, stop: stop)
    }

    /// Runs it and says what it printed. Stopping a clean, which quitting does, ends the wait at once, so quitting never sits
    /// behind a password box nobody answers. The Finder's own box stays up: answered, it moves the thing to the Trash anyway,
    /// where it simply is, unrecorded.
    static func runToEnd(_ task: Process, stop: LockedFlag?) throws -> String {
        let output = Pipe()
        let errors = Pipe()
        task.standardOutput = output
        task.standardError = errors
        try task.run()
        var watch: DispatchSourceTimer?
        if let stop {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
            timer.setEventHandler { if stop.value, task.isRunning { task.terminate() } }
            timer.resume()
            watch = timer
        }
        defer { watch?.cancel() }
        let said = output.fileHandleForReading.readDataToEndOfFile()
        let complaint = errors.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        if stop?.value == true, task.terminationReason == .uncaughtSignal { throw Cleaner.Failure.stopped }
        guard task.terminationStatus == 0 else { throw failure(from: String(decoding: complaint, as: UTF8.self)) }
        return String(decoding: said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the complaint means. It ends with the error's number.
    static func failure(from text: String) -> Failure {
        if text.contains("(-1743)") { return .notAllowed }
        if text.contains("(-128)") { return .cancelled }
        var reason = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for lead in ["execution error: ", "Finder got an error: "] {
            if let found = reason.range(of: lead) { reason = String(reason[found.upperBound...]) }
        }
        // The number at the end means nothing to anyone.
        if reason.hasSuffix(")"), let open = reason.lastIndex(of: "("), Int(reason[reason.index(after: open)...].dropLast()) != nil {
            reason = String(reason[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return .failed(reason)
    }
}

/// Everything that touches files lives here, behind one check. During a scripted run it can only reach a throwaway
/// disk called HeadroomTest, whatever the script asks, so the app can't be used to reach your files that way.
enum Cleaner {
    static let testDisk = "/Volumes/HeadroomTest"
    nonisolated(unsafe) static var onlyInside: String? = ScriptRunner.path == nil ? nil : testDisk

    enum Failure: Error {
        case notAllowed
        case wouldOverwrite(String)
        case copyDidNotMatch(String)
        case sameFile
        case stopped
    }

    static func mayTouch(_ path: String, step: PlanStep = .trash) -> Bool {
        if let root = onlyInside, !PathMath.isInside(path, root) { return false }
        if step == .uninstall { return Safety.canUninstall(path) }
        return Safety.canTrash(path)
    }

    /// Moves it to the Trash, and says where it ended up and which file it is. An app goes through the Finder, and so does
    /// anything else macOS won't let this app move itself.
    static func trash(_ path: String, step: PlanStep = .trash, stop: LockedFlag? = nil) throws -> (place: String, identity: String?) {
        guard mayTouch(path, step: step) else { throw Failure.notAllowed }
        func throughFinder() throws -> (place: String, identity: String?) {
            let place = visibleInTrash(try FinderAsk.moveToTrash(path, stop: stop))
            return (place, identity(of: place))
        }
        if step == .uninstall, path.hasSuffix(".app") { return try throughFinder() }
        do {
            var result: NSURL?
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
            let place = visibleInTrash(result?.path ?? "")
            return (place, identity(of: place))
        } catch let error where isNoPermission(error) {
            return try throughFinder()
        }
    }

    /// The Finder hides a name that starts with a dot, in the Trash as anywhere else, so what you threw away would seem to have
    /// vanished. There it goes by its name without the dot. Undo knows where it is, and brings it back under its own name.
    static func visibleInTrash(_ place: String) -> String {
        let name = (place as NSString).lastPathComponent
        let bare = String(name.drop { $0 == "." })
        guard name.hasPrefix("."), !bare.isEmpty else { return place }
        let folder = (place as NSString).deletingLastPathComponent
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: place, isDirectory: &isFolder)
        // A file keeps its extension, as the Finder does it: "a 2.txt", not "a.txt 2".
        let ext = isFolder.boolValue ? "" : (bare as NSString).pathExtension
        let stem = ext.isEmpty ? bare : (bare as NSString).deletingPathExtension
        var target = folder + "/" + bare
        var copy = 2
        while FileManager.default.fileExists(atPath: target) {
            target = folder + "/" + stem + " \(copy)" + (ext.isEmpty ? "" : "." + ext)
            copy += 1
        }
        do {
            try FileManager.default.moveItem(atPath: place, toPath: target)
            return target
        } catch {
            return place
        }
    }

    /// Whether moving this takes more than you have. A file only needs its folder to be writable, however read-only the file
    /// itself is. A folder also has to be writable itself, because it gets a new parent.
    static func takesPassword(_ path: String) -> Bool {
        if access((path as NSString).deletingLastPathComponent, W_OK) != 0 { return true }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        return access(path, W_OK) != 0
    }

    private static func isNoPermission(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain, e.code == NSFileWriteNoPermissionError { return true }
        if e.domain == NSPOSIXErrorDomain, e.code == Int(EPERM) || e.code == Int(EACCES) { return true }
        if let under = e.userInfo[NSUnderlyingErrorKey] as? NSError { return isNoPermission(under) }
        return false
    }

    /// Why something didn't go, in words, for the list.
    static func whyItFailed(_ error: Error) -> CheckProblem {
        switch error {
        case FinderAsk.Failure.notAllowed:
            return .couldntGo("Headroom isn't allowed to control the Finder.", askSettings: true)
        case FinderAsk.Failure.cancelled:
            return .couldntGo("Cancelled.", askSettings: false)
        case FinderAsk.Failure.failed(let text):
            return .couldntGo("The Finder couldn't move this: \(text)", askSettings: false)
        case Failure.notAllowed:
            return .couldntGo("Protected by macOS.", askSettings: false)
        case Failure.wouldOverwrite:
            return .couldntGo("An item with that name already exists there.", askSettings: false)
        case Failure.copyDidNotMatch:
            return .couldntGo("The copy didn't match the original, so the original was kept.", askSettings: false)
        case Failure.sameFile:
            return .couldntGo("Already there.", askSettings: false)
        case Failure.stopped:
            return .couldntGo("Stopped before this item.", askSettings: false)
        default:
            return .couldntGo((error as NSError).localizedDescription, askSettings: false)
        }
    }

    /// Which file this is, whatever it's called now.
    static func identity(of path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    /// Whether this is still the file that was moved to the Trash, and not something that later took its name.
    private static func isStillThat(_ thing: CleanedThing) -> Bool {
        guard let wanted = thing.identity else { return true }
        return identity(of: thing.inTrash) == wanted
    }

    /// Puts something back where it was. It never replaces what's there now, except the link that took a linked copy's place,
    /// and only while that is still a link to the copy that stayed.
    static func putBack(_ thing: CleanedThing) throws {
        if let root = onlyInside, !PathMath.isInside(thing.original, root) { throw Failure.notAllowed }
        let fm = FileManager.default
        if let kept = thing.linkedTo, isLink(thing.original, to: kept), isStillThat(thing) { unlink(thing.original) }
        if fm.fileExists(atPath: thing.original) { throw Failure.wouldOverwrite(thing.original) }
        guard isStillThat(thing) else { throw Failure.notAllowed }
        let folder = (thing.original as NSString).deletingLastPathComponent
        let name = (thing.original as NSString).lastPathComponent
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // What took the Finder to move out takes the Finder to bring back.
        if thing.original.hasSuffix(".app") {
            try FinderAsk.move(thing.inTrash, into: folder, named: name)
            return
        }
        do {
            try fm.moveItem(atPath: thing.inTrash, toPath: thing.original)
        } catch let error where isNoPermission(error) {
            try FinderAsk.move(thing.inTrash, into: folder, named: name)
        }
    }

    // MARK: Taking out copies

    /// What takes a copy's place once it's gone: nothing, a hard link to the copy kept, or a symlink to it.
    enum Replacement { case nothing, hardlink, symlink }

    /// Takes out a copy of the file at `kept`. Every byte of both is read and compared first, since a file that changed after
    /// it was compared isn't a copy any more. The copy goes to the Trash on record, as anything cleaned does, so Undo can put
    /// it back, and a hard link or a symlink to the kept file takes its place if asked; if that can't be made, the copy comes
    /// straight back. `trashing` is for the tests, which mustn't fill your Trash.
    static func replaceCopy(_ copy: String, of kept: String, with replacement: Replacement, stop: LockedFlag? = nil,
                            trashing: (String) throws -> (place: String, identity: String?) = { try trash($0) }) throws -> (place: String, identity: String?) {
        guard mayTouch(copy) else { throw Failure.notAllowed }
        if let root = onlyInside, !PathMath.isInside(kept, root) { throw Failure.notAllowed }
        var a = stat(), b = stat()
        guard lstat(copy, &a) == 0, lstat(kept, &b) == 0, a.st_mode & S_IFMT == S_IFREG, b.st_mode & S_IFMT == S_IFREG else { throw Failure.notAllowed }
        // A hard link can't cross disks.
        if replacement == .hardlink, a.st_dev != b.st_dev { throw Failure.notAllowed }
        guard a.st_dev != b.st_dev || a.st_ino != b.st_ino else { throw Failure.sameFile }
        guard a.st_size == b.st_size, try sameBytes(copy, kept, stop: stop) else { throw Failure.copyDidNotMatch(copy) }
        let moved = try trashing(copy)
        let made: Int32
        switch replacement {
        case .nothing: return moved
        case .hardlink: made = Darwin.link(kept, copy)
        case .symlink: made = Darwin.symlink(kept, copy)
        }
        guard made == 0 else {
            try? FileManager.default.moveItem(atPath: moved.place, toPath: copy)
            throw Failure.notAllowed
        }
        return moved
    }

    /// A copy replaced by a hard link to the copy kept.
    static func link(_ copy: String, to kept: String, stop: LockedFlag? = nil,
                     trashing: (String) throws -> (place: String, identity: String?) = { try trash($0) }) throws -> (place: String, identity: String?) {
        try replaceCopy(copy, of: kept, with: .hardlink, stop: stop, trashing: trashing)
    }

    /// Whether two paths are the same file: one file with two names.
    static func isSameFile(_ a: String, _ b: String) -> Bool {
        var x = stat(), y = stat()
        return lstat(a, &x) == 0 && lstat(b, &y) == 0 && x.st_dev == y.st_dev && x.st_ino == y.st_ino
    }

    /// Whether a path is the file at another under a second name, or a symlink to it: what took a copy's place.
    static func isLink(_ path: String, to kept: String) -> Bool {
        if isSameFile(path, kept) { return true }
        var s = stat()
        guard lstat(path, &s) == 0, s.st_mode & S_IFMT == S_IFLNK else { return false }
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == kept
    }

    /// Every byte of two files, read side by side past the file cache, so what you have open stays fast.
    static func sameBytes(_ a: String, _ b: String, stop: LockedFlag? = nil) throws -> Bool {
        let fa = open(a, O_RDONLY | O_NOFOLLOW | O_CLOEXEC), fb = open(b, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        defer {
            if fa >= 0 { close(fa) }
            if fb >= 0 { close(fb) }
        }
        guard fa >= 0, fb >= 0 else { return false }
        _ = fcntl(fa, F_NOCACHE, 1)
        _ = fcntl(fb, F_NOCACHE, 1)
        let size = 4 << 20
        let x = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16384)
        let y = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16384)
        defer {
            x.deallocate()
            y.deallocate()
        }
        func fill(_ fd: Int32, _ buffer: UnsafeMutableRawPointer) -> Int {
            var got = 0
            while got < size {
                let n = read(fd, buffer + got, size - got)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return n < 0 ? -1 : got }
                got += n
            }
            return got
        }
        while true {
            if stop?.value == true { throw Failure.stopped }
            let n = fill(fa, x), m = fill(fb, y)
            if n < 0 || n != m { return false }
            if n == 0 { return true }
            if memcmp(x, y, n) != 0 { return false }
        }
    }

    /// Only for something this app moved to the Trash. Anything else in there is left alone. Says whether it was deleted.
    @discardableResult
    static func deleteForGood(_ thing: CleanedThing) throws -> Bool {
        if let root = onlyInside, !PathMath.isInside(thing.inTrash, root) { throw Failure.notAllowed }
        guard isInTrash(thing.inTrash) else { throw Failure.notAllowed }
        guard FileManager.default.fileExists(atPath: thing.inTrash), isStillThat(thing) else { return false }
        try FileManager.default.removeItem(atPath: thing.inTrash)
        return true
    }

    /// Whether something is in a Trash: inside your own, or inside a disk's folder for one person. Never a Trash folder
    /// itself, and never a folder that's only called `.Trash` somewhere deeper: this is the last check before a file is
    /// deleted for good.
    static func isInTrash(_ path: String) -> Bool {
        guard let folder = trashFolder(holding: path) else { return false }
        return PathMath.visible(path).count > folder.count + 1
    }

    /// Whether this is a Trash folder itself.
    static func isTrashFolder(_ path: String) -> Bool {
        trashFolder(holding: path) == PathMath.visible(path)
    }

    /// The Trash folder a path is in, or is: `~/.Trash`, or `.Trashes/<person>` at the top of a disk. The folder the
    /// checks are held to has the same two at its top.
    private static func trashFolder(holding path: String) -> String? {
        let path = PathMath.visible(path)
        var own = [NSHomeDirectory()], shared = [""]
        if let root = onlyInside {
            own.append(root)
            shared.append(root)
        }
        let parts = path.split(separator: "/")
        if parts.count >= 2, parts[0] == "Volumes" { shared.append("/Volumes/" + parts[1]) }
        for top in own where PathMath.isInside(path, top + "/.Trash") { return top + "/.Trash" }
        for top in shared where path.hasPrefix(top + "/.Trashes/") {
            if let person = path.dropFirst(top.count + "/.Trashes/".count).split(separator: "/").first { return top + "/.Trashes/" + person }
        }
        return nil
    }

    /// Where your own things are, in the Trash folder that was planned. On other disks that's a folder per person.
    static func yourTrash(in planned: String) -> String {
        planned.hasSuffix("/.Trashes") ? planned + "/\(getuid())" : planned
    }

    /// What's in this Trash right now.
    static func trashContents(_ planned: String) -> [String] {
        let folder = yourTrash(in: planned)
        guard isTrashFolder(folder), let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        return names.filter { $0 != ".DS_Store" }.map { folder + "/" + $0 }
    }

    /// What was in the Trash when you said it could go. Anything thrown away since then stays. Returns how many couldn't be
    /// removed.
    static func deleteFromTrash(_ paths: [String]) -> Int {
        var failed = 0
        for path in paths {
            if let root = onlyInside, !PathMath.isInside(path, root) { continue }
            guard isInTrash(path) else { continue }
            do { try FileManager.default.removeItem(atPath: path) } catch { failed += 1 }
        }
        return failed
    }

    /// What makes a disk this disk, whatever it's called.
    static func diskID(of path: String) -> String? {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    static func diskName(of path: String) -> String {
        (PathMath.mount(of: path) as NSString).lastPathComponent
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The real path of a folder that may not exist yet: as much of it as does, plus the rest.
    private static func realPathOfFolder(_ folder: String) -> String {
        var existing = folder
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing), existing.count > 1 {
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        return rest.reduce(realPath(existing)) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// Whether moving this into that folder would land on itself or inside itself.
    static func moveIsOntoItself(_ path: String, into folder: String) -> Bool {
        let source = realPath(path)
        let target = realPathOfFolder(folder)
        return (source as NSString).deletingLastPathComponent == target || PathMath.isInside(target, source)
    }

    // MARK: Moving to another disk

    /// How far a move has got.
    struct MoveProgress: Sendable {
        var bytesDone: UInt64
        var bytesTotal: UInt64
        var file: String
    }

    /// Copies this into the folder, checks every byte against the original, and only then gives it its real name. If it
    /// stops halfway, nothing of the original has been touched and no half-copied file is left under a real name.
    static func copyAndVerify(_ path: String, into folder: String, stop: LockedFlag, progress: @escaping @Sendable (MoveProgress) -> Void) throws {
        if let root = onlyInside, !PathMath.isInside(path, root) || !PathMath.isInside(folder, root) { throw Failure.notAllowed }
        // Onto itself would "succeed" and then send the only copy to the Trash.
        if moveIsOntoItself(path, into: folder) { throw Failure.sameFile }
        let fm = FileManager.default
        let name = (path as NSString).lastPathComponent
        let target = folder + "/" + name
        let total = Walker.size(of: path)
        var done: UInt64 = 0
        var lastFile: String?
        guard fm.fileExists(atPath: path) else { throw Failure.notAllowed }
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var disk = statfs()
        var keepsAttributes = true
        if statfs(folder, &disk) == 0 {
            let type = withUnsafePointer(to: &disk.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
            keepsAttributes = type == "apfs" || type == "hfs"
        }

        func copyOne(_ from: String, _ to: String) throws {
            var info = stat()
            // Something that can't even be looked at can't be said to have been copied.
            guard lstat(from, &info) == 0 else { throw POSIXError(.EACCES) }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFLNK {
                if fm.fileExists(atPath: to) { return }
                let destination = try fm.destinationOfSymbolicLink(atPath: from)
                try fm.createSymbolicLink(atPath: to, withDestinationPath: destination)
                return
            }
            if kind == S_IFDIR {
                try fm.createDirectory(atPath: to, withIntermediateDirectories: true)
                for child in try fm.contentsOfDirectory(atPath: from) {
                    if stop.value { throw Failure.stopped }
                    try copyOne(from + "/" + child, to + "/" + child)
                }
                // Its date, now that nothing more will change it.
                _ = copyfile(from, to, nil, copyfile_flags_t(COPYFILE_STAT))
                return
            }
            guard kind == S_IFREG else { return }
            // Exactly the same file is already there: nothing to copy. Anything else with that name is never replaced.
            if fm.fileExists(atPath: to) {
                // The very same file, reached another way, is not a copy of it.
                if identity(of: to) == identity(of: from) { throw Failure.sameFile }
                if try hash(to) == hash(from) {
                    done &+= UInt64(info.st_size)
                    progress(MoveProgress(bytesDone: done, bytesTotal: total, file: (from as NSString).lastPathComponent))
                    // A copy that stopped halfway may have left this without making sure of it.
                    lastFile = to
                    return
                }
                throw Failure.wouldOverwrite(to)
            }
            let temporary = to + ".headroom-partial"
            try? fm.removeItem(atPath: temporary)
            do {
                let sourceHash = try copyHashing(from, temporary) { count in
                    done &+= UInt64(count)
                    progress(MoveProgress(bytesDone: done, bytesTotal: total, file: (from as NSString).lastPathComponent))
                    return !stop.value
                }
                // Read back what actually reached the disk, not what's in memory.
                forgetCachedCopy(temporary)
                guard try hash(temporary, uncached: true) == sourceHash else { throw Failure.copyDidNotMatch(from) }
                // Dates and permissions always. Extended attributes only where the disk can hold them, or they
                // become a litter of ._ files.
                _ = copyfile(from, temporary, nil, copyfile_flags_t(keepsAttributes ? COPYFILE_METADATA : COPYFILE_STAT))
                try fm.moveItem(atPath: temporary, toPath: to)
                lastFile = to
            } catch {
                try? fm.removeItem(atPath: temporary)
                throw error
            }
        }
        try copyOne(path, target)
        if let lastFile { try flushToDisk(lastFile) }
    }

    private static func copyHashing(_ from: String, _ to: String, onChunk: (Int) -> Bool) throws -> SHA256Digest {
        let source = open(from, O_RDONLY)
        guard source >= 0 else { throw POSIXError(.EIO) }
        defer { close(source) }
        let target = open(to, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard target >= 0 else { throw POSIXError(.EEXIST) }
        defer { close(target) }
        var hasher = SHA256()
        let size = 8 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 4096)
        defer { buffer.deallocate() }
        while true {
            let count = read(source, buffer, size)
            if count < 0 { throw POSIXError(.EIO) }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            var written = 0
            while written < count {
                let n = write(target, buffer + written, count - written)
                if n <= 0 { throw POSIXError(.ENOSPC) }
                written += n
            }
            if !onChunk(count) { throw Failure.stopped }
        }
        // On its way to the disk, so that it can be read back. `flushToDisk` makes sure of all of it once at the end.
        if fsync(target) != 0 { throw POSIXError(.EIO) }
        return hasher.finalize()
    }

    /// Everything written so far is on the disk for good when this returns. It makes the disk empty its own cache, which takes
    /// about 10 ms and covers every file, so once for a whole copy is enough. For each of many small files it would be nine
    /// tenths of the work. Nothing goes to the Trash until this has happened.
    private static func flushToDisk(_ path: String) throws {
        let file = open(path, O_RDONLY)
        guard file >= 0 else { throw POSIXError(.EIO) }
        defer { close(file) }
        // Not every disk can do the full version of this, but something has to reach the disk.
        if fcntl(file, F_FULLFSYNC) != 0, fsync(file) != 0 { throw POSIXError(.EIO) }
    }

    /// Asks macOS to drop what it remembers of this file, so the next read comes from the disk itself.
    private static func forgetCachedCopy(_ path: String) {
        let file = open(path, O_RDONLY)
        guard file >= 0 else { return }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_size > 0 else { return }
        let size = Int(info.st_size)
        guard let map = mmap(nil, size, PROT_READ, MAP_SHARED, file, 0), map != UnsafeMutableRawPointer(bitPattern: -1) else { return }
        msync(map, size, MS_INVALIDATE)
        munmap(map, size)
    }

    private static func hash(_ path: String, uncached: Bool = false) throws -> SHA256Digest {
        let file = open(path, O_RDONLY)
        guard file >= 0 else { throw POSIXError(.EIO) }
        defer { close(file) }
        if uncached { _ = fcntl(file, F_NOCACHE, 1) }
        var hasher = SHA256()
        let size = 8 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 4096)
        defer { buffer.deallocate() }
        while true {
            let count = read(file, buffer, size)
            if count < 0 { throw POSIXError(.EIO) }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
        }
        return hasher.finalize()
    }
}
