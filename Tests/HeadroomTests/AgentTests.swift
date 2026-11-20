import Darwin
import XCTest
@_spi(Diagnostics) import SunburstAgents
@testable import Headroom

/// Headroom's side of the agents' way in: what Headroom tells them, its tools and what they read, and that none of it can
/// remove anything. The door itself (the protocol, the socket, your answer to an agent that asks, the relay) is
/// SunburstAgents', and is tested there.
@MainActor
final class AgentTests: XCTestCase {
    // MARK: What agents are told

    private func session() -> AgentSession { AgentSession(AgentServer.host(version: "1.2.3")) }

    private func ask(_ session: AgentSession, _ message: [String: Any]) async throws -> [String: Any]? {
        let line = try JSONSerialization.data(withJSONObject: message)
        guard let reply = await session.handle(line) else { return nil }
        XCTAssertFalse(reply.contains(0x0A), "an answer is one line")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    /// Where the door is, and what an agent is told when it says hello, are what they were before the door moved into
    /// SunburstAgents: agents set up before find it, and agents allowed before are still allowed.
    func testHeadroomsDoorIsWhereItWasAndSaysTheSame() async throws {
        let host = AgentServer.host(version: "1.2.3")
        XCTAssertEqual(host.socketPath, AppData.folder.appendingPathComponent("agent.sock").path)
        XCTAssertEqual(host.allowListFile, AppData.folder.appendingPathComponent("agents.json"))
        XCTAssertEqual(host.tools.map(\.name), AgentLook.tools.map(\.name))
        XCTAssertEqual(host.tools.map(\.selects), AgentLook.tools.map(\.selects))

        let reply = try await ask(session(), ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                              "params": ["protocolVersion": "2025-03-26", "clientInfo": ["name": "test-agent", "version": "9"]]])
        let result = try XCTUnwrap(reply?["result"] as? [String: Any])
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "Headroom")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["version"] as? String, "1.2.3")
        XCTAssertEqual(result["instructions"] as? String, AgentServer.instructions)
        XCTAssertTrue(AgentServer.instructions.hasPrefix("Headroom is the app where the user sees their disk and decides what goes."))
        XCTAssertTrue(AgentServer.instructions.hasSuffix("the user has to allow each agent there."))
        let unknown = try await ask(session(), ["jsonrpc": "2.0", "id": 2, "method": "resources/list"])
        XCTAssertEqual((unknown?["error"] as? [String: Any])?["message"] as? String, "Headroom doesn't know resources/list.")
    }

    /// What an agent is told when you haven't answered, said no, or said it may only look, and what the list of what
    /// agents did says, as Headroom says them. A door of Headroom's own make, in a folder of the test's own, with an answer
    /// that never reaches the app.
    func testAgentsAreToldWhatYouDecidedInHeadroomsWords() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HeadroomAgentTests-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: folder) }
        var host = AgentServer.host(version: "1.2.3")
        host.folder = folder
        let door = AgentServer.makeDoor(host) { call in .json(["answered": call.tool]) }
        door.patience = .milliseconds(50)
        func call(_ session: AgentSession, _ id: Int, _ tool: String, _ arguments: [String: Any] = [:]) async throws -> (text: String?, isError: Bool?) {
            let result = try await ask(session, ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": arguments]])?["result"] as? [String: Any]
            return ((result?["content"] as? [[String: Any]])?.first?["text"] as? String, result?["isError"] as? Bool)
        }
        let agent = door.session(program: "/Applications/Test.app", signer: nil)
        _ = try await ask(agent, ["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": ["clientInfo": ["name": "Test Agent"]]])

        let waiting = try await call(agent, 1, "overview")
        XCTAssertEqual(waiting.text, "Waiting for the user to allow this agent. Headroom is asking in its window: ask the user to answer there, then try again.")
        XCTAssertEqual(waiting.isError, true)

        door.agents.answer(try XCTUnwrap(door.agents.requests.first), .lookOnly)
        let looked = try await call(agent, 2, "overview")
        XCTAssertEqual(looked.text, #"{"answered":"overview"}"#)
        XCTAssertEqual(looked.isError, false)
        for tool in AgentLook.tools.filter(\.selects).map(\.name) {
            let refused = try await call(agent, 3, tool, ["paths": ["/x"], "reason": "test"])
            XCTAssertEqual(refused.text, "The user allowed this agent to look only. They can change that in Headroom, under Agents in the app menu.", tool)
        }

        door.agents.setMaySelect(door.agents.allowed[0], true)
        _ = try await call(agent, 4, "select", ["paths": ["/Volumes/Fake/a", "/Volumes/Fake/b"], "reason": "test"])
        XCTAssertEqual(door.agents.activity.last?.what, "select: 2 paths, first /Volumes/Fake/a", "the list of what agents did reads as it did")

        let stranger = door.session(program: "/opt/stranger", signer: nil)
        _ = try await ask(stranger, ["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": ["clientInfo": ["name": "Stranger"]]])
        door.agents.answer(try XCTUnwrap(door.agents.requests.first { $0.identity.name == "Stranger" }), .deny)
        let denied = try await call(stranger, 5, "overview")
        XCTAssertEqual(denied.text, "The user didn't allow this agent to use Headroom.")
    }

    func testEveryToolIsListedAndNoneOfThemRemovesAnything() async throws {
        let reply = try await ask(session(), ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let tools = try XCTUnwrap((reply?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String },
                       ["overview", "check", "list_suggestions", "list_duplicates", "get_plan", "select", "select_suggestions", "deselect", "show", "switch_disk",
                        "get_backup", "select_for_backup", "deselect_for_backup", "set_backup_drive", "verify_moved", "wait_for_backup", "wait_for_clean"])
        XCTAssertEqual(AgentLook.tools.filter(\.selects).map(\.name),
                       ["select", "select_suggestions", "deselect", "show", "switch_disk", "select_for_backup", "deselect_for_backup", "set_backup_drive", "verify_moved"],
                       "these need more than looking")
        // An agent looks at the disk with its own tools. Headroom is where it marks, not where it browses.
        for word in ["list_folder", "search", "find"] { XCTAssertFalse(tools.contains { $0["name"] as? String == word }) }
        for tool in tools {
            XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object")
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty)
        }
        // An agent selects, and you clean. Nothing it can call takes anything off the disk.
        for word in ["remove", "delete", "trash", "clean", "undo", "empty", "move", "uninstall"] {
            XCTAssertFalse(tools.contains { ($0["name"] as? String ?? "").hasPrefix(word) }, "\(word) isn't offered")
        }
    }

    /// Deleting is the user's click, always. So it isn't a rule the agents' code follows: that code has no way to do it.
    /// Nothing an agent can reach calls anything that removes, empties, undoes or presses Clean: not Headroom's tools and
    /// what answers them, and not the door they come in by, in SunburstAgents.
    func testNothingAnAgentCanReachCanRemoveAnything() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/Headroom")
        let headroom = try FileManager.default.contentsOfDirectory(at: sources.appendingPathComponent("Agents"), includingPropertiesForKeys: nil)
            + [sources.appendingPathComponent("Model/AppModel+Agents.swift"), sources.appendingPathComponent("UI/AgentsView.swift")]
        let door = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Packages/SunburstKit/Sources/SunburstAgents"),
                                                               includingPropertiesForKeys: nil)
        XCTAssertGreaterThanOrEqual(headroom.count, 5, "all of Headroom's agent code is read")
        XCTAssertGreaterThanOrEqual(door.count, 8, "and all of the door's")
        XCTAssertTrue(door.contains { $0.lastPathComponent == "AgentSocket.swift" })
        XCTAssertTrue(door.contains { $0.lastPathComponent == "AgentDoor.swift" })
        // Every way the app has of taking something off the disk, out of the Trash, or back again.
        let removes = ["cleanNow(", "emptyNow(", "sendToTrash(", "sendAnyway(", "undoClean(", "undoCommand(", "putBack(", "takeCopies(", "leaveInTrash(",
                       "deleteForGood(", "deleteFromTrash(", "replaceCopy(", "copyAndVerify(", "Cleaner.trash(", "Cleaner.run", "trashContents(",
                       "removeItem(", "trashItem(", "moveItem(", "performClick", "cleanAnyway",
                       // Backup's: moving, copying, bringing back and deleting from a drive are the user's clicks too.
                       "runBackup(", "bringBack(", "deleteLastCopy(", "copyToMac(", "deleteFromDrive(", "DriveMover.send(", "DriveMover.copy(",
                       "unlink(", "rename("]
        for file in headroom + door {
            let code = try String(contentsOf: file, encoding: .utf8)
            // The socket's own file is the one thing the door's code may take away, and only when it is a socket.
            if file.lastPathComponent == "AgentSocket.swift" {
                XCTAssertEqual(code.components(separatedBy: "unlink(").count - 1, 1, "one place that removes a file")
                XCTAssertTrue(code.contains("S_IFSOCK"), "and it removes only a socket")
                for call in removes where call != "unlink(" { XCTAssertFalse(code.contains(call), "\(file.lastPathComponent) calls \(call)") }
                continue
            }
            for call in removes {
                XCTAssertFalse(code.contains(call), "\(file.lastPathComponent) calls \(call): an agent must have no way to remove anything")
            }
        }
        // And the tools an agent is given are exactly these. A new one has to be added here, where this is read.
        XCTAssertEqual(AgentLook.tools.map(\.name),
                       ["overview", "check", "list_suggestions", "list_duplicates", "get_plan", "select", "select_suggestions", "deselect", "show", "switch_disk",
                        "get_backup", "select_for_backup", "deselect_for_backup", "set_backup_drive", "verify_moved", "wait_for_backup", "wait_for_clean"])
        XCTAssertEqual(AgentServer.host(version: "").tools.map(\.name), AgentLook.tools.map(\.name), "and they're all the door offers")
    }

    // MARK: What Headroom knows about a path

    private func disk() -> FakeDisk {
        let disk = FakeDisk()
        let now = UInt32(Date().timeIntervalSince1970)
        disk.file("/Volumes/Fake/Films/Big.mkv", 8_000_000_000, kind: .video, modTime: now - 400 * 86_400)
        disk.file("/Volumes/Fake/Films/Small.mkv", 1_000_000_000, kind: .video, modTime: now - 2 * 86_400)
        disk.file("/Volumes/Fake/Work/report.pdf", 300_000_000, kind: .document, modTime: now - 30 * 86_400)
        disk.file("/Volumes/Fake/Work/Old/installer.dmg", 2_000_000_000, kind: .archive, modTime: now - 200 * 86_400)
        disk.finish()
        return disk
    }

    private let rules = RuleBook(homePath: NSHomeDirectory())

    func testWhatIsntOnTheMapIsSaidSo() throws {
        let tree = disk().tree
        XCTAssertThrowsError(try AgentLook.node("/Volumes/Fake/Nowhere", in: tree))
        XCTAssertThrowsError(try AgentLook.node("/etc/passwd", in: tree), "a path the scan never saw is not something to answer about")
        XCTAssertThrowsError(try AgentLook.node("node:\(tree.free)@00000000", in: tree), "a reference from another scan is refused, not guessed at")
        XCTAssertThrowsError(try AgentLook.node("node:99999999@\(tree.scanID.uuidString.prefix(8))", in: tree))
        XCTAssertEqual(try AgentLook.node("/Volumes/Fake/Films/", in: tree), disk().node("/Volumes/Fake/Films"), "a slash at the end is the same folder")
        XCTAssertEqual(AgentLook.written("~/x/"), NSHomeDirectory() + "/x")
        XCTAssertEqual(AgentLook.real("/tmp/x"), "/private/tmp/x", "a link on the way is followed, so the map's own path is found")
        XCTAssertNil(AgentLook.real("/no/such/folder/x"))
    }

    func testCheckingAPathSaysWhatItIsAndWhetherItCouldGo() throws {
        let tree = disk().tree
        let work = AgentLook.check("/Volumes/Fake/Work", in: tree, rules: rules, plan: PlanList())
        XCTAssertEqual(work["on_the_map"] as? Bool, true)
        XCTAssertEqual(work["inside"] as? String, "/Volumes/Fake")
        XCTAssertEqual((work["holds"] as? [[String: Any]])?.compactMap { $0["kind"] as? String }, ["Archives", "Documents"], "the kinds in it, most first")
        XCTAssertEqual(work["headroom_would_remove_it"] as? Bool, true)
        XCTAssertEqual(work["frees"] as? UInt64, 2_300_000_000)
        XCTAssertNil(work["shared_with_other_copies"])
        XCTAssertEqual(work["selected_for_removal"] as? Bool, false)
        XCTAssertEqual(AgentLook.check("/Volumes/Fake", in: tree, rules: rules, plan: PlanList())["headroom_would_remove_it"] as? Bool, false, "a whole disk never goes")
        XCTAssertEqual(AgentLook.check("/Volumes/Fake/Nowhere", in: tree, rules: rules, plan: PlanList())["exists"] as? Bool, false)
    }

    func testAHardlinkedFileSaysItFreesNothingAndWhereItsOtherCopyIs() throws {
        let disk = FakeDisk()
        disk.linked("/Volumes/Fake/Media/Film.mkv", "/Volumes/Fake/Downloads/film.mkv", 4_000_000_000)
        disk.file("/Volumes/Fake/Media/Other.mkv", 1_000_000_000, kind: .video)
        disk.finish()
        let tree = disk.tree
        let film = disk.node("/Volumes/Fake/Media/Film.mkv"), download = disk.node("/Volumes/Fake/Downloads/film.mkv")

        let alone = AgentLook.gain(of: film, in: tree)
        XCTAssertEqual(alone["frees"] as? UInt64, 0, "its other path keeps every byte")
        let shared = try XCTUnwrap(alone["shared_with_other_copies"] as? [String: Any])
        XCTAssertEqual(shared["size"] as? UInt64, 4_000_000_000)
        XCTAssertEqual(shared["paths"] as? [String], ["/Volumes/Fake/Downloads/film.mkv"], "and the agent is told where that is")

        let theLink = AgentLook.gain(of: download, in: tree)
        XCTAssertEqual(theLink["frees"] as? UInt64, 0)
        XCTAssertNotNil(theLink["shared_with_other_copies"])

        // Whichever copy is selected last is the one that frees the file, and it says so.
        for (last, first) in [(film, download), (download, film)] {
            let together = AgentLook.gain(of: last, with: [first, last], in: tree)
            XCTAssertEqual(together["frees"] as? UInt64, 4_000_000_000, "with the other copy going too, selecting this one frees the file")
            XCTAssertNil(together["shared_with_other_copies"])
        }
        let other = disk.node("/Volumes/Fake/Media/Other.mkv")
        XCTAssertEqual(AgentLook.gain(of: other, with: [film, download, other], in: tree)["frees"] as? UInt64, 1_000_000_000, "what it adds, not what everything frees")
        XCTAssertNil(AgentLook.gain(of: disk.node("/Volumes/Fake/Media/Other.mkv"), in: tree)["shared_with_other_copies"])
    }

    func testThePlanIsReadWithItsChecks() {
        var list = PlanList()
        list.add(PlanItem(id: "path:/Volumes/Fake/Work/Old", title: "Old", note: "", tierRaw: Tier.yourCall.rawValue, paths: ["/Volumes/Fake/Work/Old"]))
        var numbers = PlanNumbers()
        numbers.total = 2_000_000_000
        numbers.byItem = ["path:/Volumes/Fake/Work/Old": 2_000_000_000]
        let checks = ["path:/Volumes/Fake/Work/Old": ItemCheck(problems: [.appOpen(name: "Preview", bundleID: "com.apple.Preview")])]
        let plan = AgentLook.plan(list, numbers: numbers, checks: checks, isChecking: false, isCleaning: false)
        XCTAssertEqual(plan["frees"] as? UInt64, 2_000_000_000)
        let item = (plan["items"] as? [[String: Any]])?.first
        XCTAssertEqual(item?["paths"] as? [String], ["/Volumes/Fake/Work/Old"])
        XCTAssertEqual(item?["step"] as? String, "Move to Trash")
        XCTAssertEqual(item?["can_go"] as? Bool, false)
        XCTAssertEqual(item?["checks"] as? [String], ["Preview is open."])
        XCTAssertNotNil(AgentJSON.line(plan), "and it can be written as JSON")
    }

    /// What the Clean button says is what the agent is told: what's held back waits, and Clean takes the rest.
    func testThePlanSaysWhatCleanTakesNowAndWhatWaits() {
        var list = PlanList()
        for (name, bytes) in [("Spotify", UInt64(6_000_000_000)), ("Gradle", UInt64(4_000_000_000)), ("Fresh", UInt64(1_000_000_000))] {
            list.add(PlanItem(id: "path:/Volumes/Fake/\(name)", title: name, note: "", tierRaw: Tier.rebuilds.rawValue, paths: ["/Volumes/Fake/\(name)"], lastKnownBytes: bytes))
        }
        var numbers = PlanNumbers()
        numbers.total = 11_000_000_000
        numbers.byItem = ["path:/Volumes/Fake/Spotify": 6_000_000_000, "path:/Volumes/Fake/Gradle": 4_000_000_000]
        let checks = ["path:/Volumes/Fake/Spotify": ItemCheck(problems: [.inUse(process: "Spotify", pid: 1)]), "path:/Volumes/Fake/Gradle": ItemCheck()]
        let plan = AgentLook.plan(list, numbers: numbers, checks: checks, isChecking: false, isCleaning: false)
        XCTAssertEqual(plan["frees"] as? UInt64, 11_000_000_000)
        XCTAssertEqual(plan["clean_now_frees"] as? UInt64, 5_000_000_000, "what's in use waits: Clean takes the rest")
        XCTAssertTrue((plan["held_back"] as? String ?? "").hasPrefix("1 of 3 items wait"))
        let items = plan["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(items.map { $0["can_go"] as? Bool }, [false, true, nil])
        XCTAssertEqual(items.last?["checked"] as? Bool, false, "and what hasn't been looked at yet says so")
        XCTAssertNil(AgentLook.plan(list, numbers: numbers, checks: [:], isChecking: false, isCleaning: false)["held_back"])
    }

    func testAPathInUseIsSaidToBe() throws {
        // In the home folder, where the files an agent selects are: the temporary folder is reached through a link.
        let file = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/HeadroomTests-held-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        holder.arguments = ["-f", file.path]
        holder.standardOutput = FileHandle.nullDevice
        try holder.run()
        defer { holder.terminate() }
        var said: String?
        for _ in 0..<40 {
            said = AgentLook.inUse(file.path, open: OpenFiles.snapshot())
            if said != nil { break }
            usleep(50_000)
        }
        XCTAssertTrue(said?.hasPrefix("tail has files open here") ?? false, said ?? "nothing said")
        XCTAssertTrue(said?.contains("Clean anyway") ?? false, "and what that means when the user cleans")
        XCTAssertNil(AgentLook.inUse(file.deletingLastPathComponent().appendingPathComponent("nobody-\(UUID().uuidString)").path, open: OpenFiles.snapshot()))
        XCTAssertNil(AgentLook.inUse(file.path, open: nil))
    }

    func testSuggestionsAreShortUntilOneGroupIsAskedFor() throws {
        let disk = disk()
        let tree = disk.tree
        var row = WinRow(id: "cache:x", title: "Xcode cache", subtitle: "Build output", detail: "Made again when needed.", tier: .rebuilds,
                         nodes: [disk.node("/Volumes/Fake/Work/Old"), disk.node("/Volumes/Fake/Work/report.pdf"), disk.node("/Volumes/Fake/Films/Big.mkv"), disk.node("/Volumes/Fake/Films/Small.mkv")],
                         bytes: 2_000_000_000, paperBytes: 2_000_000_000, action: .trash, command: nil, bundleID: nil)
        row.isQuick = true
        let all = Suggestions(sections: [Section(id: "caches", title: "Caches", detail: "Made again when needed.", color: Palette.Box.other, rows: [row])], others: [])
        let short = try AgentLook.suggestions(all, in: tree)
        let first = ((short["groups"] as? [[String: Any]])?.first?["suggestions"] as? [[String: Any]])?.first
        XCTAssertEqual(first?["id"] as? String, "cache:x", "the id it's selected by")
        XCTAssertEqual((first?["paths"] as? [String])?.count, 3, "a few paths")
        XCTAssertEqual(first?["more_paths"] as? Int, 1)
        XCTAssertNil(first?["about"])
        XCTAssertEqual(first?["recommended"] as? Bool, true)
        XCTAssertEqual(short["recommended_size"] as? UInt64, 2_000_000_000)

        let full = try AgentLook.suggestions(all, group: "caches", in: tree)
        let whole = (full["suggestions"] as? [[String: Any]])?.first
        XCTAssertEqual((whole?["paths"] as? [String])?.count, 4, "every path")
        XCTAssertEqual(whole?["about"] as? String, "Made again when needed.")
        XCTAssertThrowsError(try AgentLook.suggestions(all, group: "Nonsense", in: tree))
        XCTAssertNotNil(AgentJSON.text(short))
        XCTAssertNotNil(AgentJSON.text(AgentLook.duplicates(nil, reading: false, arguments: [:], in: tree)))
    }

    func testAFinishedCleanSaysWhatWentAndThatItCanStillBeUndone() {
        let thing = CleanedThing(itemID: "path:/Volumes/Fake/Work/Old", title: "Old", original: "/Volumes/Fake/Work/Old", inTrash: "/Volumes/Fake/.Trashes/501/Old", bytes: 2_000_000_000)
        var after = AfterClean(things: [thing], bytes: 2_000_000_000, includesOldTrash: false)
        after.failed = 1
        let said = AgentLook.cleaned(after, free: 60_000_000_000)
        XCTAssertEqual(said["finished"] as? Bool, true)
        XCTAssertEqual(said["moved_to_trash"] as? Int, 1)
        XCTAssertEqual(said["size"] as? UInt64, 2_000_000_000)
        XCTAssertNil(said["emptying_the_trash_frees"], "the same, so it isn't said twice")
        XCTAssertEqual(said["could_not_go"] as? Int, 1)
        var withOldTrash = after
        withOldTrash.bytes = 25_000_000_000
        XCTAssertEqual(AgentLook.cleaned(withOldTrash, free: nil)["size"] as? UInt64, 2_000_000_000, "what this clean moved")
        XCTAssertEqual(AgentLook.cleaned(withOldTrash, free: nil)["emptying_the_trash_frees"] as? UInt64, 25_000_000_000, "and what emptying the Trash gives, with what was in it before")
        XCTAssertTrue((said["state"] as? String ?? "").hasPrefix("In the Trash"), "nothing is gone for good until the Trash is emptied")
        XCTAssertEqual((said["items"] as? [[String: Any]])?.first?["was_at"] as? String, "/Volumes/Fake/Work/Old")
        after.state = .done(got: 2_000_000_000)
        XCTAssertTrue((AgentLook.cleaned(after, free: nil)["state"] as? String ?? "").contains("emptied"))
        XCTAssertNotNil(AgentJSON.text(said))
    }

    // MARK: Selecting

    private func select(_ paths: [String], in tree: DiskTree, plan: inout PlanList, reason: String = "Old installer") -> [String] {
        AgentPicks.select(paths, in: tree, plan: &plan, by: "Test Agent", reason: reason) { tree.name($0) }.map(\.outcome.text)
    }

    func testAnAgentSelectsWhatAClickCouldAndItCarriesItsNameAndReason() {
        let tree = disk().tree
        var plan = PlanList()
        XCTAssertEqual(select(["/Volumes/Fake/Work/Old/installer.dmg", "/Volumes/Fake/Films"], in: tree, plan: &plan), ["selected", "selected"])
        XCTAssertEqual(plan.items.map(\.paths), [["/Volumes/Fake/Work/Old/installer.dmg"], ["/Volumes/Fake/Films"]])
        XCTAssertEqual(plan.items.map(\.agent), ["Test Agent", "Test Agent"])
        XCTAssertEqual(plan.items.map(\.note), ["Old installer", "Old installer"], "its reason is what you read beside it")
        XCTAssertEqual(plan.items.map(\.title), ["installer.dmg", "Films"])
        XCTAssertTrue(plan.items.allSatisfy { $0.isPickedByHand && $0.step == .trash }, "one path each, to the Trash, like a click on the ring")
        XCTAssertEqual(plan.items[0].lastKnownBytes, 2_000_000_000)

        XCTAssertEqual(select(["/Volumes/Fake/Films/Big.mkv"], in: tree, plan: &plan), ["already selected"], "what's inside a selected folder is selected")
        XCTAssertEqual(plan.count, 2)
    }

    func testWhatHeadroomNeverRemovesAnAgentCantSelect() {
        let tree = disk().tree
        var plan = PlanList()
        let results = select(["/Volumes/Fake", "/Volumes/Fake/Nowhere", "node:\(tree.free)@\(tree.scanID.uuidString.prefix(8))", "/etc/passwd", NSHomeDirectory() + "/Documents"],
                             in: tree, plan: &plan)
        XCTAssertTrue(results[0].hasPrefix("not done: Protected"), "a whole disk")
        XCTAssertTrue(results[1].hasPrefix("not done: Not found"), "something that isn't there")
        XCTAssertTrue(results[2].hasPrefix("not done: It has no path"), "free space")
        XCTAssertTrue(results[3].hasPrefix("not done:"), "a file that's there, in a folder the map has never seen")
        XCTAssertTrue(results[4].hasPrefix("not done:"), "a folder that holds everything together")
        XCTAssertTrue(plan.isEmpty, "and nothing was selected along the way")
    }

    /// A real folder with real files in it, and a map of that folder that knows only some of them: what an agent meets
    /// when it has found something with its own tools since Headroom last read the disk.
    func testWhatAnAgentFoundOnTheDiskIsSelectedThoughTheMapIsBehind() throws {
        let root = NSHomeDirectory() + "/Library/Caches/HeadroomTests-\(UUID().uuidString.prefix(8))"
        let files = FileManager.default
        try files.createDirectory(atPath: root + "/known", withIntermediateDirectories: true)
        try files.createDirectory(atPath: root + "/unseen", withIntermediateDirectories: true)
        defer { try? files.removeItem(atPath: root) }
        try Data(count: 3 << 20).write(to: URL(fileURLWithPath: root + "/known/new.bin"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: root + "/known/tiny.txt"))
        try Data(count: 2 << 20).write(to: URL(fileURLWithPath: root + "/unseen/deep.bin"))
        try files.createSymbolicLink(atPath: root + "/via", withDestinationPath: root + "/known")
        let disk = FakeDisk(root: root)
        disk.file(root + "/known/old.bin", 5_000_000)
        disk.finish()
        let tree = disk.tree
        var plan = PlanList()

        let picks = AgentPicks.select([root + "/known/new.bin", root + "/known/tiny.txt", root + "/unseen/deep.bin", root + "/known/gone.bin", root + "/via/old.bin"],
                                      in: tree, plan: &plan, by: "Test Agent", reason: "Found with find") { tree.name($0) }
        XCTAssertEqual(picks[0].outcome, .selected, "it's on the disk, in a folder the map knows")
        XCTAssertTrue(picks[0].isNewerThanMap, "and the disk is read again so it shows")
        XCTAssertNil(picks[0].node)
        XCTAssertEqual(picks[1].outcome, .selected)
        XCTAssertFalse(picks[1].isNewerThanMap, "a file too small for the map never will be on it: no reading again for that")
        XCTAssertTrue(picks[1].note?.hasPrefix("Too small") ?? false)
        XCTAssertTrue(picks[2].outcome.text.hasPrefix("not done: Headroom's map doesn't have the folder"), "nothing is selected that couldn't be counted or shown")
        XCTAssertTrue(picks[2].isNewerThanMap)
        XCTAssertTrue(picks[3].outcome.text.hasPrefix("not done: Not found"))
        XCTAssertEqual(picks[4].outcome, .selected, "through a link, it's the file the map has")
        XCTAssertEqual(picks[4].node, disk.node(root + "/known/old.bin"))
        XCTAssertEqual(picks[4].path, root + "/known/old.bin")

        XCTAssertEqual(plan.items.map(\.paths), [[root + "/known/new.bin"], [root + "/known/tiny.txt"], [root + "/known/old.bin"]])
        XCTAssertEqual(plan.items[0].title, "new.bin")
        XCTAssertGreaterThanOrEqual(plan.items[0].lastKnownBytes, 3 << 20, "measured where it is")
        // The list counts them through the folder they're in, as it does a file too small for the map.
        var places = PlanPlaces()
        places.resolve(plan.items, in: tree)
        XCTAssertEqual(places.loose[plan.items[0].id], [root + "/known/new.bin"])
        XCTAssertEqual(places.nodes[plan.items[2].id], [disk.node(root + "/known/old.bin")])

        XCTAssertEqual(AgentLook.check(root + "/known/new.bin", in: tree, rules: rules, plan: plan)["on_the_map"] as? Bool, false)
        XCTAssertEqual(AgentLook.check(root + "/known/new.bin", in: tree, rules: rules, plan: plan)["selected_for_removal"] as? Bool, true)
        XCTAssertEqual(AgentPicks.deselect(paths: [root + "/known/new.bin"], ids: [], in: tree, plan: &plan).map(\.outcome), [.deselected], "and taken back the same way")
    }

    func testAnAgentTakesBackItsOwnAndLeavesYours() {
        let tree = disk().tree
        var plan = PlanList()
        plan.add(PlanItem(id: PlanItem.id(pickedByHand: "/Volumes/Fake/Work/report.pdf"), title: "report.pdf", note: "", tierRaw: Tier.yourCall.rawValue,
                          paths: ["/Volumes/Fake/Work/report.pdf"], byHand: true))
        _ = select(["/Volumes/Fake/Films"], in: tree, plan: &plan)
        func deselect(_ paths: [String], ids: [String] = []) -> [String] { AgentPicks.deselect(paths: paths, ids: ids, in: tree, plan: &plan).map(\.outcome.text) }

        XCTAssertTrue(deselect(["/Volumes/Fake/Work/report.pdf"])[0].hasPrefix("not done: The user selected this"))
        XCTAssertTrue(plan.covers("/Volumes/Fake/Work/report.pdf"))
        XCTAssertEqual(deselect(["/Volumes/Fake/Work/Old"]), ["not selected"])

        // One file out of a folder it selected: the rest of the folder stays.
        XCTAssertEqual(deselect(["/Volumes/Fake/Films/Small.mkv"]), ["deselected"])
        XCTAssertFalse(plan.covers("/Volumes/Fake/Films/Small.mkv"))
        XCTAssertTrue(plan.covers("/Volumes/Fake/Films/Big.mkv"))
        // And selecting it again brings it back, as a click would.
        XCTAssertEqual(select(["/Volumes/Fake/Films/Small.mkv"], in: tree, plan: &plan), ["selected"])
        XCTAssertTrue(plan.covers("/Volumes/Fake/Films/Small.mkv"))

        XCTAssertEqual(deselect(["/Volumes/Fake/Films"]), ["deselected"])
        XCTAssertEqual(plan.items.map(\.id), [PlanItem.id(pickedByHand: "/Volumes/Fake/Work/report.pdf")], "yours is all that's left")

        // A suggestion goes by its id: one an agent ticked comes out, one you ticked stays.
        plan.add(PlanItem(id: "cache:theirs", title: "Cache", note: "", tierRaw: Tier.rebuilds.rawValue, paths: ["/Volumes/Fake/Work/Old"], agent: "Test Agent"))
        plan.add(PlanItem(id: "cache:yours", title: "Cache", note: "", tierRaw: Tier.rebuilds.rawValue, paths: ["/Volumes/Fake/Films"]))
        XCTAssertEqual(deselect([], ids: ["cache:theirs", "cache:nothing"]), ["deselected", "not selected"])
        XCTAssertTrue(deselect([], ids: ["cache:yours"])[0].hasPrefix("not done: The user selected this"))
        XCTAssertNil(plan.item("cache:theirs"))
        XCTAssertNotNil(plan.item("cache:yours"))
    }

    func testAnAgentsReasonIsOneShortLine() {
        XCTAssertEqual(AgentPicks.oneLine("  Old\ninstaller,\r\nnot opened  ", most: 140), "Old installer, not opened")
        let long = AgentPicks.oneLine(String(repeating: "x", count: 500), most: 140)
        XCTAssertEqual(long.count, 140)
        XCTAssertTrue(long.hasSuffix("…"))
        let tree = disk().tree
        var plan = PlanList()
        _ = select(["/Volumes/Fake/Films"], in: tree, plan: &plan, reason: "   ")
        XCTAssertEqual(plan.items[0].note, "/Volumes/Fake/Films", "with no reason, where it is")
    }

    func testThePlanSaysWhoSelectedWhat() {
        let tree = disk().tree
        var plan = PlanList()
        plan.add(PlanItem(id: "path:/Volumes/Fake/Work/report.pdf", title: "report.pdf", note: "", tierRaw: Tier.yourCall.rawValue, paths: ["/Volumes/Fake/Work/report.pdf"], byHand: true))
        _ = select(["/Volumes/Fake/Films"], in: tree, plan: &plan)
        let items = AgentLook.plan(plan, numbers: PlanNumbers(), checks: [:], isChecking: false, isCleaning: false)["items"] as? [[String: Any]]
        XCTAssertEqual(items?.compactMap { $0["selected_by"] as? String }, ["the user", "Test Agent"])
        // And it's still there the next time the app opens.
        let saved = try? JSONDecoder().decode(PlanList.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(saved?.items.map(\.agent), [nil, "Test Agent"])
    }

    // MARK: Headroom's views

    func testConnectedNamesReadAsOneLine() {
        XCTAssertEqual(AgentsConnected.names([]), "")
        XCTAssertEqual(AgentsConnected.names(["Claude", "Claude"]), "Claude")
        XCTAssertEqual(AgentsConnected.names(["Claude", "Codex"]), "Claude and Codex")
        XCTAssertEqual(AgentsConnected.names(["Claude", "Codex", "Gemini"]), "Claude and 2 more")
    }
}
