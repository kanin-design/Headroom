import XCTest
@testable import Headroom

/// A finished tree keeps each different set of numbers and each different name once. Nothing that asks may notice.
final class TablesTests: XCTestCase {
    private func aDisk() -> FakeDisk {
        let disk = FakeDisk()
        for project in 0..<6 {
            for at in 0..<8 {
                _ = disk.file("/Volumes/Fake/p\(project)/src/module\(at)/index.js", 2_000_000, kind: .code)
                _ = disk.file("/Volumes/Fake/p\(project)/build/module\(at)/index.js", 2_000_000, kind: .code)
            }
            _ = disk.file("/Volumes/Fake/p\(project)/film.mov", UInt64(project + 1) * 900_000_000, kind: .video)
        }
        return disk
    }

    private func rows(_ tree: DiskTree) -> [[UInt32]] {
        (0..<tree.count).map { id in
            let row = tree.statRow(id)
            return (0..<DiskTree.statStride).map { row[$0] }
        }
    }

    func testEveryNumberIsStillThere() {
        let disk = aDisk()
        disk.tree.finish()
        let before = rows(disk.tree)
        XCTAssertGreaterThan(before.flatMap { $0 }.reduce(0) { $0 + UInt64($1) }, 0)
        disk.tree.compactStats()
        XCTAssertEqual(rows(disk.tree), before)
        // Twice changes nothing.
        disk.tree.compactStats()
        XCTAssertEqual(rows(disk.tree), before)
    }

    func testChangingOneRowLeavesTheOthersAlone() {
        let disk = aDisk()
        disk.finish()
        let tree = disk.tree
        let one = disk.node("/Volumes/Fake/p0/src/module0"), same = disk.node("/Volumes/Fake/p0/src/module1")
        let kind = Int(Kind.code.rawValue)
        XCTAssertEqual(tree.statRow(one)[kind], tree.statRow(same)[kind], "The same numbers")
        XCTAssertEqual(tree.statRow(one), tree.statRow(same), "So they share a row")

        tree.changeableStatRow(one)[kind] = 77
        XCTAssertEqual(tree.statRow(one)[kind], 77)
        XCTAssertNotEqual(tree.statRow(same)[kind], 77)
        // Its own row now, so it's changed where it is.
        let own = tree.changeableStatRow(one)
        XCTAssertEqual(UnsafePointer(own), tree.statRow(one))
        own[kind] = 78
        XCTAssertEqual(tree.statRow(one)[kind], 78)
    }

    func testRemovingAndPuttingBackGivesTheSameNumbers() {
        let compact = aDisk()
        compact.finish()
        let plain = aDisk()
        plain.tree.finish()
        let before = rows(plain.tree)
        XCTAssertEqual(rows(compact.tree), before)

        let film = "/Volumes/Fake/p3/film.mov", folder = "/Volumes/Fake/p1/src"
        for disk in [compact, plain] { disk.tree.remove(disk.node(film)); disk.tree.remove(disk.node(folder)) }
        XCTAssertEqual(rows(compact.tree), rows(plain.tree), "Taken out, the same in both")
        XCTAssertNotEqual(rows(compact.tree), before)

        for disk in [compact, plain] { disk.tree.restore(disk.node(folder)); disk.tree.restore(disk.node(film)) }
        XCTAssertEqual(rows(compact.tree), before, "Put back, as it was")
        XCTAssertEqual(rows(plain.tree), before)
    }

