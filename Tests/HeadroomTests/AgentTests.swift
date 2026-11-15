import Darwin
import XCTest
@testable import Headroom

/// The agents' way in: the protocol, what they can read, your answer to one that asks, and the socket itself.
@MainActor
final class AgentTests: XCTestCase {
    // MARK: The protocol

    private func session() -> AgentSession { AgentSession(tools: AgentLook.tools, version: "1.2.3") }

    private func ask(_ session: AgentSession, _ message: [String: Any]) async throws -> [String: Any]? {
        let line = try JSONSerialization.data(withJSONObject: message)
        guard let reply = await session.handle(line) else { return nil }
        XCTAssertFalse(reply.contains(0x0A), "an answer is one line")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    func testAnAgentIsGreetedAndSaysWhoItIs() async throws {
        let session = session()
        var said: String?
        session.onHello = { name, _ in said = name }
        let reply = try await ask(session, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                            "params": ["protocolVersion": "2025-03-26", "clientInfo": ["name": "test-agent", "version": "9"], "capabilities": [:]]])
        let result = try XCTUnwrap(reply?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26", "it speaks the version the agent asked for, when it knows it")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "Headroom")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["version"] as? String, "1.2.3")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"], "it offers tools")
        XCTAssertEqual(said, "test-agent")
        XCTAssertEqual(reply?["id"] as? Int, 1)

