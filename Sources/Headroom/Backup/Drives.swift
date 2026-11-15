import Darwin
import Foundation

/// A drive as the drive row lists it: its name, how full it is and what file system it has.
struct DriveInfo: Codable, Identifiable, Equatable, Hashable, Sendable {
    var name: String
    var mountPath: String
    /// The volume's own ID, which stays when the drive is renamed. Not every file system has one.
    var uuid: String?
    /// The file system as macOS names it: apfs, exfat, hfs, msdos.
    var fileSystem: String
    var capacity: UInt64
    var free: UInt64
    var isInternal: Bool
    var isReadOnly: Bool
    var isBoot: Bool
    var isConnected = true

    var id: String { uuid ?? mountPath }

    /// The file system as people know it.
    var fileSystemTitle: String { Self.title(ofFileSystem: fileSystem) }

    static func title(ofFileSystem raw: String) -> String {
        switch raw.lowercased() {
        case "apfs": "APFS"
        case "exfat": "exFAT"
        case "hfs": "Mac OS Extended"
        case "msdos": "MS-DOS (FAT32)"
        case "ntfs": "NTFS"
        case "smbfs": "SMB"
        case "afpfs": "AFP"
        case "nfs": "NFS"
        case "": "Unknown"
        default: raw.uppercased()
        }
    }

    /// The largest file it can hold, when it has a limit that matters for big files.
    var largestFile: UInt64? { fileSystem.lowercased() == "msdos" ? 4_294_967_295 : nil }

    /// Whether it's this one: by its ID when both have one, otherwise by where it's mounted and its name.
    func isSame(as other: DriveInfo) -> Bool {
        if let a = uuid, let b = other.uuid { return a == b }
        return mountPath == other.mountPath && name == other.name
    }

    /// The drives connected now, the startup disk first.
    static func connected() -> [DriveInfo] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var out: [DriveInfo] = []
        for url in urls {
            guard let drive = info(at: url, keys: Set(keys)) else { continue }
            out.append(drive)
        }
        return out.sorted { a, b in a.isBoot != b.isBoot ? a.isBoot : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }

    /// The drive a path is on, as it is now.
    static func holding(_ path: String) -> DriveInfo? {
        let mount = PathMath.mount(of: PathMath.visible(path))
        return connected().first { $0.mountPath == mount }
    }

    private static func info(at url: URL, keys: Set<URLResourceKey>) -> DriveInfo? {
        guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsBrowsable != false else { return nil }
        var disk = statfs()
        guard statfs(url.path, &disk) == 0 else { return nil }
        let type = withUnsafeBytes(of: disk.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        // Images and system parts macOS mounts for itself aren't drives anyone picks.
        if ["devfs", "autofs", "nullfs"].contains(type) { return nil }
        let isRoot = values.volumeIsRootFileSystem == true || url.path == "/"
        // What's free for something you want to keep. On APFS that counts space macOS would clear for it; other file systems
        // only say what's free, and some say nothing at all here, so the file system's own count is the floor.
        let free = max(UInt64(max(values.volumeAvailableCapacityForImportantUsage ?? 0, 0)), UInt64(max(values.volumeAvailableCapacity ?? 0, 0)),
                       UInt64(disk.f_bavail) * UInt64(disk.f_bsize))
        return DriveInfo(name: values.volumeLocalizedName ?? url.lastPathComponent, mountPath: isRoot ? "/" : url.path, uuid: values.volumeUUIDString,
                         fileSystem: type, capacity: UInt64(max(values.volumeTotalCapacity ?? 0, 0)), free: free,
                         isInternal: values.volumeIsInternal ?? isRoot, isReadOnly: values.volumeIsReadOnly ?? false, isBoot: isRoot)
    }
}

/// Where Backup puts things: a folder on a drive, the top of the drive unless you choose one.
struct BackupDestination: Codable, Equatable, Sendable {
    var drive: DriveInfo
    /// The folder on the drive, from its top. Empty for the top itself.
    var folder: String = ""

    /// Where the folder is while the drive is connected where it was.
    var root: String {
        let mount = drive.mountPath == "/" ? "" : drive.mountPath
        return folder.isEmpty ? (mount.isEmpty ? "/" : mount) : mount + "/" + folder
    }

    /// What the drive row says: the drive, and the folder when it isn't the top.
    var title: String { folder.isEmpty ? drive.name : drive.name + " › " + (folder as NSString).lastPathComponent }
}

/// Where a file goes on the drive: the same place it has on the Mac. In your home folder that's its path from there, so
/// `~/Media/Movies/Film.mkv` goes to `Media/Movies/Film.mkv` in the backup folder, which is the layout a drive of media
/// usually has already. Outside your home folder it's its path from the top of its disk, under the disk's name.
enum BackupPaths {
    static func relative(_ path: String, home: String = NSHomeDirectory()) -> String {
        let visible = PathMath.visible(path)
        if PathMath.isInside(visible, home), visible != home { return String(visible.dropFirst(home.count + 1)) }
        let mount = PathMath.mount(of: visible)
        let disk = mount == "/" ? "Macintosh HD" : (mount as NSString).lastPathComponent
        let inside = mount == "/" ? String(visible.dropFirst()) : String(visible.dropFirst(mount.count + 1))
        return disk + "/" + inside
    }

    static func onDrive(_ path: String, under root: String, home: String = NSHomeDirectory()) -> String {
        (root == "/" ? "" : root) + "/" + relative(path, home: home)
    }

    /// The path from the drive's top, as a note keeps it.
    static func fromDriveTop(_ absolute: String, mount: String) -> String {
        mount == "/" ? String(absolute.dropFirst()) : String(absolute.dropFirst(mount.count + 1))
    }
}

/// One file waiting to go to the drive.
struct BackupItem: Codable, Identifiable, Equatable, Sendable {
    var path: String
    var title: String
    var bytes: UInt64
    var addedAt = Date()
    /// The agent that selected it, and why, when one did.
    var agent: String? = nil
    var reason: String? = nil
    var id: String { path }
}

/// What Backup remembers between launches: what's selected, where it goes, what's never offered, and the drives used.
struct BackupState: Codable, Equatable {
    var items: [BackupItem] = []
    var destination: BackupDestination?
    /// Paths that are never offered for moving: Keep on Mac.
    var keep: [String] = []
    /// Drives used before, so one can be chosen while it isn't connected.
    var knownDrives: [DriveInfo] = []
    /// The notes this Mac has written, so their ghosts can be shown without looking through the whole disk.
    var notes: [String] = []

    /// Only files this big are offered, or can be selected.
    static let smallest: UInt64 = 100_000_000

    func isKept(_ path: String) -> Bool { keep.contains { PathMath.isInside(path, $0) } }
    func has(_ path: String) -> Bool { items.contains { $0.path == path } }
}

enum BackupStore {
    private static var url: URL { AppData.folder.appendingPathComponent("backup.json") }

    static func load() -> BackupState {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(BackupState.self, from: data) else { return BackupState() }
        return state
    }

    static func save(_ state: BackupState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        let target = url
        Saves.queue.async { try? data.write(to: target, options: .atomic) }
    }
}
