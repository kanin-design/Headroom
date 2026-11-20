import Darwin
import XCTest
@testable @_spi(Diagnostics) import SunburstAgents

/// The relay an agent starts: the app's own program with `--mcp`.
final class RelayTests: XCTestCase {
    private func relay(_ path: String, open: (@Sendable () -> Void)? = nil, patience: Double = AgentRelay.patience, _ written: Written) -> AgentRelay {
        AgentRelay(host: TestPlace.host(), path: path, open: open, patience: patience) { written.add($0) }
    }

    func testTheRelayStaysQuietUntilAToolIsCalled() {
        let written = Written()
        let opened = Flag()
        let relay = relay(TestPlace.socketPath(), open: { opened.value = true }, patience: 0.3, written)
        // Claude Code asks this before it has said hello, to see what kind of server it has. It's no reason to open the app.
        relay.take(Lines.message(90, "server/discover", ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]))
        XCTAssertEqual((written.answer(90)?["error"] as? [String: Any])?["code"] as? Int, -32601, "it's told the app doesn't know that")
        XCTAssertEqual((written.answer(90)?["error"] as? [String: Any])?["message"] as? String, "TestApp doesn't know server/discover.")
        relay.take(Lines.message(1, "initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test-agent"]]))
        relay.take(Lines.message(nil, "notifications/initialized"))
        relay.take(Lines.message(2, "tools/list"))
        relay.take(Lines.message(3, "ping"))
        let greeting = written.answer(1)?["result"] as? [String: Any]
        XCTAssertEqual((greeting?["serverInfo"] as? [String: Any])?["name"] as? String, "TestApp")
        XCTAssertEqual((greeting?["serverInfo"] as? [String: Any])?["version"] as? String, "1.2.3")
        XCTAssertEqual(greeting?["instructions"] as? String, "TestApp is for tests.")
        XCTAssertEqual(((written.answer(2)?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String },
                       TestPlace.tools.map(\.name), "the app's tools, listed without the app")
        XCTAssertNotNil(written.answer(3)?["result"])
        XCTAssertFalse(opened.value, "an agent that only says hello and looks at the list doesn't open the app")

        relay.take(Lines.message(4, "tools/call", ["name": "look"]))
        XCTAssertTrue(opened.value, "a tool call does")
        XCTAssertEqual(Lines.isError(written.answer(4)), true, "and when the app can't be reached, the call is told so")
        XCTAssertEqual(Lines.text(of: written.answer(4)), "TestApp isn't running and couldn't be opened.")

        relay.take(Data("{nonsense".utf8))
        XCTAssertTrue(written.all.contains { ($0["error"] as? [String: Any])?["code"] as? Int == -32700 }, "what isn't JSON is said to be so")
    }

    func testTheRelayTellsTheAppWhoTheAgentIsAndCarriesItsAnswers() {
        let path = TestPlace.socketPath()
        let written = Written()
        let relay = relay(path, written)
        let app = FakeApp(path: path, helloID: relay.helloID)
        defer { app.listener.stop() }
        XCTAssertEqual(relay.helloID, "testapp-relay-hello")
        // As Claude Code does it: a question before the hello, then the hello, then what it was told, then the list.
        relay.take(Lines.message(90, "server/discover"))
        relay.take(Lines.message(1, "initialize", ["protocolVersion": "2025-06-18", "clientInfo": ["name": "test-agent"]]))
        relay.take(Lines.message(nil, "notifications/initialized"))
        relay.take(Lines.message(2, "tools/list"))
        _ = written.answer(2)
        XCTAssertTrue(app.received.isEmpty, "the app hears nothing of an agent that hasn't called anything")

        relay.take(Lines.message(7, "tools/call", ["name": "look"]))
        XCTAssertEqual(Lines.text(of: written.answer(7)), "from the app")
        let first = app.received.first
        XCTAssertEqual(first?["method"] as? String, "initialize", "the app is told who the agent is before anything else")
        XCTAssertEqual(((first?["params"] as? [String: Any])?["clientInfo"] as? [String: Any])?["name"] as? String, "test-agent")
        XCTAssertFalse(written.all.contains { $0["id"] as? String == relay.helloID }, "and the app's answer to that isn't passed on: the agent was already greeted")
        relay.take(Lines.message(8, "tools/call", ["name": "show"]))
        XCTAssertEqual(Lines.text(of: written.answer(8)), "from the app")
        XCTAssertEqual(app.received.filter { $0["method"] as? String == "initialize" }.count, 1, "once for the connection")
    }

    func testTheRelaySurvivesTheAppBeingReplaced() {
        let path = TestPlace.socketPath()
        let written = Written()
        let relay = relay(path, written)
        relay.take(Lines.message(1, "initialize", ["clientInfo": ["name": "test-agent"]]))

        // The app goes away with a call unanswered, as it does when a new build takes its place.
        let old = FakeApp(path: path, helloID: relay.helloID, hangUpOn: 5)
        relay.take(Lines.message(5, "tools/call", ["name": "look"]))
        XCTAssertEqual(Lines.isError(written.answer(5)), true, "the call still gets an answer")
        XCTAssertEqual(Lines.text(of: written.answer(5)), "TestApp quit before it answered. Call again: it will be opened.")
        old.listener.stop()

        let new = FakeApp(path: path, helloID: relay.helloID)
        defer { new.listener.stop() }
        relay.take(Lines.message(6, "tools/call", ["name": "look"]))
        XCTAssertEqual(Lines.text(of: written.answer(6)), "from the app", "the next call reaches the new one")
        XCTAssertEqual(new.received.first?["method"] as? String, "initialize", "which is told who the agent is, like the first")
    }

    /// An answer with a picture in it is one long line, and it comes through the relay as the app sent it.
    func testAPictureComesThroughWhole() throws {
        let path = TestPlace.socketPath()
        let written = Written()
        let relay = relay(path, written)
        let png = Data((0..<900_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let app = FakeApp(path: path, helloID: relay.helloID) { id in
            AgentSession.result(id: id, ["content": [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]], "isError": false])
        }
        defer { app.listener.stop() }
        relay.take(Lines.message(1, "initialize", ["clientInfo": ["name": "test-agent"]]))
        relay.take(Lines.message(2, "tools/call", ["name": "look"]))
        let content = try XCTUnwrap(((written.answer(2)?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(content["type"] as? String, "image")
        XCTAssertEqual(Data(base64Encoded: content["data"] as? String ?? ""), png)
    }

    func testTheCommandIsTheAppsOwnProgramWithTheFlag() {
        XCTAssertTrue(AgentDoor.command.hasSuffix(" --mcp"))
        XCTAssertTrue(AgentDoor.command.contains(Bundle.main.executablePath ?? "?"))
    }
}
