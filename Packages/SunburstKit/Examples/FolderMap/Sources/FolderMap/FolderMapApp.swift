import AppKit
import SunburstAgents
import SunburstKit
import SwiftUI

/// Shows a folder as a sunburst. It starts with a made-up sample; Open Folder… reads a real one. Agents… lets AI agents
/// look at the chart and point at things on it, once you allow them.
///
///     swift run                          the window
///     swift run FolderMap --folder ~/Projects
///     swift run FolderMap --picture ring.png   a picture of the sample, without a window
///     .build/debug/FolderMap --mcp       what an agent starts to reach the app (see `main.swift`)
struct FolderMapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = Model()

    var body: some Scene {
        WindowGroup {
            Sunburst(model.chart)
                .frame(minWidth: 760, minHeight: 520)
                .navigationTitle(model.title)
                .toolbar {
                    Button("Sample") { model.showSample() }
                    Button("Open Folder…") { model.chooseFolder() }
                    AgentsButton(model: model)
                }
                .agentQuestion(model.door)
                .task {
                    if let path = Model.argument("--folder") { await model.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) }
                }
        }
        Window("Agents", id: "agents") {
            AgentAccessView(model.door)
                .frame(minWidth: 460, minHeight: 360)
        }
    }
}

/// Opens the door for agents, which stays shut until you ask, and shows who's asking and what they did.
struct AgentsButton: View {
    let model: Model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Agents…") {
            model.door.open()
            openWindow(id: "agents")
        }
    }
}

extension AgentHost {
    /// What agents are told about the app, and the tools they get: the chart's own.
    static let folderMap = AgentHost(
        name: "FolderMap", version: "1.0",
        instructions: "FolderMap shows a folder as a sunburst. Call chart_summary to see what's on it, chart_picture to look at it, and chart_highlight to point something out to the user.",
        folder: URL.applicationSupportDirectory.appendingPathComponent("FolderMap"),
        tools: SunburstAgentTools.tools)
}

@MainActor
@Observable
final class Model {
    let chart: SunburstChart<FileTree>
    /// Agents' way in. Shut until Agents… opens it.
    @ObservationIgnored private(set) lazy var door = AgentDoor(.folderMap) { [unowned self] call in
        try SunburstAgentTools.answer(call, chart: self.chart)
    }
    private(set) var title = "Sample"

    init() {
        chart = Model.chart(of: FileTree.sample())
    }

    /// A chart of a tree, naming each piece from it.
    static func chart(of tree: FileTree) -> SunburstChart<FileTree> {
        let chart = SunburstChart(tree: tree, name: { _ in "" })
        chart.name = { [unowned chart] node in chart.tree.name(node) }
        return chart
    }

    func showSample() {
        title = "Sample"
        chart.show(FileTree.sample())
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await open(url) }
    }

    func open(_ url: URL) async {
        title = "Reading \(url.lastPathComponent)…"
        let tree = await Task.detached(priority: .userInitiated) { FileTree.read(url) }.value
        title = url.lastPathComponent
        chart.show(tree)
    }

    static func argument(_ name: String) -> String? {
        let all = CommandLine.arguments
        guard let at = all.firstIndex(of: name), at + 1 < all.count else { return nil }
        return all[at + 1]
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let path = Model.argument("--picture") { return MainActor.assumeIsolated { writePicture(to: path) } }
        // Run from Terminal, the app still gets a Dock icon and comes to the front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The sample's ring as a PNG, then quits: no window needed.
    @MainActor
    private func writePicture(to path: String) {
        let chart = Model.chart(of: FileTree.sample())
        guard let image = chart.picture(width: 1600, height: 1200),
              let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else {
            print("no picture: this Mac has no GPU to draw with")
            exit(1)
        }
        CGImageDestinationAddImage(out, image, nil)
        let written = CGImageDestinationFinalize(out)
        print(written ? "wrote \(path)" : "couldn't write \(path)")
        exit(written ? 0 : 1)
    }
}
