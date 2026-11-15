import Foundation

/// Lets agents talk to the running app. Each connection is one agent: it says who it is, you allow it or not, and from then
/// on its requests are answered from what the app has on screen.
@MainActor
final class AgentServer {
    static let shared = AgentServer()

    private var listener: AgentListener?
    /// Headroom's own program, which agents start as their way in. It only relays, so the agent is whatever started it.
    nonisolated static let helper = Bundle.main.executablePath

    /// Opens the door, if this copy of the app is the one to do it.
    func start(at path: String = AgentSocket.path) {
        guard listener == nil else { return }
        let listener = AgentListener(path: path)
        let opened = listener.start { connection in
            Thread.detachNewThread { Self.serve(connection) }
        }
        if opened { self.listener = listener }
    }

    func stop() {
        listener?.stop()
        listener = nil
    }

    /// One agent, from hello to hanging up. On a thread of its own, since reading waits.
    private nonisolated static func serve(_ connection: AgentConnection) {
        let id = UUID()
        // Before anything is read: which program this is can't change, and the agent's first line needs it.
        let origin = AgentPeer.origin(ofSocket: connection.fd, helper: helper)
        let session = DispatchQueue.main.sync {
            MainActor.assumeIsolated { makeSession(id, program: origin.program, signer: origin.signer) }
        }
        connection.read { line in
            // The main queue runs these in the order they came, and the hello is dealt with there and then. So whatever
            // follows it finds the agent known, though each request after that is answered in its own time.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { session.take(line) { connection.send($0) } }
            }
        }
        Task { @MainActor in Agents.shared.left(id) }
    }

    private static func makeSession(_ id: UUID, program: String, signer: String?) -> AgentSession {
        let session = AgentSession(tools: AgentLook.tools, version: Updater.currentShown)
        var identity: AgentIdentity?
        func known(as name: String) -> AgentIdentity {
            let named = AgentIdentity(name: String(name.prefix(80)), program: program, signer: signer)
            if let before = identity, before.key != named.key { Agents.shared.left(id) }
            identity = named
            Agents.shared.arrived(id, named)
            return named
        }
        // The name is the agent's own word, so it's kept short. The rest was read from the system.
        session.onHello = { name, _ in _ = known(as: name) }
        session.call = { tool, arguments in
            // One that calls without having said its name is known by its program, which it can't make up, and asked about
            // like any other: it never gets answers unasked, and it's never turned away for a hello that went missing.
            let identity = identity ?? known(as: AgentIdentity(name: "", program: program, signer: signer).programName)
            switch await Agents.shared.mayAnswer(identity) {
            case true?: break
            case false?: return .failure(AgentFailure("The user didn't allow this agent to use Headroom."))
            case nil:
                return .failure(AgentFailure("Waiting for the user to allow this agent. Headroom is asking in its window: ask the user to answer there, then try again."))
            }
            if AgentLook.tools.first(where: { $0.name == tool })?.selects == true, !Agents.shared.maySelect(identity) {
                return .failure(AgentFailure("The user allowed this agent to look only. They can change that in Headroom, under Agents in the app menu."))
            }
            do {
                let answer = try await AgentAPI(model: AppModel.shared).answer(tool, arguments, by: identity.name)
                Agents.shared.used(identity, describe(tool, arguments))
                return .success(answer)
            } catch let failure as AgentFailure {
                return .failure(failure)
            } catch {
                return .failure(AgentFailure("Headroom couldn't answer that."))
            }
        }
        return session
    }

    /// What an agent asked for, in a line for the list of what agents did.
    static func describe(_ tool: String, _ arguments: [String: Any]) -> String {
        var said = ["path", "group"].compactMap { key in (arguments[key] as? String).map { "\(key) \($0)" } }
        for key in ["paths", "ids"] {
            guard let list = arguments[key] as? [String], let first = list.first else { continue }
            said.append(list.count == 1 ? first : "\(list.count) \(key), first \(first)")
        }
        if let disk = arguments["disk"] as? String { said.append(disk) }
        return said.isEmpty ? tool : tool + ": " + said.joined(separator: ", ")
    }
}
