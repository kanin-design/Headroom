import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
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
}

struct HeadroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Headroom", id: "main") {
            RootView()
                .frame(minWidth: 860, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Scan Again") { AppModel.shared.scan(hurry: true) }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Map") { AppModel.shared.setLens(.map) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Changes") { AppModel.shared.setLens(.changes) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Free Up") { AppModel.shared.setLens(.freeUp) }
                    .keyboardShortcut("3", modifiers: .command)
                Divider()
                Button("Back") { AppModel.shared.goUp() }
                    .keyboardShortcut("[", modifiers: .command)
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
