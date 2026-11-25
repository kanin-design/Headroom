import AppKit
import SwiftUI

extension NSApplication {
    /// Quits once this turn of the run loop is over, as the Quit menu does, rather than from inside a task. A quit that has
    /// to wait, for a clean to stop or a new version to go in place, waits in a run loop of its own, and work on the main
    /// actor can only go on there when the quit didn't start inside some.
    func terminateSoon() {
        perform(#selector(terminate(_:)), with: nil, afterDelay: 0)
    }
}

extension [String] {
    /// What follows a flag on the command line: `--script steps.txt` gives `steps.txt`.
    func value(after flag: String) -> String? {
        guard let at = firstIndex(of: flag), at + 1 < count else { return nil }
        return self[at + 1]
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        Scanner.askForEnoughOpenFiles()
        if ScriptRunner.path != nil {
            // Checking itself: stay out of the way of whatever you're doing.
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        ScriptRunner.startIfAsked()
        Updater.shared.checkAtLaunch()
        AgentServer.door.open()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AgentServer.door.close() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A clean, or emptying the Trash, stops at the next safe point and writes down where it got to, so what's in the Trash
    /// stays on record and a clean can still be undone. Putting a clean back finishes first. If a new version is going into
    /// place at the same time, the quit waits for that too: see `AppModel.quitWhenNothingIsLeft`.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        // Halfway through swapping in a new version, the app could be left in the Trash with the new one not yet in place.
        let installing = Updater.shared.isInstalling
        if installing { Updater.shared.quitWhenInPlace = true }
        guard model.isCleaning else {
            if installing { return .terminateLater }
            model.savePlan()
            return .terminateNow
        }
        model.quitAfterClean = true
        model.stopCleaning()
        model.driveJob?.stop.value = true
        return .terminateLater
    }
}

/// The pointer can't be on anything else while it's in the menu bar, so this says what it would send. As a view of its own,
/// it follows the folder you're in.
private struct SendToTrashCommand: View {
    let model = AppModel.shared

    var body: some View {
        let node = model.selected ?? model.focus
        // The same rule as the Delete submenu on the thing itself: what's protected stays, and says so by being off.
        Button(model.trashTitle) { model.sendToTrash(NamedThing(node)) }
            .disabled(!model.canSendToTrash(node))
    }
}

/// How many rings the map draws, and how wide each is. More rings reach deeper into folders. The tick is on how many the
/// picture has now, and numbers it couldn't fill are off.
/// View › Sort By, with the Finder's keys for the same orders.
private struct SortCommand: View {
    let model = AppModel.shared

    var body: some View {
        Menu("Sort By") {
            Toggle("Name", isOn: Binding(get: { model.sortBy == .name }, set: { _ in model.sortBy = .name }))
                .keyboardShortcut("1", modifiers: [.control, .option, .command])
            Toggle("Size", isOn: Binding(get: { model.sortBy == .size }, set: { _ in model.sortBy = .size }))
                .keyboardShortcut("7", modifiers: [.control, .option, .command])
        }
    }
}

private struct RingsCommand: View {
    let model = AppModel.shared

    var body: some View {
        Menu("Rings") {
            ForEach(1...RingSizes.most, id: \.self) { count in
                Toggle("\(count)", isOn: Binding(get: { model.ringsDrawn == count }, set: { _ in model.ringSizes.depth = count }))
                    .disabled(count > model.ringReach)
            }
            Divider()
            ForEach(RingStyle.allCases, id: \.self) { style in
                Toggle(Self.title(style), isOn: Binding(get: { model.ringSizes.style == style }, set: { _ in model.ringSizes.style = style }))
            }
        }
    }

    private static func title(_ style: RingStyle) -> String {
        switch style {
        case .standard: "Standard Widths"
        case .tapered: "Tapered Widths"
        case .adaptive: "Adaptive Widths"
        }
    }
}

/// The map's colours: SunburstKit's palettes, generated ones first, then fixed sets.
private struct PaletteCommand: View {
    let model = AppModel.shared

    var body: some View {
        Menu("Palette") {
            ForEach(SunburstPalette.all) { palette in
                Toggle(palette.name, isOn: Binding(get: { model.palette == palette }, set: { _ in model.palette = palette }))
            }
        }
    }
}

/// Whether the map glows.
private struct GlowCommand: View {
    let model = AppModel.shared

    var body: some View {
        Toggle("Glow", isOn: Binding(get: { model.showsGlow }, set: { model.showsGlow = $0 }))
    }
}

/// Whether a search also finds small files, which aren't on the map. Their names are kept in a catalogue of their own.
private struct SmallFilesCommand: View {
    let model = AppModel.shared

    var body: some View {
        Toggle("Search Small Files", isOn: Binding(get: { model.searchesSmallFiles }, set: { model.setSearchesSmallFiles($0) }))
            .help("Also find files under 1 MiB, which aren't on the map")
    }
}

/// Up to the folder this one is in, as in the Finder. Like Esc, it lets go of what's selected first.
private struct EnclosingFolderCommand: View {
    let model = AppModel.shared

    var body: some View {
        Button("Enclosing Folder") { model.goToEnclosingFolder() }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(model.focus == 0 && model.selected == nil)
    }
}

/// Files moved to a drive, drawn where they were from the notes they left. They're shown in Backup.
private struct ShowMovedFilesCommand: View {
    let model = AppModel.shared

    var body: some View {
        Toggle("Show Moved Files", isOn: Binding(get: { model.showGhosts }, set: { model.setShowGhosts($0) }))
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(model.movedNotes.isEmpty && !model.showGhosts)
    }
}

/// A menu item that opens one of the app's windows, after doing `first`.
private struct OpenWindowCommand: View {
    let title: String
    let id: String
    var first: () -> Void = {}
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            first()
            openWindow(id: id)
        }
    }
}

