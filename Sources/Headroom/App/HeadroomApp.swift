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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A clean, or emptying the Trash, stops at the next safe point and writes down where it got to, so what's in the Trash
    /// stays on record and a clean can still be undone. Putting a clean back finishes first.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Halfway through swapping in a new version, the app could be left in the Trash with the new one not yet in place.
        if Updater.shared.isInstalling {
            Updater.shared.quitWhenInPlace = true
            return .terminateLater
        }
        let model = AppModel.shared
        guard model.isCleaning else {
            model.savePlan()
            return .terminateNow
        }
        model.quitAfterClean = true
        model.stopCleaning()
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

private struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Headroom") { openWindow(id: "about") }
    }
}

private struct UpdateCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Check for Updates…") {
            Updater.shared.checkNow()
            openWindow(id: "update")
        }
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
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutCommand()
                UpdateCommand()
            }
            CommandGroup(replacing: .newItem) {
                Button("Scan Again") { AppModel.shared.scan(hurry: true) }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Open") { AppModel.shared.open(AppModel.shared.actionTarget) }
                    .keyboardShortcut(.openThing)
                Button("Reveal in Finder") { AppModel.shared.reveal(AppModel.shared.actionTarget) }
                    .keyboardShortcut(.revealThing)
                Button("Quick Look") { AppModel.shared.toggleLook() }
                    .keyboardShortcut(.quickLook)
                Divider()
                Menu("Delete") {
                    SendToTrashCommand()
                    Divider()
                    Button("Select or Unselect in Free Up") { AppModel.shared.selectCommand() }
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
                Button("Free Up") { AppModel.shared.setLens(.freeUp) }
                    .keyboardShortcut("3", modifiers: .command)
                Divider()
                Button("Back") { AppModel.shared.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { AppModel.shared.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Back to the Whole Disk") { AppModel.shared.go(to: 0) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                Button("Show or Hide Panel") { AppModel.shared.panelOpen.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                RingsCommand()
                Divider()
            }
            // Help is the README, where everything is explained. There's no sidebar to toggle.
            CommandGroup(replacing: .help) {
                Button("Headroom Help") { NSWorkspace.shared.open(Updater.readme) }
                    .keyboardShortcut("?", modifiers: .command)
            }
            CommandGroup(replacing: .sidebar) {}
            CommandGroup(after: .textEditing) {
                Button("Find") {
                    AppModel.shared.searchActive = true
                    AppModel.shared.panelOpen = true
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }

        Window("About Headroom", id: "about") {
            AboutView()
                .windowMinimizeBehavior(.disabled)
                .windowResizeBehavior(.disabled)
                .windowFullScreenBehavior(.disabled)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .defaultPosition(.center)
        .commandsRemoved()

        Window("Full Disk Access", id: "access") {
            AccessGuideView()
                .windowMinimizeBehavior(.disabled)
                .windowResizeBehavior(.disabled)
                .windowFullScreenBehavior(.disabled)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .defaultPosition(.center)
        .commandsRemoved()

        Window("Update Headroom", id: "update") {
            UpdateView()
                .windowMinimizeBehavior(.disabled)
                .windowResizeBehavior(.disabled)
                .windowFullScreenBehavior(.disabled)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .defaultPosition(.center)
        .commandsRemoved()
    }
}
