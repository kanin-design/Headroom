import AppKit
import SwiftUI

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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A clean under way stops at the next safe point and writes down what it did, so it can still be undone.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard model.cleanProgress != nil else {
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
        Button(model.trashTitle) { model.sendToTrash(NamedThing(node)) }
            .disabled(node == 0)
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
                Divider()
            }
            CommandGroup(after: .textEditing) {
                Button("Find") {
                    AppModel.shared.searchActive = true
                    AppModel.shared.panelOpen = true
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}