extension Scene {
    /// A small window of its own: no title bar, its content's size, dragged by its background, opened only when asked for,
    /// in the middle of the screen, and with no menu commands of its own.
    fileprivate func smallWindow() -> some Scene {
        windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
            .windowBackgroundDragBehavior(.enabled)
            .restorationBehavior(.disabled)
            .defaultLaunchBehavior(.suppressed)
            .defaultPosition(.center)
            .commandsRemoved()
    }
}

struct HeadroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Headroom", id: "main") {
            RootView()
                .frame(minWidth: 860, minHeight: 620)
                // A scripted check stays behind whatever you're doing, and its clicks have to count anyway.
                .allowsWindowActivationEvents(ScriptRunner.path != nil ? true : nil)
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1440, height: 900)
        // The window opens where you left it, as big as you left it. A scripted check opens at the default size and saves
        // neither, so resizing or moving its window can't change yours.
        .restorationBehavior(AppModel.remembersWindow ? .automatic : .disabled)
        .commands {
            CommandGroup(replacing: .appInfo) {
                OpenWindowCommand(title: "About Headroom", id: "about")
                OpenWindowCommand(title: "Check for Updates…", id: "update") { Updater.shared.checkNow() }
                OpenWindowCommand(title: "Agents…", id: "agents")
            }
            CommandGroup(replacing: .newItem) {
                Button("Scan Again") { AppModel.shared.scan(hurry: true) }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Open") { AppModel.shared.open(AppModel.shared.actionTarget) }
                    .keyboardShortcut(.openThing)
                Button("Show in Finder") { AppModel.shared.reveal(AppModel.shared.actionTarget) }
                    .keyboardShortcut(.revealThing)
                Button("Quick Look") { AppModel.shared.toggleLook() }
                    .keyboardShortcut(.quickLook)
                Divider()
                Menu("Delete") {
                    SendToTrashCommand()
                    Divider()
                    Button("Select or Deselect in Free Up") { AppModel.shared.selectCommand() }
                        .keyboardShortcut(.selectThing)
                }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { AppModel.shared.undoCommand() }
                    .keyboardShortcut("z")
                Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            // These are the usual ones, with the name and the path where a file manager has them. ⌘C still copies selected text.
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                    .keyboardShortcut("x")
                Button("Copy Name") { AppModel.shared.copyCommand() }
                    .keyboardShortcut(.copyName)
                Button("Copy Path") { AppModel.shared.copyPath(of: AppModel.shared.actionTarget) }
                    .keyboardShortcut(.copyPath)
                Button("Copy List") { AppModel.shared.copyList() }
                    .keyboardShortcut(.copyList)
                Button("Paste") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                    .keyboardShortcut("v")
                Button("Select All") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                    .keyboardShortcut("a")
            }
            CommandGroup(after: .toolbar) {
                Button("Map") { AppModel.shared.setLens(.map) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Changes") { AppModel.shared.setLens(.changes) }
                    .keyboardShortcut("2", modifiers: .command)
                Button(AppModel.shared.mode == .backup ? "Backed Up" : "Copies") { AppModel.shared.setLens(.copies) }
                    .keyboardShortcut("3", modifiers: .command)
                Divider()
                Button("Free Up") { AppModel.shared.setLens(.freeUp) }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Backup") { AppModel.shared.setLens(.backup) }
                    .keyboardShortcut("5", modifiers: .command)
                ShowMovedFilesCommand()
                Divider()
                Button("Back") { AppModel.shared.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { AppModel.shared.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                EnclosingFolderCommand()
                Button("Back to the Whole Disk") { AppModel.shared.go(to: 0) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                SortCommand()
                RingsCommand()
                PaletteCommand()
                GlowCommand()
                Divider()
            }
            // Help is the README, where everything is explained. There's no sidebar to toggle.
            CommandGroup(replacing: .help) {
                Button("Headroom Help") { NSWorkspace.shared.open(Updater.readme) }
                    .keyboardShortcut("?", modifiers: .command)
            }
            CommandGroup(replacing: .sidebar) {}
            // Show Inspector and Hide Inspector, on ⌃⌘I: SwiftUI's own, the way ⌃⌘S shows and hides a sidebar.
            InspectorCommands()
            // Show or Hide Toolbar, as in any Mac app.
            ToolbarCommands()
            CommandGroup(after: .textEditing) {
                Button("Find") {
                    AppModel.shared.searchActive = true
                    AppModel.shared.showPanel(true)
                }
                .keyboardShortcut("f", modifiers: .command)
                SmallFilesCommand()
            }
        }

        Window("About Headroom", id: "about") {
            AboutView()
                .windowMinimizeBehavior(.disabled)
                .windowResizeBehavior(.disabled)
                .windowFullScreenBehavior(.disabled)
        }
        .smallWindow()

        Window("Agents", id: "agents") {
            AgentsView()
                .windowMinimizeBehavior(.disabled)
                .windowFullScreenBehavior(.disabled)
        }
        .smallWindow()

        Window("Full Disk Access", id: "access") {
            AccessGuideView()
                .windowMinimizeBehavior(.disabled)
                .windowResizeBehavior(.disabled)
                .windowFullScreenBehavior(.disabled)
        }
        .smallWindow()

        Window("Update Headroom", id: "update") {
            UpdateView()
                .windowMinimizeBehavior(.disabled)
                .windowResizeBehavior(.disabled)
                .windowFullScreenBehavior(.disabled)
        }
        .smallWindow()
    }
}
