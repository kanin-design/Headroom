import AppKit
import Foundation

/// The app agents talk to, as they're told it: its name, its version, what it's for, its tools, and the folder its door is
/// in. The app and the relay agents start (`relay(_:)`) are each given one.
public struct AgentHost: Sendable {
    /// The app's name: the server agents see, and what the messages they're told call it, as in "FolderMap is asking in
    /// its window".
    public var name: String
    /// The app's version, as agents are told it.
    public var version: String
    /// What every agent is told once, when it connects: what the app is for and how to use its tools.
    public var instructions: String
    /// The app's own folder, such as its folder in Application Support. The door is a socket file in it, `agent.sock`,
    /// and the agents the user allowed are kept in it, in `agents.json`. Its path must be short enough for a socket's,
    /// under about 90 characters.
    public var folder: URL
    /// Every tool, the app's own and any it adds, such as `SunburstAgentTools.tools`.
    public var tools: [AgentTool]
    /// Where the user changes what an agent may do, as an agent allowed only to look is told it when it calls a tool that
    /// selects: "under Agents in the app menu". Nil says only the app's name.
    public var accessSettingsLocation: String?

    public init(
        name: String, version: String, instructions: String, folder: URL, tools: [AgentTool],
        accessSettingsLocation: String? = nil
    ) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.folder = folder
        self.tools = tools
        self.accessSettingsLocation = accessSettingsLocation
    }

    /// Where the door is: the socket file the app listens on and the relay connects to.
    public var socketPath: String { folder.appendingPathComponent("agent.sock").path }
    /// Where the agents the user allowed are kept.
    public var allowListFile: URL { folder.appendingPathComponent("agents.json") }
}

/// The door agents come in by. It listens on a socket file that only the user can open, speaks the Model Context Protocol
/// with each agent, asks the user about each agent before it answers anything, and hands each call the user allowed to the
/// app. Nothing listens on the network.
///
/// ```swift
/// let door = AgentDoor.open(host) { call in
///     switch call.tool {
///     case "reveal": return .json(["revealed": try reveal(call.arguments["path"] as? String)])
///     default: return try SunburstAgentTools.answer(call, chart: chart)
///     }
/// }
/// ```
///
/// A call reaches `answer` only from an agent the user allowed, and a tool that `selects` only from one allowed to select.
/// Agents reach the door through the app's own program, started with `--mcp` (see `relay(_:)`): give them
/// `AgentDoor.command`.
@MainActor
public final class AgentDoor {
    /// Carries out one call the user allowed: the answer, or an `AgentFailure` that says why there isn't one.
    public typealias Answer = @MainActor (AgentCall) async throws -> AgentReply

    /// What agents are told about the app, and where the door is.
    public let host: AgentHost
    /// Who's asking, who's allowed, who's connected, and what they did.
    public let agents: Agents
    /// The line each answered call adds to `agents.activity`. By default the tool and what it was given.
    public var describe: (AgentCall) -> String = AgentDoor.describe
    /// Whether the door is open: false before `open()`, and when another copy of the app has it.
    public private(set) var isOpen = false
    /// For a check: how long a call waits for the user's answer.
    @_spi(Diagnostics) public var patience = Agents.patience

    private let answer: Answer
    private var listener: AgentListener?
    /// The program agents start as their way in: this app's own, which only relays, so the agent is whatever started it.
    var relayProgram = Bundle.main.executablePath

    /// A door for this app, closed. Its `agents` are read from the folder at once, so a view can show them before it opens.
    public init(_ host: AgentHost, answer: @escaping Answer) {
        self.host = host
        self.answer = answer
        agents = Agents(file: host.allowListFile)
    }

    /// A door for this app, open.
    public static func open(_ host: AgentHost, answer: @escaping Answer) -> AgentDoor {
        let door = AgentDoor(host, answer: answer)
        door.open()
        return door
    }

    /// Starts listening. False when it couldn't, as when another copy of the app already listens there: agents reach that
    /// one.
    @discardableResult
    public func open() -> Bool {
        guard listener == nil else { return true }
        try? FileManager.default.createDirectory(at: host.folder, withIntermediateDirectories: true)
        let listener = AgentListener(path: host.socketPath)
        let helper = relayProgram
        let opened = listener.start { [self] connection in
            Thread.detachNewThread { Self.serve(connection, door: self, helper: helper) }
        }
        if opened { self.listener = listener }
        isOpen = opened
        return opened
    }

