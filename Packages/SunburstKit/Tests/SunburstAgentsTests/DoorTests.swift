import Darwin
import XCTest
@testable @_spi(Diagnostics) import SunburstAgents

/// The door as an app opens it: an agent connects, the user is asked, and each call is answered as far as the user allowed.
@MainActor
final class DoorTests: XCTestCase {
    private func call(_ session: AgentSession, _ id: Int, _ tool: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any]? {
        Lines.object(await session.handle(Lines.message(id, "tools/call", ["name": tool, "arguments": arguments])))
    }

    private func hello(_ session: AgentSession, _ name: String) async {
        _ = await session.handle(Lines.message(0, "initialize", ["clientInfo": ["name": name]]))
    }

    /// Over the socket, from hello to answer: the agent is asked about, waits for the user, and is answered as allowed.
    func testAnAgentAtTheDoorIsAnsweredOnlyAsTheUserAllowed() async throws {
        let folder = TestPlace.folder()
        defer { TestPlace.remove(folder) }
        let door = AgentDoor(TestPlace.host(folder)) { call in .json(["answered": call.tool]) }
        door.relayProgram = nil
        XCTAssertFalse(door.isOpen)
        XCTAssertTrue(door.open(), "the folder is made, and the door opens in it")
        defer { door.close() }
        XCTAssertTrue(door.isOpen)
        XCTAssertFalse(AgentDoor(TestPlace.host(folder)) { _ in .text("") }.open(), "a second copy of the app leaves the door to the first")

        let fd = try XCTUnwrap(AgentSocket.connect(to: door.host.socketPath))
        defer { close(fd) }
        let first = Task.detached { () -> String in
            Lines.write(fd, Lines.message(1, "initialize", ["clientInfo": ["name": "test-agent"]]), Lines.message(2, "tools/call", ["name": "look"]))
            return Lines.read(fd) + "\n" + Lines.read(fd)
        }
        for _ in 0..<150 where door.agents.requests.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let request = try XCTUnwrap(door.agents.requests.first, "the user is asked")
        XCTAssertEqual(request.identity.name, "test-agent")
        let own = try XCTUnwrap(AgentPeer.path(of: getpid()))
        XCTAssertEqual(request.identity.program, AgentPeer.program(ofPath: own), "the program is the one the system says connected")
        XCTAssertEqual(door.agents.connected.map(\.identity.name), ["test-agent"])
        door.agents.answer(request, .lookOnly)

        let answers = await first.value.split(separator: "\n").compactMap { Lines.object(Data($0.utf8)) }
        XCTAssertEqual(answers.first?["id"] as? Int, 1)
        XCTAssertEqual(Lines.text(of: answers.last), #"{"answered":"look"}"#, "the call waited for the user, then was answered")
        XCTAssertEqual(door.agents.activity.last?.what, "look")

        let second = Task.detached { () -> String in
            Lines.write(fd, Lines.message(3, "tools/call", ["name": "show", "arguments": ["path": "/x"]]))
            return Lines.read(fd)
        }
        let refused = Lines.object(Data(await second.value.utf8))
        XCTAssertEqual(Lines.isError(refused), true)
        XCTAssertEqual(Lines.text(of: refused), "The user allowed this agent to look only. They can change that in TestApp, under Agents in Settings.")

        close(fd)
        for _ in 0..<150 where !door.agents.connected.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(door.agents.connected.isEmpty, "an agent that hangs up is gone from the list")
        XCTAssertTrue(FileManager.default.fileExists(atPath: door.host.allowListFile.path), "and what the user allowed is written down")
        door.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: door.host.socketPath), "a closed door leaves no socket behind")
    }

    func testEachAnswerTheUserCanGiveIsWhatTheAgentIsTold() async throws {
        let folder = TestPlace.folder()
        defer { TestPlace.remove(folder) }
        let door = AgentDoor(TestPlace.host(folder)) { call in
            switch call.tool {
            case "look": return .json(["by": call.agent.name])
            default: throw AgentFailure("Nothing to show.")
            }
        }
        door.patience = .milliseconds(50)
        let agent = door.session(program: "/Applications/Test.app", signer: nil)
        await hello(agent, "Test Agent")

        let waiting = try await call(agent, 1, "look")
        XCTAssertEqual(Lines.text(of: waiting), "Waiting for the user to allow this agent. TestApp is asking in its window: ask the user to answer there, then try again.")
        XCTAssertEqual(Lines.isError(waiting), true)

        door.agents.answer(try XCTUnwrap(door.agents.requests.first), .allow)
        let looked = try await call(agent, 2, "look")
        XCTAssertEqual(Lines.text(of: looked), #"{"by":"Test Agent"}"#, "the app is told who called")
        let failed = try await call(agent, 3, "show")
        XCTAssertEqual(Lines.text(of: failed), "Nothing to show.", "an app's own failure is the agent's answer")
        XCTAssertEqual(Lines.isError(failed), true)
        XCTAssertEqual(door.agents.activity.last?.what, "look", "only what was answered is in the list of what agents did")

        let stranger = door.session(program: "/opt/stranger", signer: nil)
        await hello(stranger, "Stranger")
        door.agents.answer(try XCTUnwrap(door.agents.requests.first { $0.identity.name == "Stranger" }), .deny)
        let denied = try await call(stranger, 4, "look")
        XCTAssertEqual(Lines.text(of: denied), "The user didn't allow this agent to use TestApp.")
    }

    func testAnAppThatCantAnswerSaysSo() async throws {
        struct Broken: Error {}
        let folder = TestPlace.folder()
        defer { TestPlace.remove(folder) }
        let door = AgentDoor(TestPlace.host(folder)) { _ in throw Broken() }
        let agent = door.session(program: "/Applications/Test.app", signer: nil)
        await hello(agent, "Test Agent")
        door.agents.answer(try XCTUnwrap(door.agents.requests.first), .allow)
        let broken = try await call(agent, 1, "look")
        XCTAssertEqual(Lines.text(of: broken), "TestApp couldn't answer that.")
    }

    /// One that calls without saying hello is known by its program, and asked about like any other.
    func testAnAgentThatNeverSaidHelloIsKnownByItsProgram() async throws {
        let door = AgentDoor(TestPlace.host()) { _ in .text("ok") }
        door.patience = .milliseconds(30)
        let agent = door.session(program: "/opt/homebrew/bin/codex", signer: nil)
        _ = try await call(agent, 1, "look")
        XCTAssertEqual(door.agents.requests.map(\.identity.name), ["codex"])
        let long = door.session(program: "/Applications/Test.app", signer: nil)
        await hello(long, String(repeating: "x", count: 300))
        XCTAssertEqual(door.agents.requests.last?.identity.name.count, 80, "a name is the agent's own word, so it's kept short")
    }

    func testAToolsCallIsDescribedByWhatItWasGiven() {
        let agent = AgentIdentity(name: "a", program: "/p", signer: nil)
        XCTAssertEqual(AgentDoor.describe(AgentCall(tool: "chart_summary", agent: agent)), "chart_summary")
        XCTAssertEqual(AgentDoor.describe(AgentCall(tool: "zoom", arguments: ["node": 12, "why": "big"], agent: agent)), "zoom: node 12, why big")
        XCTAssertEqual(AgentDoor.describe(AgentCall(tool: "light", arguments: ["nodes": [3, 4, 5]], agent: agent)), "light: 3 nodes, first 3")
        XCTAssertEqual(AgentDoor.describe(AgentCall(tool: "light", arguments: ["nodes": [3], "more": ["x": 1]], agent: agent)), "light: 3")
        let parsed = try! JSONSerialization.jsonObject(with: Data(#"{"to_root":true,"node":1}"#.utf8)) as! [String: Any]
        XCTAssertEqual(AgentDoor.describe(AgentCall(tool: "chart_zoom_out", arguments: parsed, agent: agent)), "chart_zoom_out: node 1, to_root true")
    }

    /// The door takes nothing off the disk: the one file its code removes is the socket it made, and only when it is a
    /// socket. What the app's tools do is the app's.
    func testTheDoorsCodeRemovesNothingButItsSocket() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SunburstAgents")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        XCTAssertGreaterThanOrEqual(files.count, 8)
        let removes = ["unlink(", "Darwin.remove(", "removefile(", "rmdir(", "removeItem(", "trashItem(", "moveItem(", "replaceItem", "rename(", "performClick"]
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8)
            for call in removes {
                let allowed = file.lastPathComponent == "AgentSocket.swift" && call == "unlink(" ? 1 : 0
                XCTAssertEqual(code.components(separatedBy: call).count - 1, allowed, "\(file.lastPathComponent) calls \(call)")
            }
        }
        let socket = try String(contentsOf: sources.appendingPathComponent("AgentSocket.swift"), encoding: .utf8)
        XCTAssertTrue(socket.contains("S_IFSOCK"), "and that one removes only a socket")
    }
}
