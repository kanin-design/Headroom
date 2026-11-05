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

    private func first(in list: [(path: String, holder: Holder)], under folder: String) -> Holder? {
        let target = Self.visible(folder)
        var low = 0, high = list.count
        while low < high {
            let middle = (low + high) / 2
            if list[middle].path < target { low = middle + 1 } else { high = middle }
        }
        var at = low
        while at < list.count, list[at].path.hasPrefix(target) {
            if PathMath.isInside(list[at].path, target) { return list[at].holder }
            at += 1
        }
        return nil
    }

    /// Something running that holds a file open inside this folder, or that runs from it.
    func holder(of path: String) -> Holder? {
        first(in: running, under: path) ?? first(in: open, under: path)
    }

    func isRunning(under path: String) -> Holder? { first(in: running, under: path) }

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
    case inUse(process: String, pid: pid_t)
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
        case .gone: "It's already gone."
        case .someGone(let n): "\(n) of these \(n == 1 ? "is" : "are") already gone."
        case .protected: "macOS protects this, so it can't be moved."
        case .appOpen(let name, _): "\(name) is open."
        case .inUse(let process, _): "\(process) has something open in here."
        case .someInUse(let n, let process): "\(n) \(n == 1 ? "is" : "are") in use by \(process) and will stay for now."
        case .changed(let date): "It changed \(Self.ago(date)), after you selected it."
        case .noGain(let other): "You'd get nothing back: \(other) holds the same files."
        case .linkedOutOfSight(let bytes): "\(formatBytes(bytes)) of this also exists somewhere Headroom isn't allowed to look, so you may get less back."
        case .diskMissing(let name): "\(name) isn't plugged in. It stays selected."
        case .differentDisk(let name): "This \(name) isn't the disk you selected this on, so nothing on it will be touched."
        case .alreadyThere: "It's already in that folder, so there's nothing to move."
        case .noRoom(let needed, let free): "It needs \(formatBytes(needed)), and that disk has \(formatBytes(free)) free."
        case .tooBigForDisk(let name): "\(name) can't hold files over 4 GB."
        case .needsPassword: "macOS will ask for your password for this one."
        case .couldntGo(let why, _): why
        }
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
    static func run(items: [PlanItem], trueBytes: [String: UInt64], otherCopy: [String: (title: String, bytes: UInt64)], runningApps: [RunningApp], fullAccess: Bool = true) -> [String: ItemCheck] {
        let open = OpenFiles.snapshot()
        var out: [String: ItemCheck] = [:]
        let fm = FileManager.default
        for item in items {
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
            } else {
                // Busy things stay for now. In a list of many, the rest still go.
                var busy: [(String, OpenFiles.Holder)] = []
                for path in present {
                    if let holder = open.holder(of: path) { busy.append((path, holder)) }
                }
                if let first = busy.first {
                    if busy.count == present.count {
                        check.problems.append(.inUse(process: first.1.process, pid: first.1.pid))
                    } else {
                        check.problems.append(.someInUse(busy.count, process: first.1.process))
                    }
                    check.heldPaths = busy.map(\.0)
                }
            }
            // What rebuilds itself changes all the time. Anything else that changed since you planned it might be back in use.
            if item.tier >= .redownload || item.byHand {
                var newest: Date?
                for path in present { newest = max(newest ?? .distantPast, Walker.newestChange(in: path, limit: 40_000)) }
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
                    let needed = present.reduce(UInt64(0)) { $0 &+ Walker.size(of: $1) }
                    if facts.free < needed { check.problems.append(.noRoom(needed: needed, free: facts.free)) }
                    var info = statfs()
                    if statfs(mount, &info) == 0 {
                        let type = withUnsafePointer(to: &info.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
                        if type == "msdos", present.contains(where: { Walker.largestFile(in: $0) >= 4 << 30 }) {
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
                let linked = present.reduce(UInt64(0)) { $0 &+ Walker.linkedBytes(in: $1) }
                if linked >= 50_000_000 { check.problems.append(.linkedOutOfSight(linked)) }
            }
            out[item.id] = check
        }
        return out
    }
}

/// A look inside a folder, with a limit, so a huge one can't hold anything up.
enum Walker {
    static func newestChange(in path: String, limit: Int) -> Date {
        var newest: time_t = 0
        var seen = 0
        walk(path, &seen, limit) { info, _ in newest = max(newest, info.st_mtimespec.tv_sec) }
        return Date(timeIntervalSince1970: TimeInterval(newest))
    }

    static func size(of path: String) -> UInt64 {
        var total: UInt64 = 0
        var seen = 0
        walk(path, &seen, 2_000_000) { info, _ in total &+= UInt64(info.st_size) }
        return total
    }

    /// How much in here also has another name somewhere.
    static func linkedBytes(in path: String) -> UInt64 {
        var total: UInt64 = 0
        var seen = 0
        walk(path, &seen, 40_000) { info, _ in
            if info.st_mode & S_IFMT == S_IFREG, info.st_nlink > 1 { total &+= UInt64(info.st_blocks) * 512 }
        }
        return total
    }

    static func largestFile(in path: String) -> UInt64 {
        var largest: UInt64 = 0
        var seen = 0
        walk(path, &seen, 200_000) { info, _ in largest = max(largest, UInt64(info.st_size)) }
        return largest
    }

    private static func walk(_ path: String, _ seen: inout Int, _ limit: Int, _ visit: (stat, String) -> Void) {
        guard seen < limit else { return }
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        seen += 1
        visit(info, path)
        guard info.st_mode & S_IFMT == S_IFDIR, let dir = opendir(path) else { return }
        defer { closedir(dir) }
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } }
            if name == "." || name == ".." { continue }
            walk(path + "/" + name, &seen, limit, visit)
            if seen >= limit { return }
        }
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
    fileprivate static func moveToTrash(_ path: String) throws -> String {
        var place = try run([
            "on run argv",
            "set thing to POSIX file (item 1 of argv) as alias",
            "with timeout of 600 seconds",
            "tell application \"Finder\" to set place to (delete thing) as alias",
            "end timeout",
            "return POSIX path of place",
            "end run",
        ], [path])
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
    private static func run(_ lines: [String], _ arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = lines.flatMap { ["-e", $0] } + arguments
        let output = Pipe()
        let errors = Pipe()
        task.standardOutput = output
        task.standardError = errors
        try task.run()
        let said = output.fileHandleForReading.readDataToEndOfFile()
        let complaint = errors.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
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
    static func trash(_ path: String, step: PlanStep = .trash) throws -> (place: String, identity: String?) {
        guard mayTouch(path, step: step) else { throw Failure.notAllowed }
        func throughFinder() throws -> (place: String, identity: String?) {
            let place = try FinderAsk.moveToTrash(path)
            return (place, identity(of: place))
        }
        if step == .uninstall, path.hasSuffix(".app") { return try throughFinder() }
        do {
            var result: NSURL?
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
            let place = result?.path ?? ""
            return (place, identity(of: place))
        } catch let error where isNoPermission(error) {
            return try throughFinder()
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
            return .couldntGo("macOS stopped Headroom from asking the Finder to move this. You can allow it in System Settings.", askSettings: true)
        case FinderAsk.Failure.cancelled:
            return .couldntGo("You cancelled, so it stayed.", askSettings: false)
        case FinderAsk.Failure.failed(let text):
            return .couldntGo("The Finder couldn't move this: \(text)", askSettings: false)
        case Failure.notAllowed:
            return .couldntGo("macOS protects this, so it can't be moved.", askSettings: false)
        case Failure.wouldOverwrite:
            return .couldntGo("Something with that name is already there, so it stayed.", askSettings: false)
        case Failure.copyDidNotMatch:
            return .couldntGo("The copy didn't match the original, so the original stayed.", askSettings: false)
        case Failure.sameFile:
            return .couldntGo("It's already there, so there's nothing to move.", askSettings: false)
        case Failure.stopped:
            return .couldntGo("You stopped it before this was done.", askSettings: false)
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

    /// Puts something back where it was. It never replaces what's there now.
    static func putBack(_ thing: CleanedThing) throws {
        if let root = onlyInside, !PathMath.isInside(thing.original, root) { throw Failure.notAllowed }
        let fm = FileManager.default
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

    /// Only for something this app moved to the Trash. Anything else in there is left alone. Says whether it was deleted.
    @discardableResult
    static func deleteForGood(_ thing: CleanedThing) throws -> Bool {
        if let root = onlyInside, !PathMath.isInside(thing.inTrash, root) { throw Failure.notAllowed }
        guard isInTrash(thing.inTrash) else { throw Failure.notAllowed }
        guard FileManager.default.fileExists(atPath: thing.inTrash), isStillThat(thing) else { return false }
        try FileManager.default.removeItem(atPath: thing.inTrash)
        return true
    }

    static func isInTrash(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        return parts.contains(".Trash") || parts.contains(".Trashes")
    }

    /// Where your own things are, in the Trash folder that was planned. On other disks that's a folder per person.
    static func yourTrash(in planned: String) -> String {
        planned.hasSuffix("/.Trashes") ? planned + "/\(getuid())" : planned
    }

    /// What's in this Trash right now.
    static func trashContents(_ planned: String) -> [String] {
        let folder = yourTrash(in: planned)
        guard isInTrash(folder), let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
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
            } catch {
                try? fm.removeItem(atPath: temporary)
                throw error
            }
        }
        try copyOne(path, target)
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
        // Not every disk can do the full version of this, but something has to reach the disk.
        if fcntl(target, F_FULLFSYNC) != 0, fsync(target) != 0 { throw POSIXError(.EIO) }
        return hasher.finalize()
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
