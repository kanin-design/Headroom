import Darwin
import Foundation
import SunburstKit
@testable @_spi(Diagnostics) import SunburstAgents

/// A folder of the test's own, short enough for a socket's path, and an app that keeps its door there.
enum TestPlace {
    static func folder() -> URL {
        URL(fileURLWithPath: "/tmp/sa-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    static func socketPath() -> String { "/tmp/sa-\(UUID().uuidString.prefix(8)).sock" }

    static let tools = [
        AgentTool(name: "look", description: "Looks.", properties: ["path": ["type": "string"]]),
        AgentTool(name: "show", description: "Shows something.", properties: ["path": ["type": "string"]], selects: true),
    ]

    static func host(_ folder: URL = folder(), tools: [AgentTool] = tools) -> AgentHost {
        AgentHost(name: "TestApp", version: "1.2.3", instructions: "TestApp is for tests.", folder: folder, tools: tools,
                  accessSettingsLocation: "under Agents in Settings")
    }

    static func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }
}

enum Lines {
    static func message(_ id: Int?, _ method: String, _ params: [String: Any] = [:]) -> Data {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { message["id"] = id }
        return try! JSONSerialization.data(withJSONObject: message)
    }

    static func object(_ line: Data?) -> [String: Any]? {
        line.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    /// The text of a tool's answer.
    static func text(of answer: [String: Any]?) -> String? {
        (((answer?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first)?["text"] as? String
    }

    static func isError(_ answer: [String: Any]?) -> Bool? {
        (answer?["result"] as? [String: Any])?["isError"] as? Bool
    }

    /// One line read from a socket, a byte at a time.
    static func read(_ fd: Int32) -> String {
        var out = [UInt8]()
        var byte: UInt8 = 0
        while Darwin.read(fd, &byte, 1) == 1, byte != 0x0A { out.append(byte) }
        return String(decoding: out, as: UTF8.self)
    }

    static func write(_ fd: Int32, _ lines: Data...) {
        for line in lines {
            let data = line + Data([0x0A])
            _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        }
    }
}

/// What a relay wrote back to the agent, collected as it comes.
final class Written: @unchecked Sendable {
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

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var value: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

/// Stands in for the app: says what it was sent, answers every call, and can hang up on one.
final class FakeApp: @unchecked Sendable {
    let listener: AgentListener
    private let lock = NSLock()
    private var seen: [[String: Any]] = []
    var received: [[String: Any]] { lock.withLock { seen } }

    /// `answer` is what a call is answered with, as content: by default a line of text.
    init(path: String, helloID: String, hangUpOn silent: Int? = nil, answer: (@Sendable (Any) -> Data?)? = nil) {
        listener = AgentListener(path: path)
        _ = listener.start { [self] connection in
            Thread.detachNewThread { [self] in
                connection.read { line in
                    guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = message["id"] else { return }
                    lock.withLock { seen.append(message) }
                    if let silent, id as? Int == silent {
                        connection.hangUp()
                        return
                    }
                    if id as? String != helloID, let answer, let reply = answer(id) {
                        connection.send(reply)
                        return
                    }
                    let text = id as? String == helloID ? "hello back" : "from the app"
                    if let reply = AgentSession.said(id: id, text, isError: false) { connection.send(reply) }
                }
            }
        }
    }
}

/// A small tree for a chart: files at paths, with folders made on the way.
struct PathTree: SunburstTree {
    struct Node {
        var name: String
        var parent: UInt32
        var children: [UInt32] = []
        var own: UInt64 = 0
        var folder = true
    }

    var nodes: [Node] = [Node(name: "", parent: 0)]
    var totals: [UInt64] = []

    init(_ files: [(String, UInt64)]) {
        for (path, bytes) in files {
            var at: UInt32 = 0
            let parts = path.split(separator: "/").map(String.init)
            for (i, part) in parts.enumerated() {
                if let found = nodes[Int(at)].children.first(where: { nodes[Int($0)].name == part }) {
                    at = found
                    continue
                }
                let id = UInt32(nodes.count)
                let isFile = i == parts.count - 1
                nodes.append(Node(name: part, parent: at, own: isFile ? bytes : 0, folder: !isFile))
                nodes[Int(at)].children.append(id)
                at = id
            }
        }
        totals = [UInt64](repeating: 0, count: nodes.count)
        func sum(_ id: UInt32) -> UInt64 {
            let t = nodes[Int(id)].children.reduce(nodes[Int(id)].own) { $0 + sum($1) }
            totals[Int(id)] = t
            return t
        }
        _ = sum(0)
        for i in nodes.indices { nodes[i].children.sort { totals[Int($0)] > totals[Int($1)] } }
    }

    func node(_ path: String) -> UInt32 {
        var at: UInt32 = 0
        for part in path.split(separator: "/") {
            at = nodes[Int(at)].children.first { nodes[Int($0)].name == part }!
        }
        return at
    }

    func firstChild(of node: UInt32) -> UInt32 { nodes[Int(node)].children.first ?? 0 }
    func nextSibling(of node: UInt32) -> UInt32 {
        let siblings = nodes[Int(nodes[Int(node)].parent)].children
        guard node != 0, let at = siblings.firstIndex(of: node), at + 1 < siblings.count else { return 0 }
        return siblings[at + 1]
    }
    func parent(of node: UInt32) -> UInt32 { nodes[Int(node)].parent }
    func size(of node: UInt32) -> UInt64 { totals[Int(node)] }
    func ownSize(of node: UInt32) -> UInt64 { nodes[Int(node)].own }
    func isFolder(_ node: UInt32) -> Bool { nodes[Int(node)].folder }
    func style(of node: UInt32) -> PieceStyle { nodes[Int(node)].folder ? .folder : .file }
    func nameKey(of node: UInt32) -> UInt64 { UInt64(truncatingIfNeeded: nodes[Int(node)].name.hashValue) }
}
