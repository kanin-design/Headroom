import CryptoKit
import Darwin
import Foundation

/// Copies big files between the Mac and a drive, and proves every copy: the file is hashed as it's read, the copy is read
/// back from the drive itself, past every cache, and hashed again, and only a copy whose hash matches gets its real name.
/// Nothing here removes the original; that's the Trash's job, afterwards, and only for a copy that's proved.
enum DriveMover {
    /// How much is read or written at a time.
    static let chunk = 8 << 20

    enum Failure: Error, Equatable {
        case notThere
        case notAFile
        case differentFileThere(String)
        case alreadyThere(String)
        case driveMissing(String)
        case tooBig(String)
        case noRoom(needed: UInt64, free: UInt64)
        case mismatch
        case changedWhileCopying
        case stopped
        case notAllowed
        case io(String)

        var text: String {
            switch self {
            case .notThere: "Not found."
            case .notAFile: "Only files can be moved."
            case .differentFileThere(let path): "A different file is already at \(DiskTree.friendly(path))."
            case .alreadyThere(let path): "Something is already at \(DiskTree.friendly(path))."
            case .driveMissing(let name): "\(name) isn't connected."
            case .tooBig(let name): "\(name) can't hold files over 4 GB."
            case .noRoom(let needed, let free): "Needs \(formatBytes(needed)). The drive has \(formatBytes(free)) free."
            case .mismatch: "The copy didn't match, so it was removed."
            case .changedWhileCopying: "Changed while copying."
            case .stopped: "Stopped."
            case .notAllowed: "Protected."
            case .io(let why): why
            }
        }
    }

    /// How far one file has got.
    struct Progress: Sendable {
        enum Phase: Sendable { case copying, checking }
        var phase: Phase
        var bytes: UInt64
        var of: UInt64
    }

    /// What became of a copy.
    struct Copied: Sendable, Equatable {
        var target: String
        var hash: String
        var size: UInt64
        /// It was on the drive already, the same to the last byte, so nothing was copied.
        var wasThere: Bool
    }

    /// Where a scripted check may write. Real moves are never made by a script, except between Headroom's two test disks.
    static func mayWrite(_ path: String) -> Bool { Cleaner.mayAct(on: path) }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// Gives a finished file its name, never over something already there. Where the file system can't promise that in one
    /// step, as exFAT can't, it looks first: nothing else writes into the folder a run is copying to.
    static func name(_ part: String, as target: String) throws {
        if renamex_np(part, target, UInt32(RENAME_EXCL)) == 0 { return }
        let why = errno
        guard why == ENOTSUP || why == EINVAL else {
            throw why == EEXIST ? Failure.alreadyThere(target) : Failure.io(String(cString: strerror(why)))
        }
        var there = stat()
        if lstat(target, &there) == 0 { throw Failure.alreadyThere(target) }
        guard Darwin.rename(part, target) == 0 else { throw Failure.io(String(cString: strerror(errno))) }
    }

