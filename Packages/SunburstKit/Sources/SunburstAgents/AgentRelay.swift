import Darwin
import Foundation

extension AgentDoor {
    /// What an agent starts to reach the app: the app's own program with `--mcp`, which relays between the agent and the
    /// app that's running. Call it before anything else when the program starts, as `relayIfAsked(_:)` does; it never
    /// returns.
    ///
    /// Agents start every server they know about with every session, so the relay stays quiet until the app is really
    /// wanted: it answers the hello and lists the tools by itself, and only a tool call reaches for the app, opening it if
    /// it's closed. From then on it carries lines both ways. When the app quits or is replaced by a new build, the next call
    /// reaches for it again. `--socket <path>` relays to another socket, and opens nothing.
    public nonisolated static func relay(_ host: AgentHost) -> Never {
        // An agent that has gone mustn't take this down mid-line: the write fails and the relay ends by itself.
        signal(SIGPIPE, SIG_IGN)
        let arguments = CommandLine.arguments
        let asked = arguments.firstIndex(of: "--socket").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let out = NSLock()
        let relay = AgentRelay(host: host, path: asked ?? host.socketPath, open: asked == nil ? AgentRelay.openApp : nil) { line in
            out.withLock { FileHandle.standardOutput.write(line + Data([0x0A])) }
        }
        while let line = readLine(strippingNewline: true) {
            if !line.isEmpty { relay.take(Data(line.utf8)) }
        }
        // The agent closed its end. What the app still has to say gets a moment to arrive.
        usleep(300_000)
        exit(0)
    }

    /// Relays for an agent, and never returns, when the program was started with `--mcp`; otherwise returns at once. Call it
    /// first thing: in `main.swift`, or in the `App`'s `init()`.
    public nonisolated static func relayIfAsked(_ host: AgentHost) {
        if CommandLine.arguments.contains(relayFlag) { relay(host) }
    }
}

/// Passes lines between an agent and the app, answering what it can by itself.
final class AgentRelay: @unchecked Sendable {
    /// How long to wait for the app to come up, when this had to open it.
    static let patience = 20.0

    private let host: AgentHost
    private let path: String
    private let open: (@Sendable () -> Void)?
    private let patience: Double
    private let write: @Sendable (Data) -> Void
    /// The id the agent's hello is given when it's passed on to the app. The app's answer to it is for nobody.
    let helloID: String

    private let lock = NSLock()
    private var connection: AgentConnection?
    private var hello: [String: Any]?
    /// Whether the app on the other end of `connection` has been told who the agent is.
    private var saidHello = false
    /// What the app hasn't answered yet, by id, so each still gets an answer if the app goes away.
    private var owed: [String: Any] = [:]

    init(host: AgentHost, path: String, open: (@Sendable () -> Void)?, patience: Double = AgentRelay.patience,
         write: @escaping @Sendable (Data) -> Void) {
        self.host = host
        self.path = path
        self.open = open
        self.patience = patience
        self.write = write
        helloID = host.name.lowercased() + "-relay-hello"
    }

    /// One line from the agent.
    func take(_ line: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            if let reply = AgentSession.failure(id: NSNull(), code: -32700, "That isn't JSON.") { write(reply) }
            return
        }
        // An answer to something never asked, or nothing that names what it wants: there's nothing to do with it.
        guard let method = message["method"] as? String else { return }
        let id = message["id"].flatMap { $0 is NSNull ? nil : $0 }
        let parameters = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            lock.withLock {
                hello = message
                saidHello = false
            }
            if let id, let reply = AgentSession.greeting(id: id, parameters: parameters, host: host) { write(reply) }
        case "ping":
            if let id, let reply = AgentSession.result(id: id, [:]) { write(reply) }
        case "tools/list":
            if let id, let reply = AgentSession.toolList(id: id, host.tools) { write(reply) }
        case "tools/call":
            guard let id else { return }
            guard let connection = reach() else {
                if let reply = AgentSession.said(id: id, "\(host.name) isn't running and couldn't be opened.", isError: true) { write(reply) }
                return
            }
            lock.withLock { owed[Self.key(id)] = id }
            connection.send(line)
        default:
            // Only a tool call is worth opening the app for. Agents ask other things before they've even said hello, to
            // see what a server can do: those are answered here, and what's only told needs no answer.
            if let id, let reply = AgentSession.failure(id: id, code: -32601, "\(host.name) doesn't know \(method).") { write(reply) }
        }
    }

    private static func key(_ id: Any) -> String { "\(type(of: id)):\(id)" }

    /// The connection to the app, made now if there isn't one: the app is opened if it has to be, and told who the agent is.
    private func reach() -> AgentConnection? {
        if let connection = lock.withLock({ connection }) {
            sayHello(to: connection)
            return connection
        }
        var fd = AgentSocket.connect(to: path)
        if fd == nil, let open {
            open()
            let giveUp = Date().addingTimeInterval(patience)
            while fd == nil, Date() < giveUp {
                usleep(200_000)
                fd = AgentSocket.connect(to: path)
            }
        }
        guard let fd else { return nil }
        // The app's answers come from the user's own app, and a picture in one can be several megabytes.
        let made = AgentConnection(fd: fd, longestLine: 64 << 20)
        lock.withLock {
            connection = made
            saidHello = false
        }
        sayHello(to: made)
        Thread.detachNewThread { [self] in
            made.read { line in pass(line) }
            // The app hung up: it quit, or a new build took its place. Whatever it still owed gets an answer.
            let unanswered: [Any] = lock.withLock {
                if connection === made { connection = nil }
                defer { owed = [:] }
                return Array(owed.values)
            }
            for id in unanswered {
                if let reply = AgentSession.said(id: id, "\(host.name) quit before it answered. Call again: it will be opened.", isError: true) { write(reply) }
            }
        }
        return made
    }

    /// Passes the agent's hello on, once for each connection, before the first call on it: however early the connection
    /// was made, the app knows who is calling.
    private func sayHello(to connection: AgentConnection) {
        let said: [String: Any]? = lock.withLock {
            guard !saidHello, self.connection === connection, let hello else { return nil }
            saidHello = true
            return hello
        }
        guard var said else { return }
        said["id"] = helloID
        if let line = AgentJSON.line(said) { connection.send(line) }
    }

    /// One line from the app, on its way to the agent.
    private func pass(_ line: Data) {
        if let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = message["id"], !(id is NSNull) {
            if id as? String == helloID { return }
            lock.withLock { owed[Self.key(id)] = nil }
        }
        write(line)
    }

    /// Opens the app this program is inside, behind whatever is in front.
    @Sendable static func openApp() {
        guard let own = Bundle.main.executablePath else { return }
        let app = AgentPeer.program(ofPath: own)
        guard app.hasSuffix(".app") else { return }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", app]
        try? open.run()
        open.waitUntilExit()
    }
}
