import CryptoKit
import XCTest
@testable import Headroom

/// Backup: the note a moved file leaves, the hash beside its copy, where a file goes on the drive, the copy that proves
/// itself before anything else happens, and the ghosts drawn from notes.
final class BackupTests: XCTestCase {
    private var folder: String!

    override func setUpWithError() throws {
        // In the home folder: Backup only moves what Headroom would let go, and that's not inside the system's temporary folders.
        folder = NSHomeDirectory() + "/Library/Caches/HeadroomBackupTests-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: folder + "/Mac/Films", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: folder + "/Drive", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: folder)
    }

    private func file(_ path: String, bytes: Int, seed: UInt8 = 7) throws -> String {
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            for i in stride(from: 0, to: raw.count, by: 4096) { raw[i] = UInt8(truncatingIfNeeded: i / 4096) &+ seed }
        }
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    private func sha(_ path: String) throws -> String {
        DriveMover.hex(SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: path))))
    }

    private let drive = DriveInfo(name: "Spare", mountPath: "/Volumes/Spare", uuid: "6A1F-UUID", fileSystem: "exfat", capacity: 2_000_000_000_000,
                                  free: 1_000_000_000_000, isInternal: false, isReadOnly: false, isBoot: false)

    // MARK: The note

    func testANoteSaysWhereTheFileIsAndReadsBack() throws {
        let note = MovedNote(name: "Film (2026) - 1080p.mkv", size: 7_381_234_567, sha256: String(repeating: "ab", count: 32), driveName: "Spare", driveID: "6A1F-UUID",
                             drivePath: "Media/Movies/Film (2026)/Film (2026) - 1080p.mkv", moved: Date(timeIntervalSince1970: 1_794_000_000),
                             notePath: "/Users/x/Media/Movies/Film (2026)/Film (2026) - 1080p.mkv.hrmoved")
        let text = note.text
        XCTAssertTrue(text.hasPrefix(MovedNote.firstLine), "a person who opens it reads what it is first")
        XCTAssertTrue(text.contains("size: 7381234567"))
        XCTAssertEqual(MovedNote.parse(text, at: note.notePath), note)
        XCTAssertEqual(note.originalPath, "/Users/x/Media/Movies/Film (2026)/Film (2026) - 1080p.mkv")
        XCTAssertEqual(note.pathOnDrive(mountedAt: "/Volumes/Spare"), "/Volumes/Spare/Media/Movies/Film (2026)/Film (2026) - 1080p.mkv")
        XCTAssertTrue(MovedNote.isNote(note.notePath))
        XCTAssertFalse(MovedNote.isNote("/x/.hrmoved"))
    }

    func testANoteThatIsntOneIsNotRead() {
        XCTAssertNil(MovedNote.parse("Some file\nname: x\n", at: "/a.hrmoved"), "without a hash and a drive it's no note")
        let bad = "name: x\nsize: 1\nsha256: \(String(repeating: "a", count: 64))\ndrive: Spare\npath: ../../etc/passwd\n"
        XCTAssertNil(MovedNote.parse(bad, at: "/a.hrmoved"), "a note can't point outside its drive")
        let short = "name: x\nsize: 1\nsha256: abc\ndrive: Spare\npath: a\n"
        XCTAssertNil(MovedNote.parse(short, at: "/a.hrmoved"))
        // A line further down can't replace what the note said first.
        let twice = "name: x\nsize: 1\nsha256: \(String(repeating: "a", count: 64))\ndrive: Spare\npath: a/b\npath: c/d\n"
        XCTAssertEqual(MovedNote.parse(twice, at: "/a.hrmoved")?.drivePath, "a/b")
    }

    func testTheHashBesideACopyIsWhatShasumChecks() throws {
        let text = Sidecar.text(hash: String(repeating: "c", count: 64), name: "a film.mkv", size: 6)
        XCTAssertTrue(text.hasPrefix(String(repeating: "c", count: 64) + "  a film.mkv\n"), "the form `shasum -a 256 -c` reads")
        XCTAssertEqual(Sidecar.parse(text)?.hash, String(repeating: "c", count: 64))
        XCTAssertEqual(Sidecar.parse(text)?.size, 6)
        XCTAssertNil(Sidecar.parse("nonsense"))
    }

    // MARK: Where things go

    func testAFileKeepsItsPlaceOnTheDrive() {
        XCTAssertEqual(BackupPaths.relative("/Users/x/Media/Movies/F.mkv", home: "/Users/x"), "Media/Movies/F.mkv")
        XCTAssertEqual(BackupPaths.onDrive("/Users/x/Media/Movies/F.mkv", under: "/Volumes/Spare", home: "/Users/x"), "/Volumes/Spare/Media/Movies/F.mkv")
        XCTAssertEqual(BackupPaths.onDrive("/Users/x/Media/F.mkv", under: "/Volumes/Spare/Backups", home: "/Users/x"), "/Volumes/Spare/Backups/Media/F.mkv")
        XCTAssertEqual(BackupPaths.relative("/Users/Shared/Big.mov", home: "/Users/x"), "Macintosh HD/Users/Shared/Big.mov", "outside home, under the disk's name")
        XCTAssertEqual(BackupPaths.relative("/Volumes/Other/Films/F.mkv", home: "/Users/x"), "Other/Films/F.mkv")
        XCTAssertEqual(BackupPaths.fromDriveTop("/Volumes/Spare/Media/F.mkv", mount: "/Volumes/Spare"), "Media/F.mkv")
        XCTAssertEqual(BackupDestination(drive: drive, folder: "Backups").root, "/Volumes/Spare/Backups")
        XCTAssertEqual(BackupDestination(drive: drive).root, "/Volumes/Spare")
    }

    func testDrivesAreNamedByTheirFileSystem() {
        XCTAssertEqual(DriveInfo.title(ofFileSystem: "apfs"), "APFS")
        XCTAssertEqual(DriveInfo.title(ofFileSystem: "exfat"), "exFAT")
        XCTAssertEqual(DriveInfo.title(ofFileSystem: "msdos"), "MS-DOS (FAT32)")
        XCTAssertEqual(DriveInfo.title(ofFileSystem: "hfs"), "Mac OS Extended")
        var fat = drive
        fat.fileSystem = "msdos"
        XCTAssertEqual(fat.largestFile, 4_294_967_295, "FAT32 can't hold a file over 4 GB")
        XCTAssertNil(drive.largestFile)
        var renamed = drive
        renamed.name = "Spare 2"
        renamed.mountPath = "/Volumes/Spare 2"
        XCTAssertTrue(renamed.isSame(as: drive), "a drive is itself by its ID, whatever it's called")
        let connected = DriveInfo.connected()
        XCTAssertEqual(connected.first?.isBoot, true, "the startup disk comes first")
        XCTAssertEqual(connected.first?.mountPath, "/")
        // Every connected drive says how much is free, whatever its file system: an exFAT drive once said nothing, and
        // Backup thought it full.
        for one in connected where !one.isReadOnly { XCTAssertGreaterThan(one.free, 0, "\(one.name) says it has space free") }
    }

    // MARK: The copy that proves itself

    func testACopyIsHashedReadBackAndGivenItsNameOnlyWhenItMatches() throws {
        let source = try file(folder + "/Mac/Films/a.mkv", bytes: 3_000_000)
        let target = folder + "/Drive/Media/Films/a.mkv"
        var phases: Set<String> = []
        let copied = try DriveMover.copy(source, to: target, stop: LockedFlag()) { p in phases.insert(p.phase == .copying ? "copy" : "check") }
        XCTAssertEqual(phases, ["copy", "check"], "it's read once to copy and once more, from the drive, to check")
        XCTAssertEqual(copied.hash, try sha(source))
        XCTAssertEqual(try sha(target), copied.hash)
        XCTAssertEqual(copied.size, 3_000_000)
        XCTAssertFalse(copied.wasThere)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source), "the original isn't touched")
        let dates = try FileManager.default.attributesOfItem(atPath: source)[.modificationDate] as? Date
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target)[.modificationDate] as? Date, dates, "the copy keeps its date")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder + "/Drive/Media/Films").contains { $0.hasSuffix(".hrpart") }, "no half copy is left")

        // Again: the same file is already there, so nothing is copied, and it's proved the same.
        let again = try DriveMover.copy(source, to: target, stop: LockedFlag()) { _ in }
        XCTAssertTrue(again.wasThere)
        XCTAssertEqual(again.hash, copied.hash)
    }

    func testSomethingElseAtTheTargetIsNeverReplaced() throws {
        let source = try file(folder + "/Mac/Films/a.mkv", bytes: 1_000_000)
        let target = try file(folder + "/Drive/a.mkv", bytes: 1_000_000, seed: 99)
        let before = try sha(target)
        XCTAssertThrowsError(try DriveMover.copy(source, to: target, stop: LockedFlag()) { _ in }) { error in
            XCTAssertEqual(error as? DriveMover.Failure, .differentFileThere(target))
        }
        XCTAssertEqual(try sha(target), before, "what was there is as it was")
        let other = try file(folder + "/Drive/b.mkv", bytes: 5)
        XCTAssertThrowsError(try DriveMover.copy(source, to: other, stop: LockedFlag()) { _ in })
    }

    func testAStoppedCopyLeavesNothingAndTheOriginalAlone() throws {
        let source = try file(folder + "/Mac/Films/a.mkv", bytes: 20_000_000)
        let target = folder + "/Drive/a.mkv"
        let stop = LockedFlag()
        XCTAssertThrowsError(try DriveMover.copy(source, to: target, stop: stop) { p in if p.bytes >= UInt64(DriveMover.chunk) { stop.value = true } }) { error in
            XCTAssertEqual(error as? DriveMover.Failure, .stopped)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target), "nothing has the real name")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder + "/Drive"), [], "and no half copy is left")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source))
    }

    func testAMoveWritesTheHashBesideTheCopyAndTheNoteWhereTheFileWas() throws {
        let source = try file(folder + "/Mac/Films/Film.mkv", bytes: 2_000_000)
        let target = folder + "/Drive/Films/Film.mkv"
        var mount = drive
        mount.mountPath = folder + "/Drive"
        let sent = try DriveMover.send(source, to: target, drive: mount, writeNote: true, stop: LockedFlag()) { _ in }
        let note = try XCTUnwrap(sent.note)
        XCTAssertEqual(note.drivePath, "Films/Film.mkv")
        XCTAssertEqual(note.sha256, try sha(source))
        XCTAssertEqual(MovedNote.read(at: source + ".hrmoved"), note, "the note on the Mac reads back as written")
        XCTAssertEqual(Sidecar.read(for: target)?.hash, note.sha256)
        XCTAssertEqual(Sidecar.read(for: target)?.size, 2_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source), "removing the original is the Trash's job, afterwards")

        // A copy without a note leaves the Mac as it was, but for nothing.
        let other = try file(folder + "/Mac/Films/Other.mkv", bytes: 1_000_000)
        let copied = try DriveMover.send(other, to: folder + "/Drive/Films/Other.mkv", drive: mount, writeNote: false, stop: LockedFlag()) { _ in }
        XCTAssertNil(copied.note)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other + ".hrmoved"))
    }

    func testBringingBackProvesTheFileAgainstItsNote() throws {
        let source = try file(folder + "/Mac/Films/Film.mkv", bytes: 2_000_000)
        var mount = drive
        mount.mountPath = folder + "/Drive"
        let note = try XCTUnwrap(DriveMover.send(source, to: folder + "/Drive/Films/Film.mkv", drive: mount, writeNote: true, stop: LockedFlag()) { _ in }.note)
        try FileManager.default.removeItem(atPath: source)
        XCTAssertEqual(DriveMover.verify(note, on: mount, stop: LockedFlag()), .fine)

        let back = try DriveMover.bringBack(note, from: mount, stop: LockedFlag()) { _ in }
        XCTAssertEqual(back.hash, note.sha256)
        XCTAssertEqual(try sha(source), note.sha256, "the file is back, the same to the last byte")
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.pathOnDrive(mountedAt: mount.mountPath)), "and the drive keeps its copy")

        // A copy on the drive that changed isn't brought back, and isn't called verified.
        try FileManager.default.removeItem(atPath: source)
        _ = try file(note.pathOnDrive(mountedAt: mount.mountPath), bytes: 2_000_000, seed: 42)
        XCTAssertEqual(DriveMover.verify(note, on: mount, stop: LockedFlag()), .changed)
        XCTAssertThrowsError(try DriveMover.bringBack(note, from: mount, stop: LockedFlag()) { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: source), "nothing changed was brought back")
        try FileManager.default.removeItem(atPath: note.pathOnDrive(mountedAt: mount.mountPath))
        XCTAssertEqual(DriveMover.verify(note, on: mount, stop: LockedFlag()), .missing)
        XCTAssertEqual(DriveMover.verify(note, on: nil, stop: LockedFlag()), .driveMissing)
    }

    // MARK: Ghosts

    func testGhostsAreDrawnWhereTheFilesWereAndAreNothingButPictures() throws {
        let disk = FakeDisk()
        disk.file("/Volumes/Fake/Media/Movies/Here.mkv", 2_000_000_000, kind: .video)
        disk.finish()
        let tree = disk.tree
        let moved = MovedNote(name: "Gone.mkv", size: 5_000_000_000, sha256: String(repeating: "a", count: 64), driveName: "Spare", driveID: nil,
                              drivePath: "Media/Movies/Gone.mkv", moved: Date(), notePath: "/Volumes/Fake/Media/Movies/Gone.mkv.hrmoved")
        let elsewhere = MovedNote(name: "Lost.mkv", size: 1, sha256: String(repeating: "b", count: 64), driveName: "Spare", driveID: nil,
                                  drivePath: "x/Lost.mkv", moved: Date(), notePath: "/Volumes/Fake/Nowhere/Lost.mkv.hrmoved")
        let picture = try XCTUnwrap(tree.withGhosts([moved, elsewhere]))
        XCTAssertEqual(picture.count, tree.count + 1, "a note in a folder the map doesn't have is left out")
        let ghost = UInt32(tree.count)
        XCTAssertTrue(picture.isGhost(ghost))
        XCTAssertFalse(tree.isGhost(ghost))
        XCTAssertEqual(picture.name(ghost), "Gone.mkv")
        XCTAssertEqual(picture.path(ghost), "/Volumes/Fake/Media/Movies/Gone.mkv")
        let movies = disk.node("/Volumes/Fake/Media/Movies")
        XCTAssertEqual(picture.totals[Int(movies)], tree.totals[Int(movies)] + 5_000_000_000, "drawn at its size")
        XCTAssertEqual(picture.children(movies).first, ghost, "biggest first, as everything else")
        XCTAssertTrue(picture.isInside(ghost, movies))
        XCTAssertEqual(picture.kindBytes(ghost).reduce(0, +), 0, "with no files of its own on the disk")
        XCTAssertNil(try? AgentLook.node("/Volumes/Fake/Media/Movies/Gone.mkv", in: picture), "a ghost can't be found to be selected")
        XCTAssertEqual(tree.totals[Int(movies)], 2_000_000_000, "and the real map is unchanged")
        XCTAssertNil(tree.withGhosts([elsewhere]))

        let layout = RingLayout.build(tree: picture, focus: movies, colorer: { _ in .zero }, sizes: RingSizes())
        XCTAssertEqual(layout.pieces.first { $0.node == ghost }?.style, .ghost, "and it's drawn as a ghost")
        XCTAssertNotNil(picture.copy().ghosts[ghost], "a copy of the picture keeps its ghosts")
    }

    // MARK: Both sides

    func testBothSidesSayWhereEachFileIs() throws {
        // The drive's folder, on the disk: one file the same as the Mac's, one of a different size, one only there, one moved.
        let drive = folder + "/Drive"
        _ = try file(drive + "/same.mkv", bytes: 3_000_000)
        _ = try file(drive + "/changed.mkv", bytes: 2_000_000)
        _ = try file(drive + "/only-drive.mkv", bytes: 4_000_000)
        _ = try file(drive + "/moved.mkv", bytes: 5_000_000)
        _ = try file(drive + "/._same.mkv", bytes: 4096)
        // The Mac's folder, as a map has it, with the files on the disk to measure.
        let mac = folder + "/Mac/Films"
        _ = try file(mac + "/same.mkv", bytes: 3_000_000)
        _ = try file(mac + "/changed.mkv", bytes: 2_500_000)
        _ = try file(mac + "/only-mac.mkv", bytes: 6_000_000)
        let disk = FakeDisk(root: folder + "/Mac")
        disk.file(mac + "/same.mkv", 3_000_000, kind: .video)
        disk.file(mac + "/changed.mkv", 2_500_000, kind: .video)
        disk.file(mac + "/only-mac.mkv", 6_000_000, kind: .video)
        disk.finish()
        let note = MovedNote(name: "moved.mkv", size: 5_000_000, sha256: String(repeating: "a", count: 64), driveName: "Spare", driveID: nil,
                             drivePath: "moved.mkv", moved: Date(), notePath: mac + "/moved.mkv.hrmoved")
        let pair = try XCTUnwrap(PairPicture.build(real: disk.tree, macFolder: disk.node(mac), macPath: mac, drivePath: drive, driveName: "Spare",
                                                   notes: [note], ghosts: true))
        let tree = pair.tree
        func place(_ path: String) -> PairPlace? { tree.find(path: path).flatMap { pair.places[$0] } }
        XCTAssertEqual(place(mac + "/same.mkv"), .both)
        XCTAssertEqual(place(drive + "/same.mkv"), .both)
        XCTAssertEqual(place(mac + "/changed.mkv"), .differs, "the same name at another size isn't the same file")
        XCTAssertEqual(place(mac + "/only-mac.mkv"), .onlyMac)
        XCTAssertEqual(place(drive + "/only-drive.mkv"), .onlyDrive)
        XCTAssertEqual(place(drive + "/moved.mkv"), .moved, "what a note says was moved is the drive's copy of it")
        XCTAssertNil(tree.find(path: drive + "/._same.mkv"), "the drive's bookkeeping files aren't drawn")
        let ghost = try XCTUnwrap(tree.ghosts.first?.key)
        XCTAssertEqual(pair.places[ghost], .moved, "and the Mac's side draws it as a ghost")
        XCTAssertEqual(pair.counts[.both]?.files, 1, "a file on both sides counts once")
        XCTAssertEqual(pair.counts[.onlyMac]?.bytes, 6_000_000)
        XCTAssertEqual(pair.counts[.moved]?.files, 1)
        XCTAssertNil(pair.counts[.missing])
        // The drive's half first, so it's on the right.
        XCTAssertEqual(tree.children(0).first, pair.driveSide)
        XCTAssertEqual(tree.name(pair.driveSide), "Spare")
        XCTAssertEqual(tree.name(pair.macSide), "This Mac")
        XCTAssertEqual(tree.totals[Int(pair.macSide)], disk.tree.totals[Int(disk.node(mac))] + 5_000_000, "the Mac's side at its size, with the ghost")
        XCTAssertEqual(pair.macBytes, disk.tree.totals[Int(disk.node(mac))], "the middle says what's really on the Mac")
        XCTAssertEqual(tree.bytesHere(pair.macSide), pair.macBytes, "and so does the Mac's half")
        // A file picked on the drive's half knows where it goes on the Mac.
        let picked = try XCTUnwrap(tree.find(path: drive + "/only-drive.mkv").flatMap { pair.driveFile($0) })
        XCTAssertEqual(picked.path, drive + "/only-drive.mkv")
        XCTAssertEqual(picked.macPath, mac + "/only-drive.mkv")
        XCTAssertEqual(picked.place, .onlyDrive)
        XCTAssertEqual(picked.bytes, 4_000_000)
        XCTAssertNil(pair.driveFile(pair.macSide), "only the drive's files")

        // A note whose file is gone from the drive says so.
        try FileManager.default.removeItem(atPath: drive + "/moved.mkv")
        let after = try XCTUnwrap(PairPicture.build(real: disk.tree, macFolder: disk.node(mac), macPath: mac, drivePath: drive, driveName: "Spare",
                                                    notes: [note], ghosts: true))
        XCTAssertEqual(after.counts[.missing]?.files, 1)
    }
}