    /// Reads a whole file past the cache, hashing it, and says its hash and size.
    static func hash(_ path: String, stop: LockedFlag? = nil, progress: ((UInt64) -> Void)? = nil) throws -> (hash: String, size: UInt64) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw errno == ENOENT ? Failure.notThere : Failure.io(String(cString: strerror(errno))) }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        var hasher = SHA256()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buffer.deallocate() }
        var total: UInt64 = 0
        while true {
            if stop?.value == true { throw Failure.stopped }
            let got = read(fd, buffer, chunk)
            if got < 0 {
                if errno == EINTR { continue }
                throw Failure.io(String(cString: strerror(errno)))
            }
            if got == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: got))
            total &+= UInt64(got)
            progress?(total)
        }
        return (hex(hasher.finalize()), total)
    }

    /// Copies one file to `target`, hashing it on the way, then reads the copy back from the drive and hashes it again.
    /// Only a copy that matches is given its name, and it never replaces anything: something already there is either the
    /// same file, which is left as it is, or a reason to stop. `expected` is the hash the original must have, when it's known.
    static func copy(_ source: String, to target: String, expected: String? = nil, stop: LockedFlag,
                     progress: @escaping (Progress) -> Void) throws -> Copied {
        guard mayWrite(target), mayWrite(source) else { throw Failure.notAllowed }
        var info = stat()
        guard lstat(source, &info) == 0 else { throw Failure.notThere }
        guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.notAFile }
        let size = UInt64(info.st_size)
        let fm = FileManager.default
        var there = stat()
        if lstat(target, &there) == 0 {
            // Already copied, perhaps by an earlier run that stopped before the end: it's that file only if every byte says so.
            guard there.st_mode & S_IFMT == S_IFREG, UInt64(there.st_size) == size else { throw Failure.differentFileThere(target) }
            let mine = try hash(source, stop: stop) { progress(Progress(phase: .copying, bytes: $0, of: size)) }
            let theirs = try hash(target, stop: stop) { progress(Progress(phase: .checking, bytes: $0, of: size)) }
            guard mine.hash == theirs.hash, expected.map({ $0 == mine.hash }) ?? true else { throw Failure.differentFileThere(target) }
            return Copied(target: target, hash: mine.hash, size: size, wasThere: true)
        }
        let folder = (target as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // Hidden while it's being written, and removed if anything goes wrong: a half copy never has the real name.
        let part = folder + "/." + (target as NSString).lastPathComponent + ".hrpart"
        unlink(part)
        var keep = false
        defer { if !keep { unlink(part) } }

        let input = open(source, O_RDONLY)
        guard input >= 0 else { throw Failure.io(String(cString: strerror(errno))) }
        defer { close(input) }
        _ = fcntl(input, F_NOCACHE, 1)
        let output = open(part, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard output >= 0 else { throw Failure.io(String(cString: strerror(errno))) }
        var closedOutput = false
        defer { if !closedOutput { close(output) } }
        _ = fcntl(output, F_NOCACHE, 1)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        var done: UInt64 = 0
        while true {
            if stop.value { throw Failure.stopped }
            let got = read(input, buffer, chunk)
            if got < 0 {
                if errno == EINTR { continue }
                throw Failure.io(String(cString: strerror(errno)))
            }
            if got == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: got))
            var written = 0
            while written < got {
                let wrote = write(output, buffer + written, got - written)
                if wrote < 0 {
                    if errno == EINTR { continue }
                    // A drive that went away, or filled up.
                    throw Failure.io(errno == ENOSPC ? "The drive is full." : String(cString: strerror(errno)))
                }
                written += wrote
            }
            done &+= UInt64(got)
            progress(Progress(phase: .copying, bytes: done, of: size))
        }
        // On the drive itself, not in a cache that would be lost if it's unplugged now.
        if fcntl(output, F_FULLFSYNC) != 0 { _ = fsync(output) }
        close(output)
        closedOutput = true
        let sourceHash = hex(hasher.finalize())
        if let expected, expected != sourceHash { throw Failure.mismatch }
        // The original mustn't have changed while it was read.
        var after = stat()
        guard lstat(source, &after) == 0, after.st_size == info.st_size, after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec, done == size else { throw Failure.changedWhileCopying }
        let copyHash = try hash(part, stop: stop) { progress(Progress(phase: .checking, bytes: $0, of: size)) }
        guard copyHash.hash == sourceHash, copyHash.size == size else { throw Failure.mismatch }
        // Its own dates, as the original had them.
        var times = [info.st_atimespec, info.st_mtimespec]
        _ = utimensat(AT_FDCWD, part, &times, 0)
        try name(part, as: target)
        keep = true
        return Copied(target: target, hash: sourceHash, size: size, wasThere: false)
    }

    /// Writes a small file whole, or not at all, and never over something else.
    static func writeNew(_ text: String, to path: String) throws {
        guard mayWrite(path) else { throw Failure.notAllowed }
        if FileManager.default.fileExists(atPath: path) {
            // The same words are the same note: writing it again changes nothing.
            if FileManager.default.contents(atPath: path) == Data(text.utf8) { return }
            throw Failure.alreadyThere(path)
        }
        let folder = (path as NSString).deletingLastPathComponent
        let part = folder + "/." + (path as NSString).lastPathComponent + ".hrpart"
        unlink(part)
        guard FileManager.default.createFile(atPath: part, contents: Data(text.utf8)) else { throw Failure.io("Couldn't write \(DiskTree.friendly(path)).") }
        do { try name(part, as: path) } catch {
            unlink(part)
            throw error
        }
    }

    /// Sends one file to the drive: the copy, its hash beside it, and, for a move, the note where the file was. Nothing is
    /// removed here: the original is still where it was when this returns, and only then may it go to the Trash.
    static func send(_ source: String, to target: String, drive: DriveInfo, writeNote: Bool, stop: LockedFlag,
                     progress: @escaping (Progress) -> Void) throws -> (copied: Copied, note: MovedNote?) {
        let copied = try copy(source, to: target, stop: stop, progress: progress)
        let name = (target as NSString).lastPathComponent
        let sidecar = Sidecar.text(hash: copied.hash, name: name, size: copied.size)
        // An earlier run may have written it already; one that says something else is a reason to stop.
        if let there = Sidecar.read(for: target), there.hash != copied.hash { throw Failure.differentFileThere(Sidecar.path(for: target)) }
        if Sidecar.read(for: target) == nil { try writeNew(sidecar, to: Sidecar.path(for: target)) }
        guard writeNote else { return (copied, nil) }
        let note = MovedNote(name: (source as NSString).lastPathComponent, size: copied.size, sha256: copied.hash, driveName: drive.name,
                             driveID: drive.uuid, drivePath: BackupPaths.fromDriveTop(target, mount: drive.mountPath),
                             moved: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
                             notePath: MovedNote.notePath(for: source))
        try writeNew(note.text, to: note.notePath)
        return (copied, note)
    }

    /// Brings a moved file back to where it was, from the drive, and proves it against the hash its note keeps. The note
    /// is left for the caller to remove, and the drive keeps its copy.
    static func bringBack(_ note: MovedNote, from drive: DriveInfo, stop: LockedFlag, progress: @escaping (Progress) -> Void) throws -> Copied {
        let source = note.pathOnDrive(mountedAt: drive.mountPath)
        guard FileManager.default.fileExists(atPath: source) else { throw Failure.notThere }
        return try copy(source, to: note.originalPath, expected: note.sha256, stop: stop, progress: progress)
    }

    /// What reading a moved file on the drive again found.
    enum Check: Equatable, Sendable {
        case fine
        case missing
        case changed
        case driveMissing

        var text: String {
            switch self {
            case .fine: "Verified"
            case .missing: "Missing from the drive"
            case .changed: "Changed on the drive"
            case .driveMissing: "Drive not connected"
            }
        }
    }

    /// Reads a moved file on the drive and compares it with its note, and with the hash beside it.
    static func verify(_ note: MovedNote, on drive: DriveInfo?, stop: LockedFlag, progress: ((UInt64) -> Void)? = nil) -> Check {
        guard let drive else { return .driveMissing }
        let path = note.pathOnDrive(mountedAt: drive.mountPath)
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        guard UInt64(info.st_size) == note.size, let found = try? hash(path, stop: stop, progress: progress) else { return .changed }
        if let beside = Sidecar.read(for: path), beside.hash != note.sha256 { return .changed }
        return found.hash == note.sha256 ? .fine : .changed
    }
}
