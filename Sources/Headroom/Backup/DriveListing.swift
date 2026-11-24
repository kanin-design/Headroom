import Foundation

/// What Backup last read on a drive, so the drive's half can be drawn while it's unplugged. One per drive, by the drive's
/// own ID, with every file's size and date and when each folder was read.
struct DriveListing: Codable, Equatable {
    struct File: Codable, Equatable {
        /// What the file says it holds, which is what's compared, and the space it takes, which is what's drawn.
        var size: UInt64
        var allocated: UInt64
        var modified: UInt32
    }

    /// By path from the drive's top.
    var files: [String: File] = [:]
    /// The folders that were read, from the drive's top, and when.
    var folders: [String: Date] = [:]

    /// When this folder, or one it's in, was last read. Nil when it never was.
    func readAt(_ folder: String) -> Date? {
        var path = folder
        while true {
            if let date = folders[path] { return date }
            if path.isEmpty { return nil }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    /// The files under a folder, by their path from it.
    func files(under folder: String) -> [String: File] {
        let prefix = folder.isEmpty ? "" : folder + "/"
        var out: [String: File] = [:]
        for (path, file) in files where folder.isEmpty || path.hasPrefix(prefix) { out[String(path.dropFirst(prefix.count))] = file }
        return out
    }

    /// What was just read under a folder takes the place of what was known there.
    mutating func replace(under folder: String, with found: [String: File], at date: Date) {
        let prefix = folder.isEmpty ? "" : folder + "/"
        files = files.filter { !(folder.isEmpty || $0.key.hasPrefix(prefix)) }
        for (rel, file) in found { files[prefix + rel] = file }
        folders = folders.filter { !(folder.isEmpty || $0.key == folder || $0.key.hasPrefix(prefix)) }
        folders[folder] = date
    }
}

enum DriveListings {
    private static let lock = NSLock()
    /// Where they're kept. Tests keep theirs somewhere of their own.
    nonisolated(unsafe) static var folder = AppData.folder.appendingPathComponent("drives", isDirectory: true)

    private static func url(for drive: String) -> URL {
        let safe = drive.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return folder.appendingPathComponent(String(safe) + ".json")
    }

    static func load(_ drive: String) -> DriveListing? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url(for: drive)) else { return nil }
        return try? JSONDecoder().decode(DriveListing.self, from: data)
    }

    /// Every file under a folder on a drive, by its path from the folder, leaving out what macOS and Headroom keep there for
    /// themselves. Nil when it was stopped. Folders are read side by side, as reading one waits on the drive.
    static func read(_ folder: String, stop: LockedFlag? = nil) -> [String: DriveListing.File]? {
        let walk = FolderWalk(top: folder)
        DispatchQueue.concurrentPerform(iterations: walk.workers) { _ in walk.work(stop: stop) }
        return stop?.value == true ? nil : walk.found
    }

    /// Reads a drive's folders on several threads: each takes a folder that's waiting, reads what's in it, and leaves the
    /// folders it found inside for whichever is free. It's done when nothing is waiting and nobody is reading.
    private final class FolderWalk: @unchecked Sendable {
        private static let skip: Set<String> = [
            ".DS_Store", ".Trashes", ".fseventsd", ".Spotlight-V100", ".TemporaryItems", ".DocumentRevisions-V100",
        ]
        let workers = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        private let condition = NSCondition()
        private var waiting: [(path: String, rel: String)]
        private var reading = 0
        private var parts: [[String: DriveListing.File]] = []

        init(top: String) { waiting = [(top, "")] }

        /// What every thread found, together.
        var found: [String: DriveListing.File] {
            var all: [String: DriveListing.File] = [:]
            all.reserveCapacity(parts.reduce(0) { $0 + $1.count })
            for part in parts { all.merge(part) { first, _ in first } }
            return all
        }

        func work(stop: LockedFlag?) {
            var mine: [String: DriveListing.File] = [:]
            while let (path, rel) = next() {
                var inside: [(path: String, rel: String)] = []
                if stop?.value != true, let names = try? FileManager.default.contentsOfDirectory(atPath: path) {
                    for name in names {
                        if stop?.value == true { break }
                        if Self.skip.contains(name) || name.hasPrefix("._") || name.hasSuffix(".hrpart") { continue }
                        let full = path + "/" + name
                        let here = rel.isEmpty ? name : rel + "/" + name
                        var info = stat()
                        guard lstat(full, &info) == 0 else { continue }
                        let kind = info.st_mode & S_IFMT
                        if kind == S_IFDIR {
                            inside.append((full, here))
                        } else if kind == S_IFREG {
                            mine[here] = DriveListing.File(
                                size: UInt64(max(info.st_size, 0)), allocated: UInt64(max(info.st_blocks, 0)) * 512,
                                modified: UInt32(clamping: Int(info.st_mtimespec.tv_sec)))
                        }
                    }
                }
                done(adding: stop?.value == true ? [] : inside)
            }
            condition.lock()
            parts.append(mine)
            condition.unlock()
        }

        /// A folder to read, or nil when there are none left and none still being read.
        private func next() -> (String, String)? {
            condition.lock()
            defer { condition.unlock() }
            while waiting.isEmpty {
                if reading == 0 { return nil }
                condition.wait()
            }
            reading += 1
            return waiting.removeLast()
        }

        private func done(adding folders: [(path: String, rel: String)]) {
            condition.lock()
            waiting.append(contentsOf: folders)
            reading -= 1
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Keeps what was read under a folder of a drive.
    static func record(_ drive: String, folder: String, files: [String: DriveListing.File], at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        let target = url(for: drive)
        var listing = (try? Data(contentsOf: target)).flatMap { try? JSONDecoder().decode(DriveListing.self, from: $0) } ?? DriveListing()
        listing.replace(under: folder, with: files, at: date)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(listing) { try? data.write(to: target, options: .atomic) }
    }
}