    func testEveryNameIsStillThere() {
        let disk = aDisk()
        disk.tree.finish()
        let tree = disk.tree
        let names = (0..<tree.count).map { tree.name(UInt32($0)) }
        let paths = (0..<tree.count).map { tree.path(UInt32($0)) }
        var inTable = 0
        for id in 0..<tree.count { inTable += Int(tree.nodes[id].nameLength) }

        let offsetsBefore = (0..<tree.count).map { tree.nodes[$0].nameOffset }
        tree.compactNames()
        XCTAssertEqual((0..<tree.count).map { tree.name(UInt32($0)) }, names)
        XCTAssertEqual((0..<tree.count).map { tree.path(UInt32($0)) }, paths)
        XCTAssertNotEqual((0..<tree.count).map { tree.nodes[$0].nameOffset }, offsetsBefore)
        let module = disk.node("/Volumes/Fake/p0/src/module0"), twin = disk.node("/Volumes/Fake/p5/build/module0")
        XCTAssertEqual(tree.nodes[Int(module)].nameOffset, tree.nodes[Int(twin)].nameOffset, "One name, kept once")
        XCTAssertEqual(tree.find(path: "/Volumes/Fake/p5/build/module0"), twin)
    }

    func testAPictureKeepsItsNamesAfterTheScanMovesOn() {
        let disk = aDisk()
        disk.tree.finish()
        var picture: DiskTree? = disk.tree.picture()
        let names = (0..<disk.tree.count).map { picture!.name(UInt32($0)) }
        disk.tree.compactNames()
        // What was there has been overwritten if anything still pointed at it wrongly.
        XCTAssertEqual((0..<disk.tree.count).map { picture!.name(UInt32($0)) }, names)
        picture = nil
        XCTAssertEqual((0..<disk.tree.count).map { disk.tree.name(UInt32($0)) }, names, "And it going takes nothing with it")
    }
}

/// A project is only suggested when all of this holds, so `Git.read` may stop at the first thing that doesn't.
final class GitStopsEarlyTests: XCTestCase {
    private var root = ""
    private let old = "2024-01-15T12:00:00"

    override func setUpWithError() throws {
        try XCTSkipUnless(Git.isAvailable, "No git here")
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("headroom-git-" + UUID().uuidString).resolvingSymlinksInPath().path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: root) }

    @discardableResult
    private func git(_ arguments: [String], in folder: String, date: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        var environment = ProcessInfo.processInfo.environment
        if let date {
            environment["GIT_AUTHOR_DATE"] = date
            environment["GIT_COMMITTER_DATE"] = date
        }
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
        return String(decoding: data, as: UTF8.self)
    }

    /// A project with one commit, pushed to a remote that's another folder.
    private func project(date: String) throws -> String {
        let remote = root + "/remote-" + UUID().uuidString + ".git"
        let path = root + "/project-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: remote, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try git(["init", "--bare", "-q"], in: remote)
        try git(["init", "-q"], in: path)
        try Data("hello".utf8).write(to: URL(fileURLWithPath: path + "/a.txt"))
        try git(["add", "."], in: path)
        try git(["commit", "-q", "-m", "first"], in: path, date: date)
        try git(["remote", "add", "origin", remote], in: path)
        try git(["push", "-q", "-u", "origin", "HEAD"], in: path)
        return path
    }

    private func isSuggestable(_ fact: Facts.RepoFact?) -> Bool {
        guard let fact, fact.isClean, fact.allPushed, fact.remote != nil, fact.lastCommit != nil else { return false }
        return true
    }

    func testAQuietPushedCleanProjectPassesEverything() throws {
        let fact = Git.read(try project(date: old))
        XCTAssertTrue(isSuggestable(fact))
        XCTAssertNotNil(fact?.remote)
    }

    func testARecentCommitStopsItBeforeAnythingSlow() throws {
        let path = try project(date: old)
        try Data("more".utf8).write(to: URL(fileURLWithPath: path + "/b.txt"))
        try git(["add", "."], in: path)
        try git(["commit", "-q", "-m", "second"], in: path)
        try git(["push", "-q"], in: path)
        let fact = Git.read(path)
        XCTAssertFalse(isSuggestable(fact))
        XCTAssertNotNil(fact?.lastCommit)
    }

    func testAFolderThatIsntAProjectSaysNothing() throws {
        XCTAssertNil(Git.read(root))
    }
}
