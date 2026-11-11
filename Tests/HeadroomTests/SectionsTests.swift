import XCTest
@testable import Headroom

/// The boxes in Free Up: one set of data for the list and the ring.
final class SectionsTests: XCTestCase {
    private let gb: UInt64 = 1_000_000_000

    private func found(_ disk: FakeDisk) -> [String: Leftovers.Role] {
        disk.finish()
        var out: [String: Leftovers.Role] = [:]
        for one in Leftovers.find(in: disk.tree) { out[disk.tree.path(one.node) ?? "?"] = one.role }
        return out
    }

    // MARK: What counts as left over

    func testAProjectsScenesAndStillsAreLeftOver() {
        let d = FakeDisk()
        d.file("/Volumes/Fake/film/final/film-v3-4k.mp4", gb, kind: .video)
        d.file("/Volumes/Fake/film/renders/scenes/a.mp4", gb, kind: .video)
        d.file("/Volumes/Fake/film/review/stills/f1.png", gb, kind: .image)
        let roles = found(d)
        XCTAssertEqual(roles["/Volumes/Fake/film/renders/scenes"], .scenes)
        XCTAssertEqual(roles["/Volumes/Fake/film/review"], .review)
        XCTAssertNil(roles["/Volumes/Fake/film/final/film-v3-4k.mp4"], "The newest of a film stays")
    }

    func testAFolderCalledWorkOutsideAProjectMeansNothing() {
        let d = FakeDisk()
        d.file("/Volumes/Fake/holiday/work/photo.png", gb, kind: .image)
        XCTAssertTrue(found(d).isEmpty)
    }

    func testTestsFullOfCodeAreNotLeftovers() {
        let d = FakeDisk()
        d.file("/Volumes/Fake/app/src/main.c", 10_000_000, kind: .code)
        d.file("/Volumes/Fake/app/third_party/openssl/test/data.bin", gb, kind: .code)
        XCTAssertTrue(found(d).isEmpty, "A folder of code called test is part of the code")
    }

    func testAFileWithTestInItsNameIsLeftAlone() {
        let d = FakeDisk()
        d.file("/Volumes/Fake/film/renders/x.mp4", 1000, kind: .video)
        d.file("/Volumes/Fake/film/source/raw/TestReel1941.mp4", gb, kind: .video)
        XCTAssertNil(found(d)["/Volumes/Fake/film/source/raw/TestReel1941.mp4"])
    }

    func testWhatsKeptOnPurposeIsNeverSuggested() {
        let d = FakeDisk()
        d.file("/Volumes/Fake/GOLD versions/film-v14-4k.mp4", gb, kind: .video)
        d.file("/Volumes/Fake/GOLD versions/film-v16-4k.mp4", gb, kind: .video)
        d.file("/Volumes/Fake/film/final/eye-v23-SAVED-4k.mp4", gb, kind: .video)
        d.file("/Volumes/Fake/film/final/eye-v25-4k.mp4", gb, kind: .video)
        let roles = found(d)
        XCTAssertNil(roles["/Volumes/Fake/GOLD versions/film-v14-4k.mp4"], "A folder named for keeping")
        XCTAssertNil(roles["/Volumes/Fake/film/final/eye-v23-SAVED-4k.mp4"], "A file named for keeping, even with a newer one beside it")
    }

    func testOlderVersionsAreFoundAndTheNewestStays() {
        let d = FakeDisk()
        d.file("/Volumes/Fake/film/renders/film-v14-4k.mp4", gb, kind: .video)
        d.file("/Volumes/Fake/film/renders/film-v15-4k.mp4", gb, kind: .video)
        d.file("/Volumes/Fake/film/final/film-v16-4k.mp4", gb, kind: .video)
        d.file("/Volumes/Fake/film/final/film-v15-1080p.mp4", gb, kind: .video)
        let roles = found(d)
        XCTAssertEqual(roles["/Volumes/Fake/film/renders/film-v14-4k.mp4"], .olderVersions)
        XCTAssertEqual(roles["/Volumes/Fake/film/renders/film-v15-4k.mp4"], .olderVersions)
        XCTAssertEqual(roles["/Volumes/Fake/film/final/film-v15-1080p.mp4"], .olderFinals, "An older one among the finals has a box of its own")
        XCTAssertNil(roles["/Volumes/Fake/film/final/film-v16-4k.mp4"])
    }