    /// Stops listening and takes the socket file away. Agents connected now are still answered until they hang up.
    public func close() {
        listener?.stop()
        listener = nil
        isOpen = false
    }

    /// The command an agent is given to reach this app: its own program, with `--mcp`.
    public nonisolated static var command: String {
        let program = Bundle.main.executablePath ?? ""
        return (program.contains(" ") ? "\"\(program)\"" : program) + " " + relayFlag
    }

    /// What the app's program is started with to relay for an agent.
    public nonisolated static let relayFlag = "--mcp"

    // MARK: One agent

    /// One agent, from hello to hanging up. On a thread of its own, since reading waits.
    private nonisolated static func serve(_ connection: AgentConnection, door: AgentDoor, helper: String?) {
        let id = UUID()
        // Before anything is read: which program this is can't change, and the agent's first line needs it.
        let origin = AgentPeer.origin(ofSocket: connection.fd, helper: helper)
        let session = DispatchQueue.main.sync {
            MainActor.assumeIsolated { door.session(id, program: origin.program, signer: origin.signer) }
        }
        connection.read { line in
            // The main queue runs these in the order they came, and the hello is dealt with there and then. So whatever
            // follows it finds the agent known, though each request after that is answered in its own time.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { session.take(line) { connection.send($0) } }
            }
        }
        Task { @MainActor in door.agents.left(id) }
    }

    /// The conversation with one agent, as a connection has it: from a program the system named, the user asked about it,
    /// and each call it makes answered only as far as the user allowed.
    @_spi(Diagnostics)
    public func session(_ id: UUID = UUID(), program: String, signer: String?) -> AgentSession {
        let session = AgentSession(host)
        let agents = agents, host = host
        var identity: AgentIdentity?
        func known(as name: String) -> AgentIdentity {
            let named = AgentIdentity(name: String(name.prefix(80)), program: program, signer: signer)
            if let before = identity, before.key != named.key { agents.left(id) }
            identity = named
            agents.arrived(id, named)
            return named
        }
        // The name is the agent's own word, so it's kept short. The rest was read from the system.
        session.onHello = { name, _ in _ = known(as: name) }
        session.call = { [self] tool, arguments in
            // One that calls without having said its name is known by its program, which it can't make up, and asked about
            // like any other: it never gets answers unasked, and it's never turned away for a hello that went missing.
            let identity = identity ?? known(as: AgentIdentity(name: "", program: program, signer: signer).programName)
            switch await agents.mayAnswer(identity, patience: patience) {
            case true?: break
            case false?: return .failure(AgentFailure("The user didn't allow this agent to use \(host.name)."))
            case nil:
                return .failure(
                    AgentFailure(
                        "Waiting for the user to allow this agent. \(host.name) is asking in its window: ask the user to answer there, then try again."
                    ))
            }
            if host.tools.first(where: { $0.name == tool })?.selects == true, !agents.maySelect(identity) {
                let place = host.accessSettingsLocation.map { ", " + $0 } ?? ""
                return .failure(AgentFailure("The user allowed this agent to look only. They can change that in \(host.name)\(place)."))
            }
            let call = AgentCall(tool: tool, arguments: arguments, agent: identity)
            do {
                let reply = try await answer(call)
                agents.used(identity, describe(call))
                return .success(reply)
            } catch let failure as AgentFailure {
                return .failure(failure)
            } catch {
                return .failure(AgentFailure("\(host.name) couldn't answer that."))
            }
        }
        return session
    }

    /// What an agent asked for, in a line for the list of what agents did: the tool, then what it was given that's words or
    /// a number, by name. A list is said by how long it is and its first.
    public nonisolated static func describe(_ call: AgentCall) -> String {
        var said: [String] = []
        for key in call.arguments.keys.sorted() {
            switch call.arguments[key] {
            case let text as String:
                said.append("\(key) \(text)")
            case let number as NSNumber:
                let isFlag = CFGetTypeID(number) == CFBooleanGetTypeID()
                said.append("\(key) " + (isFlag ? (number.boolValue ? "true" : "false") : "\(number)"))
            case let list as [Any]:
                guard let first = list.first else { continue }
                said.append(list.count == 1 ? "\(first)" : "\(list.count) \(key), first \(first)")
            default:
                continue
            }
        }
        return said.isEmpty ? call.tool : call.tool + ": " + said.joined(separator: ", ")
    }
}
