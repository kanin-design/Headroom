import Darwin
import Foundation
import SystemConfiguration

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

    /// On a server, shared over the network, rather than a disk of this Mac's.
    var isNetwork: Bool { ["smbfs", "afpfs", "nfs", "webdav", "cifs"].contains(fileSystem.lowercased()) }

    /// The largest file it can hold, when it has a limit that matters for big files.
    var largestFile: UInt64? { fileSystem.lowercased() == "msdos" ? 4_294_967_295 : nil }

    /// Whether it's this one: by its ID when both have one, otherwise by where it's mounted and its name.
    func isSame(as other: DriveInfo) -> Bool {
        if let a = uuid, let b = other.uuid { return a == b }
        return mountPath == other.mountPath && name == other.name
    }

    private static let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey,
                                                 .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeIsInternalKey,
                                                 .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey]

    /// The drives connected now, the startup disk first: the ones the Finder lists, a server's shares included.
    static func connected() -> [DriveInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var out: [DriveInfo] = []
        for url in urls {
            guard let drive = info(at: url, listedOnly: true) else { continue }
            out.append(drive)
        }
        return out.sorted { a, b in a.isBoot != b.isBoot ? a.isBoot : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }

    /// The drive a folder is on, as it is now: whatever is mounted there, wherever it's mounted, a server's share included.
    static func holding(_ path: String) -> DriveInfo? {
        guard let volume = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeURLKey]).volume else { return nil }
        return info(at: volume, listedOnly: false)
    }

    /// The drive mounted at this path, if one is now, even one the Finder doesn't list. Only what's mounted is looked at, so a
    /// server that isn't there isn't asked for.
    static func mounted(at mountPath: String) -> DriveInfo? {
        var list: UnsafeMutablePointer<statfs>?
        let count = Int(getmntinfo(&list, MNT_NOWAIT))
        guard count > 0, let list else { return nil }
        let isMounted = (0..<count).contains { i in
            withUnsafeBytes(of: list[i].f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } == mountPath
        }
        return isMounted ? info(at: URL(fileURLWithPath: mountPath, isDirectory: true), listedOnly: false) : nil
    }

    /// `listedOnly` leaves out what the Finder doesn't list, as macOS's own parts are.
    private static func info(at url: URL, listedOnly: Bool) -> DriveInfo? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)), !listedOnly || values.volumeIsBrowsable != false else { return nil }
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

/// Where Backup puts things: a folder on a drive, the top of the drive unless you choose one. The drive can be a server's
/// share.
struct BackupDestination: Codable, Equatable, Sendable, Identifiable {
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

    var id: String { drive.id + "/" + folder }

    /// Whether it's this one: the same folder on the same drive.
    func isSame(as other: BackupDestination) -> Bool { drive.isSame(as: other.drive) && folder == other.folder }
}

/// Where a file goes on the drive: in a folder named for this Mac, at its full path on the Mac, so
/// `/Users/you/Downloads/Film.mkv` from a Mac named Studio goes to `Backup from Studio/Users/you/Downloads/Film.mkv`. Nothing is
/// mixed in with what the drive holds already, and the path says which Mac and which folder each file came from.
enum BackupPaths {
    /// The folder on the drive that holds this Mac's files, named as Sharing names the Mac.
    static let macFolder = "Backup from " + macName

    private static var macName: String {
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? ""
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        return safe.isEmpty ? "Mac" : safe
    }

    static func relative(_ path: String, folder: String = macFolder) -> String {
        folder + PathMath.visible(path)
    }

    static func onDrive(_ path: String, under root: String, folder: String = macFolder) -> String {
        (root == "/" ? "" : root) + "/" + relative(path, folder: folder)
    }

    /// A folder's path from the top of the drive it's on, both spelled as the system spells them (`PathMath.canonical`): empty
    /// for the top itself, nil when it isn't on that drive.
    static func folder(_ path: String, onDriveAt top: String) -> String? {
        if path == top { return "" }
        let start = top == "/" ? "/" : top + "/"
        return path.hasPrefix(start) ? String(path.dropFirst(start.count)) : nil
    }

    /// The path from the drive's top, as a note keeps it.
    static func fromDriveTop(_ absolute: String, mount: String) -> String {
        mount == "/" ? String(absolute.dropFirst()) : String(absolute.dropFirst(mount.count + 1))
    }
}

/// Backup's list as a whole: how many files, what they hold, what moving them frees on the Mac, and the ones that free
/// nothing, by path.
struct BackupSummary: Equatable {
    var files = 0
    var bytes: UInt64 = 0
    var frees: UInt64 = 0
    var freesNothing: Set<String> = []
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

/// A file Backup copied to a drive and kept on this Mac: where it is on the drive, from its top, and what it hashed to.
struct CopiedFile: Codable, Equatable, Sendable {
    var driveID: String
    var path: String
    var sha256: String
    var size: UInt64
    var copied: Date
}

/// What Backup remembers between launches: what's selected, where it goes, what's never offered, and the drives used.
struct BackupState: Codable, Equatable {
    var items: [BackupItem] = []
    var destination: BackupDestination?
    /// Paths that are never offered for moving: Keep on Mac.
    var keep: [String] = []
    /// Drives used before, so one can be chosen while it isn't connected.
    var knownDrives: [DriveInfo] = []
    /// The locations chosen before, each a folder on a drive, in the order first chosen, so one can be chosen again, folder and
    /// all, while it isn't connected. Optional, so a file from before it was kept still reads (see `usedLocations`).
    var locations: [BackupDestination]?
    /// The notes this Mac has written, so their ghosts can be shown without looking through the whole disk.
    var notes: [String] = []
    /// What's picked on the drive's half, kept like what's picked on the Mac's. Optional, so a file from before it was kept
    /// still reads.
    var drivePicks: [DriveFile]?
    /// Files copied to a drive, and kept on the Mac too, so with no note: their hashes are kept here. Optional, as above.
    var copies: [CopiedFile]?

    /// Only files this big are offered, or can be selected.
    /// Under this, what a file costs on an exFAT drive with large clusters stops being small next to what it frees.
    static let smallest: UInt64 = 10_000_000

    /// The locations chosen before: as kept, or for a file from before they were, the drives used before, at their tops, or
    /// in the folder files go to now.
    var usedLocations: [BackupDestination] {
        if let locations { return locations }
        return knownDrives.map { known in
            destination.flatMap { $0.drive.isSame(as: known) ? $0 : nil } ?? BackupDestination(drive: known)
        }
    }

    /// Files go here from now on. It joins the locations used, after the others, or takes the place of itself as it was.
    mutating func use(_ place: BackupDestination) {
        var places = usedLocations
        if let at = places.firstIndex(where: { $0.isSame(as: place) }) { places[at] = place } else { places.append(place) }
        locations = places
        destination = place
        if let at = knownDrives.firstIndex(where: { $0.isSame(as: place.drive) }) {
            knownDrives[at] = place.drive
        } else if !place.drive.isBoot {
            knownDrives.append(place.drive)
        }
    }

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
