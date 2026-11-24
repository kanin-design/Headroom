import SwiftUI

/// What the question and the list say about an agent.
private enum AgentText {
    /// The program behind an agent in a list, and who signed it.
    static func originLabel(_ identity: AgentIdentity) -> String {
        identity.programName + "  ·  " + (identity.signer ?? "Unsigned")
    }

    static let whatAllowingMeans =
        "It can see the names and sizes of your files and folders, and select them for Free Up or Backup. Only you can clean or move them."
}

/// Asks about an agent that wants in, one at a time, with the question SunburstAgents asks. It has no size of its own: it
/// only carries the question.
struct AgentQuestion: View {
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .agentQuestion(AgentServer.door, explaining: AgentText.whatAllowingMeans)
    }
}

/// On the map while an agent is connected: who, and a way to the list.
struct AgentsConnected: View {
    @Environment(\.openWindow) private var openWindow
    private let agents = Agents.shared

    var body: some View {
        let names = Self.names(agents.connected.map(\.identity.name))
        if !names.isEmpty {
            Button {
                openWindow(id: "agents")
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Kit.green)
                        .frame(width: 6, height: 6)
                    Text(names + " connected")
                        .font(Kit.Font.name)
                        .foregroundStyle(Kit.Text.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, Kit.Space.large)
                .frame(height: 26)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Capsule())
            .help("Agents")
            .transition(.opacity)
        }
    }

    /// Each name once, and a count past two.
    static func names(_ all: [String]) -> String {
        var seen: [String] = []
        for name in all where !seen.contains(name) { seen.append(name) }
        switch seen.count {
        case 0: return ""
        case 1, 2: return seen.joined(separator: " and ")
        default: return "\(seen[0]) and \(seen.count - 1) more"
        }
    }
}

/// Agents, in the app menu: which are connected, which you've allowed, and what they asked for. Drawn like About and the
/// other small windows: no title bar, the app's own text colours, pills for its buttons.
struct AgentsView: View {
    private let agents = Agents.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Agents")
                .font(Kit.Font.title)
                .foregroundStyle(Kit.Text.primary)
                .frame(maxWidth: .infinity)
            if agents.allowed.isEmpty && agents.connected.isEmpty {
                Text("No agents")
                    .font(Kit.Font.note)
                    .foregroundStyle(Kit.Text.primary)
            }
            if !agents.connected.isEmpty {
                section("Connected") {
                    ForEach(agents.connected) { one in
                        row(one.identity, detail: standing(one.identity)) { EmptyView() }
                    }
                }
            }
            if !agents.allowed.isEmpty {
                section("Allowed") {
                    ForEach(agents.allowed) { one in
                        row(one.identity, detail: one.lastUsed.map { "Last used \(LastUse.ago($0, now: Date()))" } ?? "Not used yet") {
                            Segmented(
                                name: "Access", options: [true, false], selection: one.maySelect, title: { $0 ? "Look and select" : "Look only" },
                                help: { $0 ? "Let it select files for Free Up and Backup" : "Let it only look" }
                            ) { agents.setMaySelect(one, $0) }
                            Button("Remove") { agents.remove(one) }
                                .buttonStyle(.pill)
                                .help("Take back its access")
                        }
                    }
                }
            }
            section("MCP server command") {
                HStack(spacing: Kit.Space.regular) {
                    Text(AgentDoor.command)
                        .font(Kit.Font.detail)
                        .fontDesign(.monospaced)
                        .foregroundStyle(Kit.Text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, Kit.rowInset)
                        .frame(height: 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(radius: Kit.Radius.row)
                    Button(copied ? "Copied" : "Copy") {
                        AppModel.clipboard.clearContents()
                        AppModel.clipboard.setString(AgentDoor.command, forType: .string)
                        copied = true
                    }
                    .buttonStyle(.pill)
                }
                .help("Add to an agent as an MCP server")
            }
            if !agents.activity.isEmpty {
                section("Activity") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(agents.activity.reversed()) { one in
                                HStack(alignment: .firstTextBaseline, spacing: Kit.Space.regular) {
                                    Text(one.date, format: .dateTime.hour().minute().second())
                                        .foregroundStyle(Kit.Text.tertiary)
                                        .monospacedDigit()
                                    Text(one.agent)
                                        .foregroundStyle(Kit.Text.tertiary)
                                    Text(one.what)
                                        .foregroundStyle(Kit.Text.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .font(Kit.Font.detail)
                                .frame(height: 14)
                            }
                        }
                    }
                    // A scrolling list has no height of its own: as tall as its lines, up to ten of them.
                    .frame(height: min(CGFloat(agents.activity.count), 10) * 17)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 24)
        .frame(width: 480, alignment: .leading)
        .containerBackground(Palette.window, for: .window)
        .preferredColorScheme(.dark)
    }

    private func standing(_ identity: AgentIdentity) -> String {
        switch agents.standing(of: identity) {
        case .allowed: "Allowed"
        case .refused: "Not allowed"
        case .asking: "Waiting"
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: @escaping () -> Content) -> some View {
        PanelSection(title: title, inset: 0, spacing: Kit.Space.regular, content: content)
    }

    /// Not a `ListRow`: an agent has three lines, its name, its program and when it was last used, and controls at the end.
    private func row<Trailing: View>(_ identity: AgentIdentity, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: Kit.rowInset) {
            VStack(alignment: .leading, spacing: Kit.Space.tight) {
                Text(identity.name)
                    .font(Kit.Font.name)
                    .foregroundStyle(Kit.Text.primary)
                Text(AgentText.originLabel(identity))
                    .font(Kit.Font.detail)
                    .foregroundStyle(Kit.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(identity.program)
                Text(detail)
                    .font(Kit.Font.detail)
                    .foregroundStyle(Kit.Text.tertiary)
            }
            // Its words are laid out first; the controls take what's left.
            .lineLimit(1)
            .layoutPriority(1)
            Spacer(minLength: 0)
            trailing()
        }
    }
}
