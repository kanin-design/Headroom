import XCTest
@testable import SunburstAgents

private let claude = AgentIdentity(name: "Test Agent", program: "/Applications/Test.app", signer: "Developer ID Application: Test (ABCDE12345)")

/// The user's answer to an agent that asks, and what's remembered of it.
@MainActor
final class AccessTests: XCTestCase {
    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString).json")
    }

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
        XCTAssertEqual(agents.activity.last?.what, "Allowed")
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
        XCTAssertEqual(agents.standing(of: claude), .refused)
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
        var resigned = claude
        resigned.signer = "Developer ID Application: Someone Else (ZZZZZ99999)"
        XCTAssertEqual(agents.standing(of: resigned), .asking, "nor is a program signed by someone else")
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
        let file = file()
        defer { try? FileManager.default.removeItem(at: file) }
        let agents = Agents(file: file)
        agents.arrived(UUID(), claude)
        agents.answer(agents.requests[0], .allow)
        agents.used(claude, "overview")
        let next = Agents(file: file)
        XCTAssertEqual(next.allowed.map(\.identity), [claude], "the next time the app opens, it's still allowed")
        XCTAssertNotNil(next.allowed.first?.lastUsed)

        next.remove(next.allowed[0])
        XCTAssertEqual(next.standing(of: claude), .asking)
        async let waiting = next.mayAnswer(claude, patience: .milliseconds(50))
        await Task.yield()
        XCTAssertEqual(next.requests.map(\.identity), [claude], "removed, it has to ask again")
        _ = await waiting
        XCTAssertTrue(Agents(file: file).allowed.isEmpty)
    }

    func testAnAgentAllowedToLookOnlyCantSelectUntilYouSaySo() async throws {
        let file = file()
        defer { try? FileManager.default.removeItem(at: file) }
        let agents = Agents(file: file)
        agents.arrived(UUID(), claude)
        agents.answer(agents.requests[0], .lookOnly)
        let mayLook = await agents.mayAnswer(claude)
        XCTAssertEqual(mayLook, true)
        XCTAssertFalse(agents.maySelect(claude))
        agents.setMaySelect(agents.allowed[0], true)
        XCTAssertTrue(agents.maySelect(claude))
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

    /// The file the app wrote before the door moved into this package reads the same: agents allowed then stay allowed.
    func testTheListIsSavedAsItAlwaysWas() throws {
        let file = file()
        defer { try? FileManager.default.removeItem(at: file) }
        let saved = #"[{"identity":{"name":"Claude","program":"/Applications/Claude.app","signer":"Developer ID Application: Anthropic"},"allowed":784000000,"lastUsed":784000100,"maySelect":true}]"#
        try Data(saved.utf8).write(to: file)
        let agents = Agents(file: file)
        XCTAssertEqual(agents.allowed.count, 1)
        XCTAssertEqual(agents.allowed[0].identity.programName, "Claude")
        XCTAssertEqual(agents.allowed[0].allowed, Date(timeIntervalSinceReferenceDate: 784_000_000))
        XCTAssertTrue(agents.allowed[0].maySelect)
        agents.setMaySelect(agents.allowed[0], false)
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        XCTAssertEqual(Set(written[0].keys), ["identity", "allowed", "lastUsed", "maySelect"], "and written with the same names")
        XCTAssertEqual(written[0]["allowed"] as? Double, 784_000_000)
        XCTAssertEqual((written[0]["identity"] as? [String: Any])?["signer"] as? String, "Developer ID Application: Anthropic")
        XCTAssertEqual(written[0]["maySelect"] as? Bool, false)
    }

    func testWhatAgentsDidIsKeptToTheLastFewHundred() {
        let agents = Agents(file: nil)
        for i in 0..<(Agents.longestActivity + 20) { agents.note(claude, "call \(i)") }
        XCTAssertEqual(agents.activity.count, Agents.longestActivity)
        XCTAssertEqual(agents.activity.first?.what, "call 20")
        XCTAssertEqual(agents.activity.last?.agent, "Test Agent")
    }
}
