import Darwin
import XCTest
@testable import SunburstAgents

/// The socket only the user can open, and what the system says about who is on the other end.
@MainActor
final class SocketTests: XCTestCase {
    func testOnlyYouCanOpenTheSocketAndLinesGoBothWays() async throws {
        let path = TestPlace.socketPath()
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
            return [Lines.read(fd), Lines.read(fd), Lines.read(fd)]
        }.value
        XCTAssertEqual(replies, ["got one", "got two", "got three"])
    }

    /// A line far longer than one read, as an answer with a picture in it is, arrives whole, with what follows it.
    func testALongLineArrivesWhole() async throws {
        let path = TestPlace.socketPath()
        let listener = AgentListener(path: path)
        defer { listener.stop() }
        XCTAssertTrue(listener.start { connection in
            Thread.detachNewThread {
                connection.read { line in connection.send(Data("\(line.count) \(line.first ?? 0) \(line.last ?? 0)".utf8)) }
            }
        })
        let fd = try XCTUnwrap(AgentSocket.connect(to: path))
        defer { close(fd) }
        let replies = await Task.detached { () -> [String] in
            var long = Data(repeating: UInt8(ascii: "a"), count: 1_500_000)
            long[long.startIndex] = UInt8(ascii: "b")
            long.append(contentsOf: Array("\nshort\n".utf8))
            long.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let wrote = write(fd, raw.baseAddress! + sent, min(raw.count - sent, 100_000))
                    guard wrote > 0 else { break }
                    sent += wrote
                }
            }
            return [Lines.read(fd), Lines.read(fd)]
        }.value
        XCTAssertEqual(replies, ["1500000 98 97", "5 115 116"])
    }

    func testARunningCopyKeepsItsSocketAndALeftoverFileIsReplaced() throws {
        let path = TestPlace.socketPath()
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

    func testAFileThatIsntASocketIsLeftAlone() throws {
        let path = TestPlace.socketPath()
        try Data("keep".utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertFalse(AgentListener(path: path).start { _ in }, "nothing listens where a file is")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "keep", "and the file is still there")
    }

    func testTheProgramBehindAConnectionIsReadFromTheSystem() throws {
        let own = try XCTUnwrap(AgentPeer.path(of: getpid()))
        XCTAssertTrue(own.hasPrefix("/"))
        let parent = try XCTUnwrap(AgentPeer.parent(of: getpid()))
        XCTAssertEqual(parent, getppid())

        XCTAssertEqual(AgentPeer.program(ofPath: "/Applications/Claude.app/Contents/Helpers/disclaimer"), "/Applications/Claude.app")
        XCTAssertEqual(AgentPeer.program(ofPath: "/opt/homebrew/bin/codex"), "/opt/homebrew/bin/codex")

        // Anything that connects by itself is the agent. The app's own relay only passes lines on, so the agent is what
        // started it.
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
        XCTAssertEqual(AgentIdentity(name: "x", program: "/Applications/Claude.app", signer: "Developer ID Application: Anthropic").origin,
                       "Started by Claude. Signed by Developer ID Application: Anthropic.")
        XCTAssertEqual(AgentIdentity(name: "x", program: "/opt/homebrew/bin/codex", signer: nil).origin, "Started by codex. Not signed by a known developer.")
    }
}
