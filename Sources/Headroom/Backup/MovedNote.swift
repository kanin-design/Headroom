import Foundation

/// What's left in a folder on the Mac when a file in it has been moved to a drive: a small text file with the same name
/// and `.hrmoved` on the end, saying where the file is now, how big it is and what its contents hash to. Everything Headroom
/// needs to show the file as a ghost, and to bring it back, is in it, so it works with the drive unplugged, on any Mac,
/// and survives the folder being moved or renamed. It's plain text, so it can be read without Headroom.
struct MovedNote: Codable, Equatable, Hashable, Sendable {
    /// The file's name, as it was.
    var name: String
    var size: UInt64
    var sha256: String
    /// The drive it's on, by the name it had and, when known, the volume's own ID, which survives renaming the drive.
    var driveName: String
    var driveID: String?
    /// Where it is on that drive, from the drive's top.
    var drivePath: String
    var moved: Date
    /// Where this note is on the Mac. It isn't written in the note: the note is wherever it's found.
    var notePath: String = ""

    static let ext = "hrmoved"
    static let firstLine = "Moved by Headroom. This file is on another drive."

    /// Where the file was, and where its note is.
    var originalPath: String { String(notePath.dropLast(Self.ext.count + 1)) }
    static func notePath(for original: String) -> String { original + "." + ext }
    static func isNote(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix("." + ext) && name.count > ext.count + 1
    }

    /// Where the file is when that drive is connected at this place.
    func pathOnDrive(mountedAt mount: String) -> String { mount + "/" + drivePath }

    private static let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    var text: String {
        var lines = [Self.firstLine, "name: \(name)", "size: \(size)", "sha256: \(sha256)", "drive: \(driveName)"]
        if let driveID { lines.append("drive-id: \(driveID)") }
        lines += ["path: \(drivePath)", "moved: \(Self.dates.string(from: moved))"]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads a note. Nil for anything that isn't one, or lacks what's needed to find the file again.
    static func parse(_ text: String, at notePath: String) -> MovedNote? {
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // The first of each: a value can't be replaced by a line further down.
            if fields[key] == nil { fields[key] = value }
        }
        guard let name = fields["name"], !name.isEmpty, let size = fields["size"].flatMap(UInt64.init), let hash = fields["sha256"]?.lowercased(),
              hash.count == 64, hash.allSatisfy(\.isHexDigit), let drive = fields["drive"], !drive.isEmpty, let path = fields["path"], !path.isEmpty,
              !path.split(separator: "/").contains("..") else { return nil }
        let moved = fields["moved"].flatMap { dates.date(from: $0) } ?? Date(timeIntervalSince1970: 0)
        return MovedNote(name: name, size: size, sha256: hash, driveName: drive, driveID: fields["drive-id"].flatMap { $0.isEmpty ? nil : $0 },
                         drivePath: path, moved: moved, notePath: notePath)
    }

    /// The note at this path, if there's a readable one. Notes are small: anything big isn't one.
    static func read(at path: String) -> MovedNote? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size < 64 << 10,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return parse(String(decoding: data, as: UTF8.self), at: path)
    }
}

/// The `name.sha256` Backup used to write beside each file on a drive. It isn't written any more: on a large exFAT drive each
/// took a whole 128 KB cluster, and the hash is kept on the Mac, in the note or Backup's record of copies. One from before
/// is still read.
enum Sidecar {
    static let ext = "sha256"

    static func path(for file: String) -> String { file + "." + ext }

    /// The hash in the `.sha256` beside a file, if one is there.
    static func hash(for file: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path(for: file)), data.count < 4096,
              let first = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first else { return nil }
        let hash = String(first.prefix(64)).lowercased()
        return hash.count == 64 && hash.allSatisfy(\.isHexDigit) ? hash : nil
    }
}
