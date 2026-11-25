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

    /// Every process is asked about each file it has open, one call a file: thousands of calls, so the processes are shared
    /// out over the cores. What each says is put together in the order the system listed them, as when one thread asked.
    static func snapshot() -> OpenFiles {
        var out = OpenFiles()
        let me = getpid()
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return out }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard found > 0 else { return out }
        let asked = pids.prefix(Int(found)).filter { $0 > 0 && $0 != me }
        let share = 8
        var said = [Said](repeating: Said(), count: asked.count)
        said.withUnsafeMutableBufferPointer { said in
            // Each share writes only its own places.
            nonisolated(unsafe) let said = said
            DispatchQueue.concurrentPerform(iterations: (asked.count + share - 1) / share) { part in
                var buffer = [CChar](repeating: 0, count: 4096)
                var fds: [proc_fdinfo] = []
                for i in (part * share)..<min((part + 1) * share, asked.count) { said[i] = ask(asked[i], &buffer, &fds) }
            }
        }
        for one in said {
            if let running = one.running { out.running.append(running) }
            out.open.append(contentsOf: one.open)
        }
        out.open.sort { $0.path < $1.path }
        out.running.sort { $0.path < $1.path }
        return out
    }

    /// What one process runs from and has open.
    private struct Said {
        var running: (path: String, holder: Holder)?
        var open: [(path: String, holder: Holder)] = []
    }

    private static func ask(_ pid: pid_t, _ buffer: inout [CChar], _ fds: inout [proc_fdinfo]) -> Said {
        var said = Said()
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return said }
        let executable = PathMath.visible(String(cString: buffer))
        let holder = Holder(process: Self.name(of: executable), pid: pid)
        said.running = (executable, holder)
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return said }
        let room = Int(size) / MemoryLayout<proc_fdinfo>.stride
        if fds.count < room { fds = [proc_fdinfo](repeating: proc_fdinfo(), count: room) }
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(room * MemoryLayout<proc_fdinfo>.stride))
        guard used > 0 else { return said }
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else {
                continue
            }
            // As you'd write it first: a path that comes with the data volume's prefix is under /Users all the same.
            let path = PathMath.visible(
                withUnsafePointer(to: &info.pvip.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) } })
            if path.hasPrefix("/Users/") || path.hasPrefix("/Volumes/") || path.hasPrefix("/Applications/") { said.open.append((path, holder)) }
        }
        return said
    }

    /// A process goes by the app it's part of, not its helper's name.
    private static func name(of executable: String) -> String {
        for part in executable.split(separator: "/") where part.hasSuffix(".app") {
            return String(part.dropLast(4))
        }
        return (executable as NSString).lastPathComponent
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
        let target = PathMath.visible(folder)
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

/// Why something planned can't go now, or what's worth knowing before it does.
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
    /// Too many files to read through, so whether any changed since it was selected isn't known.
    case tooManyToCheck
    /// It isn't yours to move, so macOS will ask for your password when it goes.
    case needsPassword
    /// The last clean tried and it didn't go. It waits for you to say try again, so one stubborn thing can't keep failing.
    case couldntGo(String, askSettings: Bool)

    /// Whether this stops it for now. It stays planned, and everything else goes ahead.
    var holdsBack: Bool {
        switch self {
        case .gone, .someGone, .someInUse, .noGain, .linkedOutOfSight, .needsPassword, .tooManyToCheck: false
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
        case .tooManyToCheck: "Too many files to check for changes."
        case .needsPassword: "Requires your password."
        case .couldntGo(let why, _): why
        }
    }

    private static func inUseText(_ process: String, others: Int, runFromHere: Bool) -> String {
        let who = others == 0 ? process : "\(process) and \(others) more"
        let doing =
            runFromHere
            ? (others == 0 ? "is running from here" : "are running from here") : (others == 0 ? "has a file open here" : "have files open here")
        return "\(who) \(doing)."
    }

    private static func ago(_ date: Date) -> String { LastUse.ago(date, now: Date()) }
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

    /// How far the look inside a planned thing goes. While you're ticking things, or coming back to the list, a quick look
    /// will do. The look before a clean, or at something that's about to be copied whole, reads all of it.
    private static func lookLimit(for item: PlanItem, thorough: Bool) -> Int { thorough || item.isMove ? Walker.most : Walker.quick }

    /// Looks at every planned thing as it is right now. Nothing is changed.
    /// `otherCopy` names what else holds the same files, and how much.
    /// A `fresh` check looks at everything again. The rest are for while you're ticking things, when a look from a moment ago is
    /// as good as a new one. A `thorough` one is the last look before things go: it reads all of a folder to see whether
    /// anything in it changed, however long that takes, where the others stop after a quick look.
    static func run(
        items: [PlanItem], trueBytes: [String: UInt64], otherCopy: [String: (title: String, bytes: UInt64)], runningApps: [RunningApp],
        fullAccess: Bool = true, fresh: Bool = true,
        thorough: Bool = false
    ) -> [String: ItemCheck] {
        let open = OpenFiles.snapshot()
        var out: [String: ItemCheck] = [:]
        let fm = FileManager.default
        let maxAge: TimeInterval = fresh ? 0 : 60
        // Whether anything changed inside each planned folder: all of them read at once, before they're gone through.
        var looked: [String: Walker.Look] = [:]
        for limit in [Walker.quick, Walker.most] {
            let paths = items.filter {
                !$0.isEmptyTrash && ($0.tier >= .redownload || $0.byHand) && Self.lookLimit(for: $0, thorough: thorough) == limit
            }
            .flatMap(\.paths)
            guard !paths.isEmpty, !Task.isCancelled else { continue }
            for (path, look) in zip(paths, Walker.recentLooks(at: paths, limit: limit, maxAge: maxAge)) { looked[path] = look }
        }
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
                        check.problems.append(
                            .inUse(process: users.first.process, pid: users.first.pid, others: users.others, runFromHere: users.runFromHere))
                    } else {
                        check.problems.append(.someInUse(busy.count, process: users.first.process))
                    }
                    check.heldPaths = busy.map(\.path)
                }
            }
            // What rebuilds itself changes all the time. Anything else that changed since you planned it might be back in use.
            if item.tier >= .redownload || item.byHand {
                var newest: Date?
                var sawAll = true
                let limit = lookLimit(for: item, thorough: thorough)
                for path in present {
                    let look = looked[path] ?? Walker.recentLook(at: path, limit: limit, maxAge: maxAge)
                    newest = max(newest ?? .distantPast, look.newestDate)
                    if !look.complete { sawAll = false }
                }
                if let newest, newest > item.addedAt.addingTimeInterval(120), newest > (item.acceptedChange ?? .distantPast) {
                    check.problems.append(.changed(newest))
                } else if !sawAll, limit == Walker.most {
                    check.problems.append(.tooManyToCheck)
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
                    let needed = present.reduce(UInt64(0)) { $0 &+ Walker.recentLook(at: $1, limit: Walker.most, maxAge: max(maxAge, 1)).size }
                    if facts.free < needed { check.problems.append(.noRoom(needed: needed, free: facts.free)) }
                    if DriveInfo.fileSystem(at: mount) == "msdos",
                        present.contains(where: { Walker.recentLook(at: $0, limit: Walker.most, maxAge: max(maxAge, 1)).largestFile >= 4 << 30 })
                    {
                        check.problems.append(.tooBigForDisk((mount as NSString).lastPathComponent))
                    }
                }
            }
            if let other = otherCopy[item.id], let bytes = trueBytes[item.id], Double(bytes) < Double(other.bytes) * 0.02 {
                check.problems.append(.noGain(other: other.title))
            }
            // Without Full Disk Access the other copy may be in a folder that couldn't be read, so the map can't know.
            // A planned other copy has its links by definition: it's the one half of a pair the map already knows about.
            if !fullAccess, otherCopy[item.id] == nil, !item.isOtherCopy {
                let linked = present.reduce(UInt64(0)) { $0 &+ Walker.recentLook(at: $1, limit: 40_000, maxAge: max(maxAge, 1)).linkedBytes }
                if linked >= 50_000_000 { check.problems.append(.linkedOutOfSight(linked)) }
            }
            out[item.id] = check
        }
        return out
    }
}