    func testOlderNumberedFoldersGoAndTheNewestStays() {
        let d = FakeDisk()
        d.file("/Volumes/Fake/voice/.git/config", 1000)
        for v in [3, 8, 9] { d.file("/Volumes/Fake/voice/out/v\(v)/take.m4a", gb, kind: .audio) }
        let roles = found(d)
        XCTAssertEqual(roles["/Volumes/Fake/voice/out/v3"], .oldFolders)
        XCTAssertEqual(roles["/Volumes/Fake/voice/out/v8"], .oldFolders)
        XCTAssertNil(roles["/Volumes/Fake/voice/out/v9"])
        XCTAssertNil(roles["/Volumes/Fake/voice/out"], "An output folder as a whole isn't left over")
    }

    func testANumberedSetOfOutputsNeedsNoProjectAroundIt() {
        let d = FakeDisk()
        for v in [7, 8] { d.file("/Volumes/Fake/voice/out/v\(v)/take.m4a", gb, kind: .audio) }
        XCTAssertEqual(found(d)["/Volumes/Fake/voice/out/v7"], .oldFolders)
    }

    func testALeftoverIsCalledWhatYoudCallIt() throws {
        let d = FakeDisk()
        d.file("/Volumes/Fake/dev/films/eye/final/eye-v3.mp4", gb, kind: .video)
        d.file("/Volumes/Fake/dev/films/eye/work/a/still.png", gb, kind: .image)
        d.finish()
        let rows = Sections.build(from: [], tree: d.tree).rows
        XCTAssertEqual(rows.first?.title, "eye › work", "From the project down, not the whole way from the disk")
    }

    func testAModelIsCalledByItsOwnName() throws {
        let d = FakeDisk()
        d.file("/Volumes/Fake/LLM/hub/m/w.bin", gb)
        d.finish()
        var one = row("model:google/gemma", d, "/Volumes/Fake/LLM/hub/m", tier: .redownload)
        one.title = "google/gemma"
        one.subtitle = "Re-downloadable from Hugging Face · Downloaded Oct 9"
        one.box = .models
        let models = try XCTUnwrap(Sections.build(from: [one], tree: d.tree).sections.first { $0.id == "models" })
        XCTAssertEqual(models.rows.first?.title, "gemma")
        XCTAssertEqual(models.rows.first?.subtitle, "Downloaded Oct 9", "It says when it arrived, and doesn't claim it's old")
        XCTAssertEqual(models.rows.first?.id, "model:google/gemma", "Keeping it still means keeping it")
    }

    func testNumberedFoldersOfCodeStay() {
        let d = FakeDisk()
        d.file("/Volumes/Fake/server/.git/config", 1000)
        for v in [1, 2] { d.file("/Volumes/Fake/server/api/v\(v)/routes.swift", gb, kind: .code) }
        XCTAssertTrue(found(d).isEmpty)
    }

    func testOtherCopiesOfAProjectAreLeftToGit() {
        let d = FakeDisk()
        d.file("/Volumes/Fake/app/.claude/worktrees/one/film/renders/x.mp4", 1000, kind: .video)
        d.file("/Volumes/Fake/app/.claude/worktrees/one/film/review/still.png", gb, kind: .image)
        d.file("/Volumes/Fake/app/.claude/worktrees/one/App-1.0.dmg", gb)
        XCTAssertTrue(found(d).isEmpty)
    }

    func testOnlyTheOutermostFolderIsNamed() {
        let d = FakeDisk()
        d.file("/Volumes/Fake/film/renders/x.mp4", 1000, kind: .video)
        d.file("/Volumes/Fake/film/review/stills/f1.png", gb, kind: .image)
        d.file("/Volumes/Fake/film/review/seq/f2.png", gb, kind: .image)
        let roles = found(d)
        XCTAssertEqual(roles["/Volumes/Fake/film/review"], .review)
        XCTAssertNil(roles["/Volumes/Fake/film/review/stills"])
        XCTAssertNil(roles["/Volumes/Fake/film/review/seq"])
    }

