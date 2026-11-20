import XCTest
@testable @_spi(Diagnostics) import SunburstAgents

/// The protocol: an agent's hello, the tools it's shown, and the answers to its calls.
@MainActor
final class SessionTests: XCTestCase {
    private func session() -> AgentSession { AgentSession(TestPlace.host()) }

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
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "TestApp", "the app's own name")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["version"] as? String, "1.2.3")
        XCTAssertEqual(result["instructions"] as? String, "TestApp is for tests.", "and what the app tells agents")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"], "it offers tools")
        XCTAssertEqual(said, "test-agent")
        XCTAssertEqual(session.clientName, "test-agent")
        XCTAssertEqual(reply?["id"] as? Int, 1)

        let newer = try await ask(session, ["jsonrpc": "2.0", "id": "a", "method": "initialize", "params": ["protocolVersion": "2099-01-01"]])
        XCTAssertEqual((newer?["result"] as? [String: Any])?["protocolVersion"] as? String, AgentSession.versions[0], "and its own newest otherwise")
        XCTAssertEqual(newer?["id"] as? String, "a", "an id comes back as it was sent")
        let titled = try await ask(session, ["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["clientInfo": ["name": "cli", "title": "Test Agent"]]])
        XCTAssertNotNil(titled?["result"])
        XCTAssertEqual(said, "Test Agent", "a title, when it gives one, is what it's called")
    }

    func testWhatIsntARequestGetsTheRightAnswerOrNone() async throws {
        let session = session()
        let none = try await ask(session, ["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertNil(none, "something told, not asked, gets no answer")
        let unknown = try await ask(session, ["jsonrpc": "2.0", "id": 2, "method": "resources/list"])
        XCTAssertEqual((unknown?["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual((unknown?["error"] as? [String: Any])?["message"] as? String, "TestApp doesn't know resources/list.")
        let noTool = try await ask(session, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "delete_everything"]])
        XCTAssertEqual((noTool?["error"] as? [String: Any])?["code"] as? Int, -32602)
        let ping = try await ask(session, ["jsonrpc": "2.0", "id": 4, "method": "ping"])
        XCTAssertNotNil(ping?["result"])
        let notRPC = try await ask(session, ["id": 5, "method": "ping"])
        XCTAssertEqual((notRPC?["error"] as? [String: Any])?["code"] as? Int, -32600)

        let broken = await session.handle(Data("{not json".utf8))
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(broken)) as? [String: Any])
        XCTAssertEqual((parsed["error"] as? [String: Any])?["code"] as? Int, -32700)
    }

    func testEveryToolIsListedWithItsSchema() async throws {
        let reply = try await ask(session(), ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let tools = try XCTUnwrap((reply?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["look", "show"], "the app's tools, in its order")
        let schema = try XCTUnwrap(tools[0]["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertNotNil((schema["properties"] as? [String: Any])?["path"])
        XCTAssertEqual(tools[1]["description"] as? String, "Shows something.")
    }

    func testAToolsAnswerAndAToolsFailureAreBothAnswers() async throws {
        let session = session()
        session.call = { tool, arguments in
            arguments["path"] as? String == "/missing" ? .failure(AgentFailure("Not there.")) : .success(.json(["tool": tool, "size": UInt64(5_000_000_000)]))
        }
        let good = try await ask(session, ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "show", "arguments": ["path": "/there"]]])
        let result = try XCTUnwrap(good?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        let answer = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(answer["size"] as? Int, 5_000_000_000, "sizes past four billion come through whole")
        XCTAssertEqual(answer["tool"] as? String, "show")

        XCTAssertFalse(text.contains("\n"), "with no layout: an agent pays for every space")
        XCTAssertFalse(text.contains(" "))
        let bad = try await ask(session, ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "show", "arguments": ["path": "/missing"]]])
        let failed = try XCTUnwrap(bad?["result"] as? [String: Any])
        XCTAssertEqual(failed["isError"] as? Bool, true)
        XCTAssertEqual((failed["content"] as? [[String: Any]])?.first?["text"] as? String, "Not there.")
    }

    /// A picture goes back as an image, beside any text, and the agent sees it as one.
    func testAnAnswerCanBeAnImage() async throws {
        let session = session()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        session.call = { _, _ in .success(AgentReply([.text("The chart."), .image(png, mimeType: "image/png")])) }
        let reply = try await ask(session, ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "look"]])
        let content = try XCTUnwrap((reply?["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[1]["type"] as? String, "image")
        XCTAssertEqual(content[1]["mimeType"] as? String, "image/png")
        XCTAssertEqual(Data(base64Encoded: content[1]["data"] as? String ?? ""), png, "the file's bytes, in base64")
        XCTAssertEqual((reply?["result"] as? [String: Any])?["isError"] as? Bool, false)
    }

    func testAnAnswerJSONCantHoldIsSaidToBeAnError() async throws {
        let session = session()
        session.call = { _, _ in .success(.json(["when": Date()])) }
        let reply = try await ask(session, ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "look"]])
        XCTAssertEqual(Lines.isError(reply), true)
        XCTAssertEqual(Lines.text(of: reply), "TestApp couldn't write its answer.")
    }

    func testWhatFollowsTheHelloFindsTheAgentKnown() async throws {
        let session = session()
        var said: String?
        var seenByCall: String?
        session.onHello = { name, _ in said = name }
        session.call = { _, _ in
            seenByCall = said
            return .success(.json([:]))
        }
        let answers = expectation(description: "both answered")
        answers.expectedFulfillmentCount = 2
        // One straight after the other, as they arrive when the relay passes on a hello and a call together.
        session.take(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "hello", "method": "initialize", "params": ["clientInfo": ["name": "test-agent"]]])) { _ in answers.fulfill() }
        XCTAssertEqual(said, "test-agent", "the hello is dealt with before anything else is looked at")
        session.take(try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "look"]])) { _ in answers.fulfill() }
        await fulfillment(of: [answers], timeout: 2)
        XCTAssertEqual(seenByCall, "test-agent")
    }

    func testAToolsSchemaIsAnObjectThatTakesOnlyWhatItNames() {
        let tool = AgentTool(name: "zoom", description: "Zooms.", properties: ["node": ["type": "integer"]], required: ["node"], selects: true)
        XCTAssertEqual(tool.schema["type"] as? String, "object")
        XCTAssertEqual(tool.schema["required"] as? [String], ["node"])
        XCTAssertEqual(tool.schema["additionalProperties"] as? Bool, false)
        XCTAssertTrue(tool.selects)
        XCTAssertFalse(AgentTool(name: "look", description: "Looks.").selects, "a tool only looks unless it says otherwise")
    }
}
