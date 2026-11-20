import AppKit
import Foundation
import Observation

/// An agent the user allowed, and when.
public struct AllowedAgent: Codable, Identifiable, Equatable, Sendable {
    public var identity: AgentIdentity
    /// When the user allowed it.
    public var allowed: Date
    /// When it last asked for something, if it has.
    public var lastUsed: Date?
    /// Whether it may call the tools that change what's shown or selected (`AgentTool.selects`), or only look.
    public var maySelect = false
    public var id: String { identity.key }

    public init(identity: AgentIdentity, allowed: Date, maySelect: Bool) {
        self.identity = identity
        self.allowed = allowed
        self.maySelect = maySelect
    }

    /// One saved before agents could be allowed to select was allowed to look, and that's what it keeps.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identity = try values.decode(AgentIdentity.self, forKey: .identity)
        allowed = try values.decode(Date.self, forKey: .allowed)
        lastUsed = try values.decodeIfPresent(Date.self, forKey: .lastUsed)
        maySelect = try values.decodeIfPresent(Bool.self, forKey: .maySelect) ?? false
    }
}

/// What the user can say to an agent that asks.
public enum AgentDecision: Sendable {
    /// It may look and call every tool.
    case allow
    /// It may look: tools that select or change what's shown are refused.
    case lookOnly
    /// It gets nothing, and isn't asked about again until the app is opened again.
    case deny
}

/// An agent waiting for the user's answer.
public struct AgentRequest: Identifiable, Equatable, Sendable {
    public var identity: AgentIdentity
    public var id: String { identity.key }
}

/// An agent that's connected now.
public struct ConnectedAgent: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var identity: AgentIdentity
    /// When it connected.
    public var since: Date
}

/// Something an agent asked for, or something the user decided about it.
public struct AgentActivity: Identifiable, Equatable, Sendable {
    public var id = UUID()
    /// When it asked.
    public var date: Date
    /// The agent's name.
    public var agent: String
    /// What it asked for, in a line.
    public var what: String
}

/// Which agents may use the app. Nothing is answered until the user has allowed the agent that asks, and what they allowed
/// is remembered, in the door's folder, until they remove it.
///
/// Show it in the app with `AgentAccessView` and `agentQuestion(_:)`, or with views of your own: it's observable.
@MainActor
@Observable
public final class Agents {
    /// Agents the user allowed, in the order they were allowed.
    public private(set) var allowed: [AllowedAgent] = []
    /// Agents waiting for the user's answer, first come first.
    public private(set) var requests: [AgentRequest] = []
    /// Agents connected now. One agent may be connected more than once.
    public private(set) var connected: [ConnectedAgent] = []
    /// What agents asked for and what the user decided, oldest first, the last `longestActivity` of it.
    public private(set) var activity: [AgentActivity] = []

    /// Turned down since the app started. It isn't asked about again until the app is opened again.
    @ObservationIgnored private var refused: Set<String> = []
    @ObservationIgnored private var waiting: [String: [UUID: CheckedContinuation<Bool?, Never>]] = [:]
    @ObservationIgnored private let file: URL?

    /// How long a call waits for the user's answer before the agent is told to try again.
    public nonisolated static let patience: Duration = .seconds(90)
    /// As much as the list of what agents did holds.
    public static let longestActivity = 200

    /// The list saved in `file`, if there is one. Without a file nothing is remembered past this run.
    init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([AllowedAgent].self, from: data) {
            allowed = saved
        }
    }

    /// Where an agent stands with the user.
    public enum Standing: Sendable { case allowed, refused, asking }

    /// Whether this agent is allowed, was turned down since the app started, or hasn't been answered about.
    public func standing(of identity: AgentIdentity) -> Standing {
        if allowed.contains(where: { $0.id == identity.key }) { return .allowed }
        return refused.contains(identity.key) ? .refused : .asking
    }

    // MARK: Connections

    /// An agent has connected and said who it is. One the user hasn't answered about yet is put to them.
    func arrived(_ id: UUID, _ identity: AgentIdentity) {
        connected.removeAll { $0.id == id }
        connected.append(ConnectedAgent(id: id, identity: identity, since: Date()))
        ask(about: identity)
    }

    /// Puts an agent to the user, if they haven't answered about it and aren't being asked already.
    private func ask(about identity: AgentIdentity) {
        guard standing(of: identity) == .asking, !requests.contains(where: { $0.id == identity.key }) else { return }
        requests.append(AgentRequest(identity: identity))
        // In the Dock, when the app isn't in front: a question is waiting.
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

    /// Whether this agent may have an answer: true or false once the user has said, nil if they haven't within `patience`.
    func mayAnswer(_ identity: AgentIdentity, patience: Duration = Agents.patience) async -> Bool? {
        switch standing(of: identity) {
        case .allowed: return true
        case .refused: return false
        case .asking: break
        }
        // One allowed and then removed asks again, as a new one would.
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

    /// The user's answer to an agent that asked. A call that's waiting for it goes on at once.
    public func answer(_ request: AgentRequest, _ decision: AgentDecision) {
        requests.removeAll { $0.id == request.id }
        if decision == .deny {
            refused.insert(request.id)
        } else {
            allowed.removeAll { $0.id == request.id }
            allowed.append(AllowedAgent(identity: request.identity, allowed: Date(), maySelect: decision == .allow))
            refused.remove(request.id)
            save()
        }
        note(request.identity, decision == .allow ? "Allowed" : (decision == .lookOnly ? "Allowed to look" : "Not allowed"))
        settle(request.id, decision != .deny)
    }

    /// Whether an agent the user allowed may select things, or only look.
    public func maySelect(_ identity: AgentIdentity) -> Bool {
        allowed.first { $0.id == identity.key }?.maySelect ?? false
    }

    /// Lets an allowed agent select, or only look.
    public func setMaySelect(_ agent: AllowedAgent, _ may: Bool) {
        guard let at = allowed.firstIndex(where: { $0.id == agent.id }), allowed[at].maySelect != may else { return }
        allowed[at].maySelect = may
        save()
        note(agent.identity, may ? "Allowed to select" : "Allowed to look only")
    }

    /// Takes back what the user allowed. An agent that's connected gets no more answers, and has to ask again.
    public func remove(_ agent: AllowedAgent) {
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

    /// Written whole each time, in place of the file before: the list is a few lines long.
    private func save() {
        guard let file, let data = try? JSONEncoder().encode(allowed) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
