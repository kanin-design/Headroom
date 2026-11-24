import AppKit
import SwiftUI

extension View {
    /// Asks the user about each agent that wants in, one at a time, in an alert: Allow, Look Only or Don't Allow. Put it on
    /// the app's main window, so the question is there when an agent asks. `explaining` says what allowing an agent lets it
    /// do; by default, that it can see what the app shows and use its tools.
    public func agentQuestion(_ door: AgentDoor, explaining: String? = nil) -> some View {
        modifier(
            AgentQuestion(
                agents: door.agents, app: door.host.name,
                explaining: explaining
                    ?? "It can see what \(door.host.name) shows and use its tools. With Look Only, it can see but not change anything."))
    }
}

/// The question about the first agent waiting for an answer.
struct AgentQuestion: ViewModifier {
    let agents: Agents
    let app: String
    let explaining: String

    func body(content: Content) -> some View {
        let request = agents.requests.first
        content
            .alert(
                "“\(request?.identity.name ?? "An agent")” would like to work with \(app)",
                isPresented: Binding(get: { request != nil }, set: { _ in }), presenting: request
            ) { request in
                Button("Allow") { agents.answer(request, .allow) }
                Button("Look Only") { agents.answer(request, .lookOnly) }
                Button("Don’t Allow", role: .cancel) { agents.answer(request, .deny) }
            } message: { request in
                Text(request.identity.origin + "\n\n" + explaining)
            }
    }
}

/// The agents a door knows, for a window or a Settings tab: who's asking, who's allowed and whether each may select or
/// only look, who's connected, what they did, and the command that reaches the app. Plain controls, in a grouped form.
public struct AgentAccessView: View {
    private let door: AgentDoor
    @State private var copied = false

    public init(_ door: AgentDoor) {
        self.door = door
    }

    public var body: some View {
        let agents = door.agents
        Form {
            if !agents.requests.isEmpty {
                Section("Asking") {
                    ForEach(agents.requests) { request in
                        HStack {
                            label(request.identity)
                            Spacer(minLength: 12)
                            Button("Don’t Allow") { agents.answer(request, .deny) }
                            Button("Look Only") { agents.answer(request, .lookOnly) }
                            Button("Allow") { agents.answer(request, .allow) }
                        }
                    }
                }
            }
            Section("Allowed") {
                if agents.allowed.isEmpty {
                    Text("No agents")
                        .foregroundStyle(.secondary)
                }
                ForEach(agents.allowed) { one in
                    HStack {
                        label(
                            one.identity,
                            detail: one.lastUsed.map { Text("Last used \($0, format: .relative(presentation: .named))") }
                                ?? Text("Not used yet"))
                        Spacer(minLength: 12)
                        Picker("Access", selection: Binding(get: { one.maySelect }, set: { agents.setMaySelect(one, $0) })) {
                            Text("Look and select").tag(true)
                            Text("Look only").tag(false)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help("Whether it can select, or only look")
                        Button("Remove") { agents.remove(one) }
                            .help("Take back its access")
                    }
                }
            }
            if !agents.connected.isEmpty {
                Section("Connected") {
                    ForEach(agents.connected) { one in
                        label(one.identity, detail: Text(standing(agents.standing(of: one.identity))))
                    }
                }
            }
            Section("MCP server command") {
                HStack {
                    Text(AgentDoor.command)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 12)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(AgentDoor.command, forType: .string)
                        copied = true
                    }
                }
                .help("Add to an agent as an MCP server")
            }
            if !agents.activity.isEmpty {
                Section("Activity") {
                    ForEach(agents.activity.reversed()) { one in
                        HStack(alignment: .firstTextBaseline) {
                            Text(one.date, format: .dateTime.hour().minute().second())
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(one.agent)
                                .foregroundStyle(.secondary)
                            Text(one.what)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func standing(_ standing: Agents.Standing) -> String {
        switch standing {
        case .allowed: "Allowed"
        case .refused: "Not allowed"
        case .asking: "Waiting"
        }
    }

    private func label(_ identity: AgentIdentity, detail: Text? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(identity.name)
            Text(identity.programName + "  ·  " + (identity.signer ?? "Unsigned"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(identity.program)
            if let detail {
                detail
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
