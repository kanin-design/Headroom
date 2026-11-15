import AppKit
import Foundation

/// An agent you've allowed, and when.
struct AllowedAgent: Codable, Identifiable, Equatable {
    var identity: AgentIdentity
    var allowed: Date
    var lastUsed: Date?
    /// Whether it may select things for removal and bring the window forward, or only look.
    var maySelect = false
    var id: String { identity.key }

    init(identity: AgentIdentity, allowed: Date, maySelect: Bool) {
        self.identity = identity
        self.allowed = allowed
        self.maySelect = maySelect
    }

    /// One allowed before agents could select was allowed to look, and that's what it keeps.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identity = try values.decode(AgentIdentity.self, forKey: .identity)
        allowed = try values.decode(Date.self, forKey: .allowed)
        lastUsed = try values.decodeIfPresent(Date.self, forKey: .lastUsed)
        maySelect = try values.decodeIfPresent(Bool.self, forKey: .maySelect) ?? false
    }
}

/// What you can say to an agent that asks.
enum AgentAnswer { case allow, lookOnly, deny }

/// An agent waiting for your answer.
struct AgentRequest: Identifiable, Equatable {
    var identity: AgentIdentity
    var id: String { identity.key }
}

/// An agent that's connected now.
struct ConnectedAgent: Identifiable, Equatable {
    var id: UUID
    var identity: AgentIdentity
    var since: Date
}

/// Something an agent asked for.
struct AgentActivity: Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var agent: String
    var what: String
}

/// Which agents may talk to Headroom. Nothing is answered until you've allowed the agent that asks, and what you allowed
/// is remembered until you remove it.
@MainActor
@Observable
final class Agents {
    static let shared = Agents(file: AppData.folder.appendingPathComponent("agents.json"))

    private(set) var allowed: [AllowedAgent] = []
    private(set) var requests: [AgentRequest] = []
    private(set) var connected: [ConnectedAgent] = []
    private(set) var activity: [AgentActivity] = []

    /// Turned down since the app started. It isn't asked about again until the app is opened again.
    @ObservationIgnored private var refused: Set<String> = []
    @ObservationIgnored private var waiting: [String: [UUID: CheckedContinuation<Bool?, Never>]] = [:]
    @ObservationIgnored private let file: URL?

    /// How long a request waits for your answer before the agent is told to try again.
    nonisolated static let patience: Duration = .seconds(90)
    /// As much as the list of what agents asked for holds.
    static let longestActivity = 200

    init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([AllowedAgent].self, from: data) {
            allowed = saved
        }
    }

    enum Standing { case allowed, refused, asking }

    func standing(of identity: AgentIdentity) -> Standing {
        if allowed.contains(where: { $0.id == identity.key }) { return .allowed }
        return refused.contains(identity.key) ? .refused : .asking
    }

    // MARK: Connections

    /// An agent has connected and said who it is. One you haven't answered about yet is put to you.
    func arrived(_ id: UUID, _ identity: AgentIdentity) {
        connected.removeAll { $0.id == id }
        connected.append(ConnectedAgent(id: id, identity: identity, since: Date()))
        ask(about: identity)
    }

    /// Puts an agent to you, if you haven't answered about it and aren't being asked already.
    private func ask(about identity: AgentIdentity) {
        guard standing(of: identity) == .asking, !requests.contains(where: { $0.id == identity.key }) else { return }
        requests.append(AgentRequest(identity: identity))
        // In the Dock, when Headroom isn't in front: a question is waiting.
        NSApp?.requestUserAttention(.informationalRequest)
    }

    func left(_ id: UUID) {
        guard let gone = connected.first(where: { $0.id == id }) else { return }
        connected.removeAll { $0.id == id }
        // Nobody is left to hear the answer.
        if !connected.contains(where: { $0.identity.key == gone.identity.key }) {
            requests.removeAll { $0.id == gone.identity.key }
            settle(gone.identity.key, nil)
        }
    }

    // MARK: Asking

    /// Whether this agent may have an answer: true or false once you've said, nil if you haven't within `patience`.
    func mayAnswer(_ identity: AgentIdentity, patience: Duration = Agents.patience) async -> Bool? {
        switch standing(of: identity) {
        case .allowed: return true
        case .refused: return false
        case .asking: break
        }
        // One you allowed and then removed asks again, as a new one would.
        ask(about: identity)
        let ticket = UUID()
        let key = identity.key
        return await withCheckedContinuation { continuation in
            waiting[key, default: [:]][ticket] = continuation
            Task { @MainActor in
                try? await Task.sleep(for: patience)
                if let still = self.waiting[key]?.removeValue(forKey: ticket) { still.resume(returning: nil) }
            }
        }
    }

    private func settle(_ key: String, _ answer: Bool?) {
        for (_, continuation) in waiting.removeValue(forKey: key) ?? [:] { continuation.resume(returning: answer) }
    }

    /// Your answer to an agent that asked.
    func answer(_ request: AgentRequest, _ answer: AgentAnswer) {
        requests.removeAll { $0.id == request.id }
        if answer == .deny {
            refused.insert(request.id)
        } else {
            allowed.removeAll { $0.id == request.id }
            allowed.append(AllowedAgent(identity: request.identity, allowed: Date(), maySelect: answer == .allow))
            refused.remove(request.id)
            save()
        }
        note(request.identity, answer == .allow ? "Allowed" : (answer == .lookOnly ? "Allowed to look" : "Not allowed"))
        settle(request.id, answer != .deny)
    }

    /// Whether an agent you allowed may select things, or only look.
    func maySelect(_ identity: AgentIdentity) -> Bool {
        allowed.first { $0.id == identity.key }?.maySelect ?? false
    }

    func setMaySelect(_ agent: AllowedAgent, _ may: Bool) {
        guard let at = allowed.firstIndex(where: { $0.id == agent.id }), allowed[at].maySelect != may else { return }
        allowed[at].maySelect = may
        save()
        note(agent.identity, may ? "Allowed to select" : "Allowed to look only")
    }

    /// Takes back what you allowed. An agent that's connected gets no more answers, and has to ask again.
    func remove(_ agent: AllowedAgent) {
        allowed.removeAll { $0.id == agent.id }
        save()
        note(agent.identity, "Removed")
    }

    // MARK: What they did

    func note(_ identity: AgentIdentity, _ what: String) {
        activity.append(AgentActivity(date: Date(), agent: identity.name, what: what))
        if activity.count > Self.longestActivity { activity.removeFirst(activity.count - Self.longestActivity) }
    }

    /// An allowed agent asked for something, and got it.
    func used(_ identity: AgentIdentity, _ what: String) {
        note(identity, what)
        guard let at = allowed.firstIndex(where: { $0.id == identity.key }) else { return }
        // Written down at most once a minute: it's only for the list.
        let last = allowed[at].lastUsed
        allowed[at].lastUsed = Date()
        if last.map({ Date().timeIntervalSince($0) > 60 }) ?? true { save() }
    }

    private func save() {
        guard let file else { return }
        Saves.write(allowed, to: file)
    }
}