    func testVersionNumbersAreReadFromTheName() {
        func read(_ name: String) -> (Int, Int)? {
            Array(name.utf8).withUnsafeBufferPointer { Leftovers.version(of: $0).map { ($0.stem, $0.version) } }
        }
        XCTAssertEqual(read("film-v12-4k.mp4")?.0, 4)
        XCTAssertEqual(read("film-v12-4k.mp4")?.1, 12)
        XCTAssertEqual(read("film_v3.mov")?.1, 3)
        XCTAssertNil(read("avatar.mp4"))
        XCTAssertNil(read("dev3tools.mp4"), "A v inside a word isn't a version")
        XCTAssertNil(read("film-v2x.mp4"))
    }

    // MARK: The list

    private func row(_ id: String, _ d: FakeDisk, _ path: String, tier: Tier = .yourCall, quick: Bool = false, action: WinAction = .trash, askFirst: Bool = false, box: BoxKind? = nil) -> WinRow {
        let node = d.node(path)
        var r = WinRow(id: id, title: id, subtitle: "", detail: "", tier: tier, nodes: [node], bytes: d.tree.totals[Int(node)], paperBytes: d.tree.totals[Int(node)], action: action, command: nil, bundleID: nil)
        r.isQuick = quick
        r.askFirst = askFirst
        // As the finders say it: a model's row is in AI models, and so on.
        r.box = box ?? (id.hasPrefix("model:") || id == "group:models" ? .models : id.hasPrefix("series:") ? .media : .other)
        return r
    }

    func testEachThingGoesInTheBoxItsFinderNamed() {
        let d = FakeDisk()
        d.file("/Volumes/Fake/Trash/a", gb)
        d.file("/Volumes/Fake/app/cache/b", 2 * gb)
        d.file("/Volumes/Fake/LLM/model/c", 3 * gb)
        d.file("/Volumes/Fake/TV/Show/S01E01.mp4", 50 * gb, kind: .video)
        d.file("/Volumes/Fake/film/renders/x.mp4", 1000, kind: .video)
        d.file("/Volumes/Fake/film/review/still.png", 4 * gb, kind: .image)
        d.finish()
        let rows = [row("series:show", d, "/Volumes/Fake/TV/Show"), row("model:m", d, "/Volumes/Fake/LLM/model", tier: .redownload),
                    row("Spotify cache", d, "/Volumes/Fake/app/cache", tier: .rebuilds, quick: true, box: .caches),
                    row("trash", d, "/Volumes/Fake/Trash", tier: .noLoss, quick: true, action: .emptyTrash, box: .trash)]
        let sections = Sections.build(from: rows, tree: d.tree).sections
        XCTAssertEqual(Set(sections.map(\.id)), ["caches", "trash", "models", "leftovers", "largest"], "No box for the series: a collection isn't a suggestion")
        XCTAssertEqual(sections.first { $0.id == "largest" }?.rows.map(\.title), ["S01E01.mp4"], "Its one huge episode is among the largest files, though")
        let boxes = Sections.boxes(from: sections, tree: d.tree, focus: 0, kept: [])
        XCTAssertEqual(boxes.map(\.id), ["trash", "leftovers", "models", "caches", "largest"], "The Trash first, then biggest first, and the shortlist under them")
        XCTAssertEqual(boxes.first { $0.id == "trash" }?.isOneThing, true, "The Trash has nothing to open: it's one row with its own tick")
        XCTAssertEqual(boxes.first { $0.id == "caches" }?.detail, "Spotify", "A cache is named for its app")
    }

