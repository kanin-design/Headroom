import AppKit
import SwiftUI

/// What the question and the list both say about an agent: the program behind it, and who signed that.
enum AgentText {
    static func origin(_ identity: AgentIdentity) -> String {
        "Started by \(identity.programName). " + (identity.signer.map { "Signed by \($0)." } ?? "Not signed by a known developer.")
    }

    /// The same in a list: the program, and who signed it.
    static func originLabel(_ identity: AgentIdentity) -> String {
        identity.programName + "  ·  " + (identity.signer ?? "Unsigned")
    }

    static let whatAllowingMeans = "It can see the names and sizes of your files and folders, and select them for Free Up or Backup. Only you can clean or move them."

    /// The command an agent is given to reach this copy of Headroom.
    static var command: String {
        let program = Bundle.main.executablePath ?? "/Applications/Headroom.app/Contents/MacOS/Headroom"
        return (program.contains(" ") ? "\"\(program)\"" : program) + " --mcp"
    }
}

/// Asks about an agent that wants in, one at a time. It has no size of its own: it only carries the question.
struct AgentQuestion: View {
    private let agents = Agents.shared

    var body: some View {
        let request = agents.requests.first
        Color.clear
            .frame(width: 0, height: 0)
            .alert("“\(request?.identity.name ?? "An agent")” would like to work with Headroom",
                   isPresented: Binding(get: { request != nil }, set: { _ in }), presenting: request) { request in
                Button("Allow") { agents.answer(request, .allow) }
                Button("Look Only") { agents.answer(request, .lookOnly) }
                Button("Don’t Allow", role: .cancel) { agents.answer(request, .deny) }
            } message: { request in
                Text(AgentText.origin(request.identity) + "\n\n" + AgentText.whatAllowingMeans)
            }
    }
}

/// On the map while an agent is connected: who, and a way to the list.
struct AgentsConnected: View {
    @Environment(\.openWindow) private var openWindow
    private let agents = Agents.shared

    var body: some View {
        let names = Self.names(agents.connected.map(\.identity.name))
        if !names.isEmpty {
            Button { openWindow(id: "agents") } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Kit.green)
                        .frame(width: 6, height: 6)
                    Text(names + " connected")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(maxWidth: .infinity)
            if agents.allowed.isEmpty && agents.connected.isEmpty {
                Text("No agents")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
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
                            PillPicker(options: [true, false], selection: one.maySelect, title: { $0 ? "Look and select" : "Look only" },
                                       help: { $0 ? "Let it select files for Free Up and Backup" : "Let it only look" },
                                       fills: false, height: 22) { agents.setMaySelect(one, $0) }
                            Button("Remove") { agents.remove(one) }
                                .buttonStyle(.pill)
                                .help("Take back its access")
                        }
                    }
                }
            }
            section("MCP server command") {
                HStack(spacing: 8) {
                    Text(AgentText.command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, Kit.rowInset)
                        .frame(height: 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Kit.rowRadius, style: .continuous).fill(Kit.cardFill))
                        .overlay(RoundedRectangle(cornerRadius: Kit.rowRadius, style: .continuous).strokeBorder(Kit.cardStroke))
                    Button(copied ? "Copied" : "Copy") {
                        AppModel.clipboard.clearContents()
                        AppModel.clipboard.setString(AgentText.command, forType: .string)
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
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(one.date, format: .dateTime.hour().minute().second())
                                        .foregroundStyle(Kit.tertiary)
                                        .monospacedDigit()
                                    Text(one.agent)
                                        .foregroundStyle(Kit.secondary)
                                    Text(one.what)
                                        .foregroundStyle(.white.opacity(0.82))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .font(.system(size: 11))
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
        .frame(width: 460, alignment: .leading)
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

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            content()
        }
    }

    private func row<Trailing: View>(_ identity: AgentIdentity, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(identity.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Text(AgentText.originLabel(identity))
                    .font(.system(size: 11))
                    .foregroundStyle(Kit.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(identity.program)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Kit.tertiary)
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}