        let newer = try await ask(session, ["jsonrpc": "2.0", "id": "a", "method": "initialize", "params": ["protocolVersion": "2099-01-01"]])
        XCTAssertEqual((newer?["result"] as? [String: Any])?["protocolVersion"] as? String, AgentSession.versions[0], "and its own newest otherwise")
        XCTAssertEqual(newer?["id"] as? String, "a", "an id comes back as it was sent")
    }

    func testWhatIsntARequestGetsTheRightAnswerOrNone() async throws {
        let session = session()
        let none = try await ask(session, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertNil(none, "something told, not asked, gets no answer")
        let unknown = try await ask(session, ["jsonrpc": "2.0", "id": 2, "method": "resources/list"])
        XCTAssertEqual((unknown?["error"] as? [String: Any])?["code"] as? Int, -32601)
        let noTool = try await ask(session, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "delete_everything"]])
        XCTAssertEqual((noTool?["error"] as? [String: Any])?["code"] as? Int, -32602)
        let ping = try await ask(session, ["jsonrpc": "2.0", "id": 4, "method": "ping"])
        XCTAssertNotNil(ping?["result"])

        let broken = await session.handle(Data("{not json".utf8))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(broken)) as? [String: Any])
        XCTAssertEqual((parsed["error"] as? [String: Any])?["code"] as? Int, -32700)
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
    /// Nothing an agent can reach calls anything that removes, empties, undoes or presses Clean, here or in the app.
    func testNothingAnAgentCanReachCanRemoveAnything() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Headroom")
        let agents = try FileManager.default.contentsOfDirectory(at: sources.appendingPathComponent("Agents"), includingPropertiesForKeys: nil)
            + [sources.appendingPathComponent("Model/AppModel+Agents.swift"), sources.appendingPathComponent("UI/AgentsView.swift")]
        XCTAssertGreaterThanOrEqual(agents.count, 8, "all of the agents' code is read")
        // Every way the app has of taking something off the disk, out of the Trash, or back again.
        let removes = ["cleanNow(", "emptyNow(", "sendToTrash(", "sendAnyway(", "undoClean(", "undoCommand(", "putBack(", "takeCopies(", "leaveInTrash(",
                       "deleteForGood(", "deleteFromTrash(", "replaceCopy(", "copyAndVerify(", "Cleaner.trash(", "Cleaner.run", "trashContents(",
                       "removeItem(", "trashItem(", "moveItem(", "performClick", "cleanAnyway",
                       // Backup's: moving, copying, bringing back and deleting from a drive are the user's clicks too.
                       "runBackup(", "bringBack(", "deleteLastCopy(", "copyToMac(", "deleteFromDrive(", "DriveMover.send(", "DriveMover.copy(",
                       "unlink(", "rename("]
        for file in agents {
            let code = try String(contentsOf: file, encoding: .utf8)
            // The socket's own file is the one thing its code may take away, and only when it is a socket.
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
    }

    func testAToolsAnswerAndAToolsFailureAreBothAnswers() async throws {
        let session = session()
        session.call = { tool, arguments in
            arguments["path"] as? String == "/missing" ? .failure(AgentFailure("Not on the map.")) : .success(["tool": tool, "size": UInt64(5_000_000_000)])
        }
        let good = try await ask(session, ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "show", "arguments": ["path": "/there"]]])
        let result = try XCTUnwrap(good?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        let answer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(answer["size"] as? Int, 5_000_000_000, "sizes past four billion come through whole")

        XCTAssertFalse(text.contains("\n"), "with no layout: an agent pays for every space")
        let bad = try await ask(session, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "show", "arguments": ["path": "/missing"]]])
        let failed = try XCTUnwrap(bad?["result"] as? [String: Any])
        XCTAssertEqual(failed["isError"] as? Bool, true)
        XCTAssertEqual((failed["content"] as? [[String: Any]])?.first?["text"] as? String, "Not on the map.")
    }

    func testWhatFollowsTheHelloFindsTheAgentKnown() async throws {
        let session = session()
        var said: String?
        var seenByCall: String?
        session.onHello = { name, _ in said = name }
        session.call = { _, _ in
            seenByCall = said
            return .success([:])
        }
        let answers = expectation(description: "both answered")
        answers.expectedFulfillmentCount = 2
        // One straight after the other, as they arrive when the helper passes on a hello and a call together.
        session.take(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "hello", "method": "initialize", "params": ["clientInfo": ["name": "test-agent"]]])) { _ in answers.fulfill() }
        XCTAssertEqual(said, "test-agent", "the hello is dealt with before anything else is looked at")
        session.take(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "overview"]])) { _ in answers.fulfill() }
        await fulfillment(of: [answers], timeout: 2)
        XCTAssertEqual(seenByCall, "test-agent")
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

    // MARK: Your answer

    private let claude = AgentIdentity(name: "Test Agent", program: "/Applications/Test.app", signer: "Developer ID Application: Test (ABCDE12345)")

    func testNothingIsAnsweredUntilYouAllow() async {
        let agents = Agents(file: nil)
        let id = UUID()
        agents.arrived(id, claude)
        XCTAssertEqual(agents.requests.map(\.identity), [claude], "a new agent is put to you")
        XCTAssertEqual(agents.standing(of: claude), .asking)
        agents.arrived(UUID(), claude)
        XCTAssertEqual(agents.requests.count, 1, "once, however many times it connects")

        async let waiting = agents.mayAnswer(claude)
        await Task.yield()
        agents.answer(agents.requests[0], .allow)
        let allowed = await waiting
        XCTAssertEqual(allowed, true)
        XCTAssertTrue(agents.requests.isEmpty)
        let again = await agents.mayAnswer(claude)
        XCTAssertEqual(again, true, "and it isn't asked about again")
    }

    func testAnAgentYouTurnDownGetsNothingAndIsntAskedAboutAgain() async {
        let agents = Agents(file: nil)
        agents.arrived(UUID(), claude)
        agents.answer(agents.requests[0], .deny)
        let answer = await agents.mayAnswer(claude)
        XCTAssertEqual(answer, false)
        agents.arrived(UUID(), claude)
        XCTAssertTrue(agents.requests.isEmpty)
        XCTAssertTrue(agents.allowed.isEmpty)
    }

    func testTheSameNameFromAnotherProgramIsAnotherAgent() async {
        let agents = Agents(file: nil)
        agents.arrived(UUID(), claude)
        agents.answer(agents.requests[0], .allow)
        var other = claude
        other.program = "/tmp/pretender"
        other.signer = nil
        XCTAssertEqual(agents.standing(of: other), .asking, "a name is only the agent's word for itself")
        agents.arrived(UUID(), other)
        XCTAssertEqual(agents.requests.map(\.identity), [other])
    }

    func testNoAnswerInTimeIsNoAnswerNotANo() async {
        let agents = Agents(file: nil)
        agents.arrived(UUID(), claude)
        let answer = await agents.mayAnswer(claude, patience: .milliseconds(50))
        XCTAssertNil(answer)
        XCTAssertEqual(agents.requests.count, 1, "the question is still there for you")
    }

    func testAnAgentThatLeavesTakesItsQuestionWithIt() async {
        let agents = Agents(file: nil)
        let id = UUID()
        agents.arrived(id, claude)
        async let waiting = agents.mayAnswer(claude)
        await Task.yield()
        agents.left(id)
        let answer = await waiting
        XCTAssertNil(answer)
        XCTAssertTrue(agents.requests.isEmpty)
        XCTAssertTrue(agents.connected.isEmpty)
    }

    func testWhatYouAllowedIsRememberedUntilYouRemoveIt() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let agents = Agents(file: file)
        agents.arrived(UUID(), claude)
        agents.answer(agents.requests[0], .allow)
        agents.used(claude, "overview")
        Saves.queue.sync {}
        let next = Agents(file: file)
        XCTAssertEqual(next.allowed.map(\.identity), [claude], "the next time the app opens, it's still allowed")
        XCTAssertNotNil(next.allowed.first?.lastUsed)

        next.remove(next.allowed[0])
        XCTAssertEqual(next.standing(of: claude), .asking)
        async let waiting = next.mayAnswer(claude, patience: .milliseconds(50))
        await Task.yield()
        XCTAssertEqual(next.requests.map(\.identity), [claude], "removed, it has to ask again")
        _ = await waiting
        Saves.queue.sync {}
        XCTAssertTrue(Agents(file: file).allowed.isEmpty)
    }

    func testAnAgentAllowedToLookOnlyCantSelectUntilYouSaySo() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let agents = Agents(file: file)
        agents.arrived(UUID(), claude)
        agents.answer(agents.requests[0], .lookOnly)
        let mayLook = await agents.mayAnswer(claude)
        XCTAssertEqual(mayLook, true)
        XCTAssertFalse(agents.maySelect(claude))
        agents.setMaySelect(agents.allowed[0], true)
        XCTAssertTrue(agents.maySelect(claude))
        Saves.queue.sync {}
        XCTAssertEqual(Agents(file: file).allowed.map(\.maySelect), [true])

        var stranger = claude
        stranger.name = "Someone else"
        XCTAssertFalse(agents.maySelect(stranger), "one you never answered about can do neither")

        // One allowed before agents could select: it was allowed to look, and that's what it keeps.
        let old = #"[{"identity":{"name":"Old","program":"/Applications/Old.app"},"allowed":0}]"#
        try Data(old.utf8).write(to: file)
        let before = Agents(file: file)
        XCTAssertEqual(before.allowed.map(\.identity.name), ["Old"])
        XCTAssertEqual(before.allowed.map(\.maySelect), [false])
    }

    func testConnectedNamesReadAsOneLine() {
        XCTAssertEqual(AgentsConnected.names([]), "")
        XCTAssertEqual(AgentsConnected.names(["Claude", "Claude"]), "Claude")
        XCTAssertEqual(AgentsConnected.names(["Claude", "Codex"]), "Claude and Codex")
        XCTAssertEqual(AgentsConnected.names(["Claude", "Codex", "Gemini"]), "Claude and 2 more")
    }

    // MARK: The socket

    private func socketPath() -> String { "/tmp/hr-\(UUID().uuidString.prefix(8)).sock" }

    nonisolated private static func readLine(_ fd: Int32) -> String {
        var out = [UInt8]()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1, byte != 0x0A { out.append(byte) }
        return String(decoding: out, as: UTF8.self)
    }

    func testOnlyYouCanOpenTheSocketAndLinesGoBothWays() async throws {
        let path = socketPath()
        let listener = AgentListener(path: path)
        defer { listener.stop() }
        XCTAssertTrue(listener.start { connection in
            Thread.detachNewThread {
                connection.read { line in connection.send(Data("got ".utf8) + line) }
            }
        })
        var info = stat()
        XCTAssertEqual(stat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600, "nobody else on this Mac can connect")
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFSOCK)

        let fd = try XCTUnwrap(AgentSocket.connect(to: path))
        defer { close(fd) }
        XCTAssertEqual(AgentPeer.pid(ofSocket: fd), getpid(), "the system says who is on the other end")
        // Two lines in one write, and one line in two.
        let replies = await Task.detached { () -> [String] in
            _ = "one\ntwo\nthr".withCString { write(fd, $0, 11) }
            usleep(50_000)
            _ = "ee\n".withCString { write(fd, $0, 3) }
            return [Self.readLine(fd), Self.readLine(fd), Self.readLine(fd)]
        }.value
        XCTAssertEqual(replies, ["got one", "got two", "got three"])
    }

    func testARunningCopyKeepsItsSocketAndALeftoverFileIsReplaced() throws {
        let path = socketPath()
        let first = AgentListener(path: path)
        XCTAssertTrue(first.start { _ in })
        XCTAssertFalse(AgentListener(path: path).start { _ in }, "a second copy doesn't take the socket from the first")
        first.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))

        // What a copy that was killed leaves behind: a socket file nobody listens on.
        let dead = try XCTUnwrap(AgentSocket.listen(at: path))
        close(dead)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let next = AgentListener(path: path)
        XCTAssertTrue(next.start { _ in })
        next.stop()
        XCTAssertNil(AgentSocket.connect(to: path))
    }

    // MARK: The helper an agent starts

    /// What the helper wrote back to the agent, collected as it comes.
    private final class Written: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [[String: Any]] = []
        func add(_ data: Data) {
            guard let one = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            lock.withLock { lines.append(one) }
        }
        var all: [[String: Any]] { lock.withLock { lines } }
        /// The answer with this id, waited for a moment.
        func answer(_ id: Int) -> [String: Any]? {
            for _ in 0..<150 {
                if let found = all.first(where: { $0["id"] as? Int == id }) { return found }
                usleep(20_000)
            }
            return nil
        }
    }

    private static func line(_ id: Int?, _ method: String, _ params: [String: Any] = [:]) -> Data {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { message["id"] = id }
        return try! JSONSerialization.data(withJSONObject: message)
    }

    private static func text(of answer: [String: Any]?) -> String? {
        (((answer?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first)?["text"] as? String
    }

    func testTheHelperStaysQuietUntilAToolIsCalled() {
        let written = Written()
        let opened = LockedFlag()
        let relay = AgentRelay(path: socketPath(), open: { opened.value = true }, patience: 0.3, version: "1.2.3") { written.add($0) }
        // Claude Code asks this before it has said hello, to see what kind of server it has. It's no reason to open the app.
        relay.take(Self.line(90, "server/discover", ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]))
        XCTAssertEqual((written.answer(90)?["error"] as? [String: Any])?["code"] as? Int, -32601, "it's told Headroom doesn't know that")
        relay.take(Self.line(1, "initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test-agent"]]))
        relay.take(Self.line(nil, "notifications/initialized"))
        relay.take(Self.line(2, "tools/list"))
        relay.take(Self.line(3, "ping"))
        XCTAssertEqual(((written.answer(1)?["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String, "Headroom")
        XCTAssertEqual(((written.answer(2)?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.count, AgentLook.tools.count)
        XCTAssertNotNil(written.answer(3)?["result"])
        XCTAssertFalse(opened.value, "an agent that only says hello and looks at the list doesn't open Headroom")

        relay.take(Self.line(4, "tools/call", ["name": "overview"]))
        XCTAssertTrue(opened.value, "a tool call does")
        let refused = written.answer(4)?["result"] as? [String: Any]
        XCTAssertEqual(refused?["isError"] as? Bool, true, "and when Headroom can't be reached, the call is told so")
        XCTAssertTrue(Self.text(of: written.answer(4))?.contains("isn't running") ?? false)
    }

    /// Stands in for the app: says what it was sent, answers every call, and can hang up on one.
    private final class FakeApp: @unchecked Sendable {
        let listener: AgentListener
        private let lock = NSLock()
        private var seen: [[String: Any]] = []
        var received: [[String: Any]] { lock.withLock { seen } }

        init(path: String, hangUpOn silent: Int? = nil) {
            listener = AgentListener(path: path)
            _ = listener.start { [self] connection in
                Thread.detachNewThread { [self] in
                    connection.read { line in
                        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = message["id"] else { return }
                        lock.withLock { seen.append(message) }
                        if let silent, id as? Int == silent { connection.hangUp(); return }
                        let text = id as? String == AgentRelay.helloID ? "hello back" : "from the app"
                        if let reply = AgentSession.said(id: id, text, isError: false) { connection.send(reply) }
                    }
                }
            }
        }
    }

    func testTheHelperTellsTheAppWhoTheAgentIsAndCarriesItsAnswers() {
        let path = socketPath()
        let app = FakeApp(path: path)
        defer { app.listener.stop() }
        let written = Written()
        let relay = AgentRelay(path: path, open: nil, version: "1.2.3") { written.add($0) }
        // As Claude Code does it: a question before the hello, then the hello, then what it was told, then the list.
        relay.take(Self.line(90, "server/discover"))
        relay.take(Self.line(1, "initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test-agent"]]))
        relay.take(Self.line(nil, "notifications/initialized"))
        relay.take(Self.line(2, "tools/list"))
        _ = written.answer(2)
        XCTAssertTrue(app.received.isEmpty, "the app hears nothing of an agent that hasn't called anything")

        relay.take(Self.line(7, "tools/call", ["name": "overview"]))
        XCTAssertEqual(Self.text(of: written.answer(7)), "from the app")
        let first = app.received.first
        XCTAssertEqual(first?["method"] as? String, "initialize", "the app is told who the agent is before anything else")
        XCTAssertEqual(((first?["params"] as? [String: Any])?["clientInfo"] as? [String: Any])?["name"] as? String, "test-agent")
        XCTAssertFalse(written.all.contains { $0["id"] as? String == AgentRelay.helloID }, "and the app's answer to that isn't passed on: the agent was already greeted")
        relay.take(Self.line(8, "tools/call", ["name": "get_plan"]))
        XCTAssertEqual(Self.text(of: written.answer(8)), "from the app")
        XCTAssertEqual(app.received.filter { $0["method"] as? String == "initialize" }.count, 1, "once for the connection")
    }

    func testTheHelperSurvivesTheAppBeingReplaced() {
        let path = socketPath()
        let written = Written()
        let relay = AgentRelay(path: path, open: nil, version: "1.2.3") { written.add($0) }
        relay.take(Self.line(1, "initialize", ["clientInfo": ["name": "test-agent"]]))

        // The app goes away with a call unanswered, as it does when a new build takes its place.
        let old = FakeApp(path: path, hangUpOn: 5)
        relay.take(Self.line(5, "tools/call", ["name": "overview"]))
        XCTAssertEqual((written.answer(5)?["result"] as? [String: Any])?["isError"] as? Bool, true, "the call still gets an answer")
        XCTAssertTrue(Self.text(of: written.answer(5))?.contains("quit before it answered") ?? false)
        old.listener.stop()

        let new = FakeApp(path: path)
        defer { new.listener.stop() }
        relay.take(Self.line(6, "tools/call", ["name": "overview"]))
        XCTAssertEqual(Self.text(of: written.answer(6)), "from the app", "the next call reaches the new one")
        XCTAssertEqual(new.received.first?["method"] as? String, "initialize", "which is told who the agent is, like the first")
    }

    // MARK: Who is on the other end

    func testTheProgramBehindAConnectionIsReadFromTheSystem() throws {
        let own = try XCTUnwrap(AgentPeer.path(of: getpid()))
        XCTAssertTrue(own.hasPrefix("/"))
        let parent = try XCTUnwrap(AgentPeer.parent(of: getpid()))
        XCTAssertEqual(parent, getppid())

        XCTAssertEqual(AgentPeer.program(ofPath: "/Applications/Claude.app/Contents/Helpers/disclaimer"), "/Applications/Claude.app")
        XCTAssertEqual(AgentPeer.program(ofPath: "/opt/homebrew/bin/codex"), "/opt/homebrew/bin/codex")

        // Anything that connects by itself is the agent. Headroom's own helper only relays, so the agent is what started it.
        XCTAssertEqual(AgentPeer.program(behind: getpid(), helper: nil)?.pid, getpid())
        XCTAssertEqual(AgentPeer.program(behind: getpid(), helper: "/somewhere/else")?.pid, getpid())
        let behind = try XCTUnwrap(AgentPeer.program(behind: getpid(), helper: own))
        XCTAssertNotEqual(behind.pid, getpid())
        XCTAssertNotEqual(behind.path, own)

        // A program of Apple's own, started here: its signature is read from the running process, and names its signer.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["20"]
        try sleeper.run()
        defer { sleeper.terminate() }
        XCTAssertEqual(AgentPeer.path(of: sleeper.processIdentifier), "/bin/sleep")
        XCTAssertTrue(AgentPeer.signer(of: sleeper.processIdentifier)?.hasSuffix("Software Signing") ?? false, "Apple signs it")

        XCTAssertEqual(AgentIdentity(name: "x", program: "/Applications/Claude.app", signer: nil).programName, "Claude")
        XCTAssertEqual(AgentIdentity(name: "x", program: "/opt/homebrew/bin/codex", signer: nil).programName, "codex")
    }
}