    func testAGroupOfThingsBecomesOneThingEach() {
        let d = FakeDisk()
        d.file("/Volumes/Fake/LLM/a/w", gb)
        d.file("/Volumes/Fake/LLM/b/w", 2 * gb)
        d.finish()
        var group = row("group:models", d, "/Volumes/Fake/LLM", tier: .redownload)
        group.parts = [row("model:a", d, "/Volumes/Fake/LLM/a", tier: .redownload), row("model:b", d, "/Volumes/Fake/LLM/b", tier: .redownload)]
        let models = Sections.build(from: [group], tree: d.tree).sections.first { $0.id == "models" }
        XCTAssertEqual(models?.rows.map(\.id), ["model:b", "model:a"], "Biggest first")
    }

    func testWhatCantBeTickedStaysOutOfTheBoxes() {
        let d = FakeDisk()
        d.file("/Volumes/Fake/x/y", gb)
        d.finish()
        let built = Sections.build(from: [row("restart", d, "/Volumes/Fake/x", tier: .noLoss, action: .restart)], tree: d.tree)
        XCTAssertTrue(built.sections.isEmpty)
        XCTAssertEqual(built.others.map(\.id), ["restart"])
    }

    // MARK: The picture on screen

    private func filmDisk() -> FakeDisk {
        let d = FakeDisk()
        d.file("/Volumes/Fake/film/renders/x.mp4", 1000, kind: .video)
        d.file("/Volumes/Fake/film/review/still.png", 4 * gb, kind: .image)
        d.file("/Volumes/Fake/film/work/a.png", 2 * gb, kind: .image)
        d.file("/Volumes/Fake/LLM/a/w", gb)
        d.file("/Volumes/Fake/LLM/b/w", 2 * gb)
        d.finish()
        return d
    }

    private func filmSections(_ d: FakeDisk) -> [Section] {
        Sections.build(from: [row("model:a", d, "/Volumes/Fake/LLM/a", tier: .redownload), row("model:b", d, "/Volumes/Fake/LLM/b", tier: .redownload)], tree: d.tree).sections
    }

    func testOnTheWholeDiskASectionIsOneBox() throws {
        let d = filmDisk()
        let boxes = Sections.boxes(from: filmSections(d), tree: d.tree, focus: 0, kept: [])
        XCTAssertEqual(boxes.map(\.id), ["leftovers", "models"], "Biggest first")
        let leftovers = try XCTUnwrap(boxes.first)
        XCTAssertEqual(leftovers.kids.map(\.title), ["Review stills and clips", "Working folders"])
        XCTAssertEqual(leftovers.rows.count, 2, "Ticking it takes everything inside")
    }

    func testInsideAFolderKindsBecomeBoxesOfTheirOwn() {
        let d = filmDisk()
        let boxes = Sections.boxes(from: filmSections(d), tree: d.tree, focus: d.node("/Volumes/Fake/film"), kept: [])
        XCTAssertEqual(boxes.map(\.title), ["Review stills and clips", "Working folders"])
    }

    func testAFolderThatsAllOneKindHasABoxForEachThing() {
        let d = filmDisk()
        let boxes = Sections.boxes(from: filmSections(d), tree: d.tree, focus: d.node("/Volumes/Fake/LLM"), kept: [])
        XCTAssertEqual(boxes.map(\.title), ["model:b", "model:a"])
        XCTAssertTrue(boxes.allSatisfy(\.isOneThing))
        XCTAssertEqual(Set(boxes.map { $0.color.l }).count, 2, "Each has a colour of its own")
    }

    func testWhatYoureKeepingLeavesItsBox() {
        let d = filmDisk()
        let boxes = Sections.boxes(from: filmSections(d), tree: d.tree, focus: 0, kept: ["model:a"])
        XCTAssertEqual(boxes.first { $0.id == "models" }?.rows.map(\.id), ["model:b"])
    }

    func testAnAppKeepsItsSettingsWhenYoureLookingAtApplications() throws {
        let d = FakeDisk()
        d.file("/Volumes/Fake/Applications/A.app/bin", gb)
        d.file("/Volumes/Fake/Library/Preferences/a.plist", 2_000_000)
        d.finish()
        var app = row("app:a", d, "/Volumes/Fake/Applications/A.app", action: .uninstall)
        app.nodes.append(d.node("/Volumes/Fake/Library/Preferences"))
        let inFolder = try XCTUnwrap(Sections.scoped(app, tree: d.tree, focus: d.node("/Volumes/Fake/Applications")))
        XCTAssertEqual(inFolder.nodes.count, 2, "Uninstalling is the app and what belongs to it")
    }

