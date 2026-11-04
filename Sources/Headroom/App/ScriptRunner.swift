import AppKit
import Foundation
import QuickLookUI

/// Runs the real app through a written list of steps and photographs its window, so the whole interface can be
/// checked by eye without anyone at the mouse. Started with `--script steps.txt`, and it keeps its data apart from yours.
/// It can look and click, but deliberately has no step that moves files: the app may hold Full Disk Access, and that
/// shouldn't be something another program can script. `--no-cache` starts without the saved scan, and `--locked` leaves
/// the guarded folders alone, as on a first launch.
///
///     wait 1.5                 pause, in seconds
///     scanned                  wait until the running scan has finished
///     lens map|changes|freeUp
///     focus ~/some/folder      zoom straight to a folder
///     up
///     hover ~/some/folder
///     tick 0                   tick the nth row in Free Up, or the row with this title
///     window 7                 pick a Changes window, in days, or 0 for the last scan
///     search text
///     panel on|off
///     size 1440 900
///     timescale 0.1            slow every animation down
///     mouse x y                move the real pointer path, in window points
///     click x y
///     activate                 bring the app to the front
///     quicklook ~/some/file    open the preview panel, and report what it shows
///     volume /Volumes/Name     switch to another disk
///     shot file.png
///     quit
enum ScriptRunner {
    static var path: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--script"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor
    static func startIfAsked() {
        guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let model = AppModel.shared
        model.forceTouchGuarded = !CommandLine.arguments.contains("--locked")
        Task { @MainActor in
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                let argument = parts.count > 1 ? parts[1] : ""
                await run(parts[0], argument, model)
            }
        }
    }

    @MainActor
    private static func resolve(_ path: String, _ model: AppModel) -> UInt32? {
        guard let tree = model.tree else { return nil }
        var p = path
        if p.hasPrefix("~") { p = "/System/Volumes/Data" + NSHomeDirectory() + p.dropFirst() }
        return tree.find(path: p)
    }

    @MainActor
    private static func run(_ command: String, _ argument: String, _ model: AppModel) async {
        switch command {
        case "wait":
            try? await Task.sleep(for: .seconds(Double(argument) ?? 1))
        case "scanned":
            while model.isScanning || model.tree == nil { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(400))
        case "lens":
            switch argument {
            case "changes": model.setLens(.changes)
            case "freeUp": model.setLens(.freeUp)
            default: model.setLens(.map)
            }
        case "focus":
            if let node = resolve(argument, model), let tree = model.tree { model.zoom(into: RingLayout.chainTail(tree: tree, node)) }
            else { print("no such folder: \(argument)") }
        case "up":
            model.goUp()
        case "hover":
            if argument.isEmpty { model.setHover(nil) }
            else if let node = resolve(argument, model) { model.highlight(node: node) }
            else { print("no such folder: \(argument)") }
        case "tick":
            let rows = model.wins.filter { $0.action == .trash }
            if let i = Int(argument) {
                if i < rows.count { model.toggle(rows[i]) }
            } else if let row = rows.first(where: { $0.title == argument }) {
                model.toggle(row)
            } else {
                print("no such row: \(argument)")
            }
        case "window":
            if let d = Int(argument) { model.setChangeWindow(d == 0 ? .lastScan : .days(d)) }
        case "search":
            model.searchActive = true
            model.searchText = argument
            model.runSearch()
        case "panel":
            model.panelOpen = argument != "off"
        case "size":
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            if numbers.count == 2, let w = mainWindow {
                var frame = w.frame
                frame.origin.y += frame.height - numbers[1]
                frame.size = CGSize(width: numbers[0], height: numbers[1])
                w.setFrame(frame, display: true)
            }
        case "timescale":
            model.engine.timeScale = Float(argument) ?? 1
        case "shot":
            guard let w = mainWindow else { print("no window"); return }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l", String(w.windowNumber), argument]
            try? task.run()
            task.waitUntilExit()
            print("shot \(argument)")
        case "mouse", "click":
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            guard numbers.count == 2, let view = model.mapView, let w = mainWindow else { return }
            let location = NSPoint(x: numbers[0], y: w.frame.height - numbers[1])
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if command == "mouse" {
                if let e = event(.mouseMoved) { view.mouseMoved(with: e) }
                print("mouse \(argument) hover: \(model.hover?.title ?? "nothing")")
            } else if let down = event(.leftMouseDown), let up = event(.leftMouseUp) {
                view.mouseDown(with: down)
                view.mouseUp(with: up)
            }
        case "activate":
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            mainWindow?.makeKeyAndOrderFront(nil)
        case "quicklook":
            var path = argument
            if path.hasPrefix("~") { path = NSHomeDirectory() + path.dropFirst() }
            QuickLook.shared.show(URL(fileURLWithPath: path))
            try? await Task.sleep(for: .milliseconds(700))
            let panel = QLPreviewPanel.shared()
            print("quick look visible: \(panel?.isVisible ?? false), showing: \((panel?.currentPreviewItem?.previewItemURL)?.lastPathComponent ?? "nothing")")
            panel?.orderOut(nil)
        case "volume":
            if let facts = VolumeFacts.read(path: argument) { model.switchVolume(facts) } else { print("no such disk: \(argument)") }
        case "report":
            report(model)
        case "quit":
            fflush(stdout)
            NSApp.terminate(nil)
        default:
            print("unknown step: \(command)")
        }
    }

    @MainActor
    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }
    }

    @MainActor
    private static func report(_ model: AppModel) {
        guard let tree = model.tree else { print("no tree"); return }
        print(String(format: "scan %.2fs, %d files, %d nodes, %d link records", tree.scanSeconds, tree.totalFiles[0], tree.count, tree.links.count))
        print(String(format: "pieces %d, labels %d, last scan loaded in %.1f ms", model.engine.layout.pieces.count, model.labels.count, model.cacheLoadMilliseconds))
        print("focus \(model.displayName(model.focus)), ticked \(model.ticked.count), you'd get back \(formatBytes(model.tickedReclaim)), message: \(model.message ?? "none")")
        print("wins:")
        for row in model.wins { print("  [\(row.tier.title)] \(row.title) — \(formatBytes(row.bytes)) (paper \(formatBytes(row.paperBytes))) \(row.subtitle) action=\(row.action)") }
        print("changes (\(model.changeCaption)):")
        for row in model.changeRows.prefix(12) { print("  +\(formatBytes(UInt64(max(row.delta, 0)))) \(row.title)  \(row.subtitle)") }
    }
}
