import CoreServices
import Foundation

/// macOS keeps a journal of which folders change on each disk, and it lasts across restarts. A map notes where the journal
/// was when its reading began. A refresh asks what has changed since, and only reads those folders again.
enum ChangeJournal {
    /// A place in one disk's journal: the event it had got to, which journal that was, and when. A disk whose journal was
    /// started afresh has a new one, and then nothing from the old one counts.
    struct Place: Codable, Equatable, Sendable {
        var event: UInt64
        var journal: String
        /// Seconds since 1970.
        var time: Double
    }

    /// What has changed since a place: folders whose own contents changed, and folders anything under which may have.
    struct Changes: Sendable {
        var folders: Set<String> = []
        var everythingUnder: Set<String> = []
    }

    /// Where the journal is now, for the disk holding `path`.
    static func now(for path: String) -> Place? {
        var info = stat()
        guard lstat(path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        return Place(event: FSEventsGetCurrentEventId(), journal: CFUUIDCreateString(nil, uuid) as String, time: Date().timeIntervalSince1970)
    }

    /// How many events the journal has had since `place`, or nil if it's another journal now. Going back through them costs
    /// about a second per million on a busy Mac, so past a point, reading the disk is quicker.
    static func distance(from place: Place, for path: String) -> UInt64? {
        guard let current = now(for: path), current.journal == place.journal, place.event <= current.event else { return nil }
        return current.event - place.event
    }

    /// The journal names folders the way you see them, so the Data volume's own paths lose their prefix to ask about them,
    /// and get it back in what comes back.
    static let dataPrefix = "/System/Volumes/Data"
    static func visible(_ path: String) -> String { path.hasPrefix(dataPrefix + "/") ? String(path.dropFirst(dataPrefix.count)) : path }

    /// The folders to watch for a map: the ones its scan started from.
    static func roots(of tree: DiskTree) -> [String] { tree.anchors.map { visible($0.path) }.sorted() }

    /// Collects what changes on a disk from a place onwards, for as long as it runs: first what the journal already holds
    /// since then, then each change as it happens. A refresh takes what has been collected, and collecting carries on from
    /// there for the next one.
    final class Watcher: @unchecked Sendable {
        let roots: [String]
        /// Past this many folders, reading everything is quicker than reading them all again, so it stops keeping them.
        private static let most = 100_000
        private let lock = NSLock()
        private var stream: FSEventStreamRef?
        private let queue = DispatchQueue(label: "change journal")
        private let historyRead = DispatchSemaphore(value: 0)
        // On `queue`.
        private var collected = Changes()
        private var lostTrack = false
        private var historyDone = false
        private var from: Place

        /// Nil when the journal isn't the one `place` is in, or can't be watched.
        init?(from place: Place, roots: [String]) {
            guard let root = roots.first, let current = ChangeJournal.now(for: root), current.journal == place.journal,
                  place.event <= current.event else { return nil }
            self.roots = roots
            from = place
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
            guard let stream = FSEventStreamCreate(nil, Self.callback, &context, roots as CFArray, place.event, 0.5, flags) else { return nil }
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                return nil
            }
            self.stream = stream
        }

        /// From now on.
        static func starting(roots: [String]) -> Watcher? {
            guard let root = roots.first, let place = ChangeJournal.now(for: root) else { return nil }
            return Watcher(from: place, roots: roots)
        }

        deinit { stop() }

        /// The place the changes it holds are counted from.
        var base: Place { queue.sync { from } }

        /// Whether it has caught up with what the journal held when it started.
        func waitForHistory(timeout: TimeInterval) -> Bool {
            queue.sync { historyDone } || historyRead.wait(timeout: .now() + timeout) == .success
        }

        /// What changed since `base`, which has to be `place`, and the place the next lot is counted from, which becomes
        /// `base`. Nil when it lost track along the way, or another refresh took this lot first, and then everything has to
        /// be read.
        func take(from place: Place) -> (changes: Changes, next: Place)? {
            lock.lock()
            defer { lock.unlock() }
            guard let stream, queue.sync(execute: { from == place }), let root = roots.first, let next = ChangeJournal.now(for: root) else { return nil }
            // Everything up to now is handed over before the lot is taken.
            FSEventStreamFlushSync(stream)
            return queue.sync {
                defer {
                    collected = Changes()
                    lostTrack = false
                    from = next
                }
                return lostTrack || next.journal != from.journal ? nil : (collected, next)
            }
        }

        func stop() {
            lock.lock()
            defer { lock.unlock() }
            guard let stream else { return }
            self.stream = nil
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            // Whatever was being handed over has been.
            queue.sync {}
            FSEventStreamRelease(stream)
        }

        private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            for i in 0..<count {
                let flag = flags[i]
                if flag & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                    if !watcher.historyDone {
                        watcher.historyDone = true
                        watcher.historyRead.signal()
                    }
                    continue
                }
                if flag & UInt32(kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged) != 0 {
                    watcher.lostTrack = true
                    continue
                }
                guard !watcher.lostTrack, var path = list[i] as? String else { continue }
                while path.count > 1, path.hasSuffix("/") { path.removeLast() }
                if watcher.collected.folders.count + watcher.collected.everythingUnder.count >= most {
                    watcher.lostTrack = true
                    watcher.collected = Changes()
                    continue
                }
                if flag & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                    watcher.collected.everythingUnder.insert(path)
                } else {
                    watcher.collected.folders.insert(path)
                }
            }
        }
    }
}