    func testATickLeavesOutWhatYouSetUpByHand() {
        let d = filmDisk()
        let hand = row("model:a", d, "/Volumes/Fake/LLM/a", tier: .redownload, askFirst: true)
        let plain = row("model:b", d, "/Volumes/Fake/LLM/b", tier: .redownload)
        let box = Box(id: "models", title: "AI models", detail: "", color: Palette.Box.models, rows: [plain, hand])
        XCTAssertEqual(box.rowsATickTakes.map(\.id), ["model:b"])
        let onlyHand = Box(id: "games", title: "Games", detail: "", color: Palette.Box.games, rows: [hand])
        XCTAssertEqual(onlyHand.rowsATickTakes.map(\.id), ["model:a"], "With nothing else in the box, a tick can only mean that")
    }

    func testEveryThingInABoxHasAColour() {
        let d = filmDisk()
        let boxes = Sections.boxes(from: filmSections(d), tree: d.tree, focus: 0, kept: [])
        let colours = Sections.colours(for: boxes)
        for row in boxes.flatMap(\.rows) { XCTAssertNotNil(colours[row.id], row.id) }
    }

    func testTheMapKnowsWhichThingAFileBelongsTo() {
        let d = filmDisk()
        let map = ReclaimMap(tree: d.tree, rows: [row("outer", d, "/Volumes/Fake/LLM"), row("inner", d, "/Volumes/Fake/LLM/a")])
        XCTAssertEqual(map.rowIndex(of: d.node("/Volumes/Fake/LLM/b/w")), 0)
        XCTAssertEqual(map.rowIndex(of: d.node("/Volumes/Fake/LLM/a/w")), 1, "The smaller one inside it wins")
        XCTAssertNil(map.rowIndex(of: d.node("/Volumes/Fake/film/review/still.png")))
    }

    // MARK: What lights up

    private func ring(_ d: FakeDisk, focus: UInt32 = 0) -> RingLayout {
        RingLayout.build(tree: d.tree, focus: focus, colorer: { _ in .zero })
    }

    func testPointingAtSomethingLightsItsPieceAndWhatsInsideIt() throws {
        let d = filmDisk()
        let layout = ring(d)
        let lit = layout.lit(by: [d.node("/Volumes/Fake/LLM")], tree: d.tree)
        let first = try XCTUnwrap(lit.full.first)
        XCTAssertGreaterThan(first.count, 1, "Its children light with it")
    }

    func testAChainDrawnAsOneStillLights() throws {
        let d = FakeDisk()
        d.file("/Volumes/Fake/a/review/stills/f.png", 40 * gb, kind: .image)
        d.file("/Volumes/Fake/a/small.bin", 1_000_000)
        d.finish()
        let stills = d.node("/Volumes/Fake/a/review/stills")
        let layout = ring(d)
        XCTAssertFalse(layout.pieces.contains { $0.node == stills }, "It has no piece of its own: the chain is drawn as one")
        let lit = layout.lit(by: [stills], tree: d.tree)
        XCTAssertFalse(lit.full.isEmpty && lit.holding.isEmpty, "It lights all the same")
    }

    func testSomethingTooSmallToDrawLightsWhatHoldsIt() {
        let d = FakeDisk()
        for i in 0..<40 { d.file("/Volumes/Fake/big/f\(i).bin", 10 * gb) }
        d.file("/Volumes/Fake/big/tiny/t.bin", 2_000_000)
        d.finish()
        let tiny = d.node("/Volumes/Fake/big/tiny")
        let layout = ring(d)
        XCTAssertFalse(layout.pieces.contains { $0.node == tiny && !$0.isSmaller })
        let lit = layout.lit(by: [tiny], tree: d.tree)
        XCTAssertFalse(lit.holding.isEmpty, "Whatever holds it lights instead of nothing at all")
    }
}
