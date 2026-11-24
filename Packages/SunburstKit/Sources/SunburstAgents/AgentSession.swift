import Foundation

/// One agent's side of the conversation, in the Model Context Protocol: JSON-RPC 2.0 messages, each on a line of its own.
/// It knows the protocol and nothing about the app: the tools and what answers them are handed to it.
@_spi(Diagnostics)
@MainActor
public final class AgentSession {
    /// The protocol versions this speaks, newest first.
    nonisolated static let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let host: AgentHost
    /// The agent has said what it calls itself.
    var onHello: @MainActor (_ name: String, _ version: String?) -> Void = { _, _ in }
    /// Carries out one tool call: the answer, or why there isn't one.
    var call: @MainActor (_ tool: String, _ arguments: [String: Any]) async -> Result<AgentReply, AgentFailure> = { _, _ in
        .failure(AgentFailure("Nothing answers here."))
    }

    private(set) var clientName: String?

    /// A conversation about this app's tools.
    public init(_ host: AgentHost) {
        self.host = host
    }

    /// Takes one line from the agent, in the order the lines came. The hello is dealt with before this returns, so the
    /// agent is known to whatever comes after it. Anything else is answered in its own time: a call may wait for the user,
    /// and mustn't hold up the next.
    func take(_ line: Data, reply: @escaping (Data) -> Void) {
        let parsed = try? JSONSerialization.jsonObject(with: line)
        if let message = parsed as? [String: Any], message["method"] as? String == "initialize", message["jsonrpc"] as? String == "2.0",
            let id = message["id"], !(id is NSNull)
        {
            if let answer = greet(id: id, parameters: message["params"] as? [String: Any] ?? [:]) { reply(answer) }
            return
        }
        Task { if let answer = await answer(parsed) { reply(answer) } }
    }

    /// Takes one line from the agent and gives the line to send back, if it's owed one.
    public func handle(_ line: Data) async -> Data? {
        await answer(try? JSONSerialization.jsonObject(with: line))
    }

    private func greet(id: Any, parameters: [String: Any]) -> Data? {
        let client = parameters["clientInfo"] as? [String: Any]
        let name = (client?["title"] as? String) ?? (client?["name"] as? String) ?? "An agent"
        clientName = name
        onHello(name, client?["version"] as? String)
        return Self.greeting(id: id, parameters: parameters, host: host)
    }

    /// The line owed for one message, read as JSON already: nil when it was nothing JSON could read.
    private func answer(_ parsed: Any?) async -> Data? {
        guard let parsed else { return Self.failure(id: NSNull(), code: -32700, "That isn't JSON.") }
        guard let message = parsed as? [String: Any], message["jsonrpc"] as? String == "2.0" else {
            return Self.failure(id: NSNull(), code: -32600, "One JSON-RPC 2.0 message a line.")
        }
        // No id: it's telling, not asking, and gets no answer. No method: it's an answer to something never asked.
        guard let method = message["method"] as? String else { return nil }
        guard let id = message["id"], !(id is NSNull) else { return nil }
        let parameters = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return greet(id: id, parameters: parameters)
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.toolList(id: id, host.tools)
        case "tools/call":
            guard let name = parameters["name"] as? String, host.tools.contains(where: { $0.name == name }) else {
                return Self.failure(id: id, code: -32602, "No such tool: \(parameters["name"] as? String ?? "")")
            }
            switch await call(name, parameters["arguments"] as? [String: Any] ?? [:]) {
            case .success(let reply):
                guard let content = reply.content() else { return Self.said(id: id, "\(host.name) couldn't write its answer.", isError: true) }
                return Self.result(id: id, ["content": content, "isError": false])
            case .failure(let why):
                return Self.said(id: id, why.message, isError: true)
            }
        default:
            return Self.failure(id: id, code: -32601, "\(host.name) doesn't know \(method).")
        }
    }

    // What needs nothing from the app, so the relay an agent starts can say it without the app running.

    /// The answer to an agent's hello: the protocol version to speak, and what the app is for.
    nonisolated static func greeting(id: Any, parameters: [String: Any], host: AgentHost) -> Data? {
        let asked = parameters["protocolVersion"] as? String
        return result(
            id: id,
            [
                "protocolVersion": asked.flatMap { versions.contains($0) ? $0 : nil } ?? versions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": host.name, "version": host.version],
                "instructions": host.instructions,
            ])
    }

    nonisolated static func toolList(id: Any, _ tools: [AgentTool]) -> Data? {
        result(id: id, ["tools": tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.schema] as [String: Any] }])
    }

    nonisolated static func result(id: Any, _ result: [String: Any]) -> Data? {
        AgentJSON.line(["jsonrpc": "2.0", "id": id, "result": result])
    }

    nonisolated static func failure(id: Any, code: Int, _ message: String) -> Data? {
        AgentJSON.line(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message] as [String: Any]])
    }

    /// A tool's answer in words. One that failed is still an answer, marked as an error, so the agent can read why.
    nonisolated static func said(id: Any, _ text: String, isError: Bool) -> Data? {
        result(id: id, ["content": [["type": "text", "text": text]], "isError": isError])
    }
}
