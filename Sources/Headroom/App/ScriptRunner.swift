import AppKit
import Foundation
import QuickLookUI

/// Runs the real app through a written list of steps and photographs its window, so the whole interface can be
/// checked by eye without anyone at the mouse. Started with `--script steps.txt`, and it keeps its data apart from yours.
/// It can look and click, but it can't move your files: the app may hold Full Disk Access, and that shouldn't be
/// something another program can script. Its clean, empty and undo steps are stopped by `Cleaner.onlyInside` anywhere but
/// a throwaway test disk. `--no-cache` starts without the saved scan, and `--locked` leaves the guarded folders alone,
/// as on a first launch.
///
///     wait 1.5                 pause, in seconds
///     scanned                  wait until the running scan has finished
///     lens map|changes|freeUp
///     focus ~/some/folder      zoom straight to a folder
///     up
///     hover ~/some/folder
///     tick 0                   tick the nth row in Free Up, or the row with this title
///     plan ~/some/folder       add it to the planned actions, or take it out
///     box quick                tick a box in the panel, by id or title
///     point models             point at a box in the panel. Nothing after it: the pointer leaves
///     pointat Caches           point at one thing in the panel
///     press x y clicks dx dy   a click, double-click or drag on the window, given to the app alone. `press piece 1` hits the ring
///     frame                    where the window is, and whether it fills the screen
///     memory, footprint        how much memory it uses, and what that's made of
///     open models              open a box
///     review                   check what's selected
///     clean, empty, undo       only ever act inside the throwaway test disk
///     keep Title               keep a suggestion
///     after on|off             show the disk as it will be after the clean
///     expand Title             open a suggestion
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
///     film 3 0.1 name          keep photographing in the background without holding anything up: 3 s, every 0.1 s
///     memory label             say how much memory is in use, and the most so far
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
            let rows = model.shownRows.filter(\.isPlannable)
            if let i = Int(argument) {
                if i < rows.count { model.toggle(rows[i]) }
            } else if let row = rows.first(where: { $0.title == argument }) {
                model.toggle(row)
            } else {
                print("no such row: \(argument)")
            }
        case "plan":
            if let node = resolve(argument, model) { model.togglePiece(node) } else { print("no such path: \(argument)") }
        case "box":
            // box quick, box models: ticks a box in the panel, by its id or its title.
            if let box = model.boxes.first(where: { $0.id == argument || $0.title == argument }) { model.toggle(box) } else { print("no such box: \(argument)") }
        case "point":
            // point models: as if the pointer were on that box in the panel. With nothing after it, the pointer leaves.
            if argument.isEmpty { model.point(at: nil) }
            else if let box = model.boxes.first(where: { $0.id == argument || $0.title == argument }) { model.point(at: box) }
            else { print("no such box: \(argument)") }
        case "pointat":
            // pointat Title: as if the pointer were on one thing in the panel.
            if let box = model.boxes.first(where: { $0.rows.contains { $0.title == argument } }), let row = box.rows.first(where: { $0.title == argument }) { model.point(at: box, row: row) }
            else { print("no such thing: \(argument)") }
        case "open":
            model.openBoxes.insert(argument)
        case "review":
            // Looks at what's selected now.
            model.runChecks()
        case "checked":
            // Waits for the checks to finish, and says how long they took.
            let start = DispatchTime.now()
            while model.isChecking { try? await Task.sleep(for: .milliseconds(50)) }
            print(String(format: "checks took %.2f s", Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9))
        case "clean":
            // Only ever acts inside the throwaway test disk: see Cleaner.onlyInside.
            model.cleanNow()
            while model.cleanProgress != nil { try? await Task.sleep(for: .milliseconds(50)) }
        case "empty":
            model.emptyNow()
            while model.afterClean?.isEmptying == true { try? await Task.sleep(for: .milliseconds(50)) }
        case "undo":
            model.undoClean()
        case "copies":
            // What's known about the other copies of a suggestion.
            guard let tree = model.tree, let row = model.flatRows.first(where: { $0.title == argument }) else { print("no such row: \(argument)"); return }
            let video = tree.links.filter { $0.kind == Kind.video.rawValue }
            let found = Accounting.otherCopies(of: row.nodes, in: tree)
            let viaVideo = Accounting.otherCopies(of: row.nodes, in: tree, links: video)
            print("row bytes \(formatBytes(row.bytes)) paper \(formatBytes(row.paperBytes)) copies \(row.otherCopies.count); via video \(viaVideo.folders.count) \(formatBytes(viaVideo.bytes)); nodes \(row.nodes.map { tree.friendlyPath($0) })")
            print("links \(tree.links.count), video links \(video.count), found \(found.folders.count) folders, \(formatBytes(found.bytes)): \(found.folders.prefix(3).map { tree.friendlyPath($0) })")
        case "speed":
            // How long things take, from the click to the new picture being ready.
            guard let tree = model.tree else { return }
            func measure(_ rounds: Int, _ body: () -> Void) -> Double {
                let start = DispatchTime.now()
                for _ in 0..<rounds { body() }
                return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6 / Double(rounds)
            }
            if let big = model.boxes.max(by: { $0.rows.count < $1.rows.count }) {
                let tick = measure(20) { model.toggle(big) }
                print(String(format: "a tick on \(big.title), \(big.rows.count) things: %.1f ms", tick))
                let point = measure(20) { model.pointing = nil; model.point(at: big) }
                print(String(format: "pointing at it: %.1f ms", point))
                model.pointing = nil
            }
            let list = measure(20) { model.refreshShownRows() }
            print(String(format: "the list for this picture: %.1f ms", list))
            let draw = measure(20) { _ = model.drawing(tree) }
            print(String(format: "one picture: %.1f ms", draw))
            let facts = model.facts
            let wins = measure(3) { _ = Wins.build(tree: tree, rules: model.rules, running: [], facts: facts) }
            let all = Wins.build(tree: tree, rules: model.rules, running: [], facts: facts)
            let sections = measure(3) { _ = Sections.build(from: all, tree: tree, facts: facts) }
            let left = measure(3) { _ = Leftovers.find(in: tree) }
            print(String(format: "suggestions %.1f ms, sorting them into sections %.1f ms, of which leftovers %.1f ms", wins, sections, left))
        case "othercopy":
            if let row = model.flatRows.first(where: { $0.title == argument }) { model.toggleOtherCopies(of: row) } else { print("no such row: \(argument)") }
        case "moveplan":
            // moveplan /path/to/thing -> /folder/it/goes/into
            let parts = argument.components(separatedBy: " -> ")
            if parts.count == 2, let item = model.plan.items.first(where: { $0.paths.first == parts[0] }) {
                model.setStep(.move(folder: parts[1]), for: item.id)
            } else {
                print("no such planned thing: \(argument)")
            }
        case "tryagain":
            if let item = model.plan.items.first(where: { $0.paths.first == argument }) { model.tryAgain(item) } else { print("no such planned thing: \(argument)") }
        case "uninstallplan":
            // uninstallplan /path/to/Some.app: the planned thing becomes an uninstall, as an unused app's suggestion is.
            if let item = model.plan.items.first(where: { $0.paths.first == argument }) {
                model.setStep(.uninstall, for: item.id)
            } else {
                print("no such planned thing: \(argument)")
            }
        case "keep":
            if let row = model.shownRows.first(where: { $0.title == argument }) { model.keep(row) } else { print("no such row: \(argument)") }
        case "after":
            model.setPreviewAfter(argument != "off")
        case "expand":
            if let row = model.shownRows.first(where: { $0.title == argument }) { model.toggleExpanded(row) } else { print("no such row: \(argument)") }
        case "keys":
            for character in argument { model.handleScriptKey(character) }
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
            // With the display off for a moment, as on a locked screen, a picture can fail. It works when it's back on.
            for _ in 0..<8 where !FileManager.default.fileExists(atPath: argument) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-x", "-o", "-l", String(w.windowNumber), argument]
                try? task.run()
                task.waitUntilExit()
                if !FileManager.default.fileExists(atPath: argument) { try? await Task.sleep(for: .seconds(1)) }
            }
            print("shot \(argument)")
        case "film":
            let parts = argument.split(separator: " ").map(String.init)
            guard parts.count == 3, let seconds = Double(parts[0]), let step = Double(parts[1]), let window = mainWindow else { return }
            let id = String(window.windowNumber)
            let name = parts[2]
            Task.detached {
                for frame in 0..<Int(seconds / step) {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    task.arguments = ["-x", "-o", "-l", id, name + String(format: "-%03d.png", frame)]
                    try? task.run()
                    try? await Task.sleep(for: .seconds(step))
                }
            }
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
        case "float":
            // Stage Manager shrinks a window it can't bring forward, as on a locked screen. It leaves floating ones alone.
            mainWindow?.level = .floating
            mainWindow?.orderFrontRegardless()
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
        case "memory":
            // memory label: how much memory the app is using now, and the most it has used so far.
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            if result == KERN_SUCCESS {
                print(String(format: "memory %@: %.0f MB now, %.0f MB at most", argument, Double(info.phys_footprint) / 1e6, Double(info.ledger_phys_footprint_peak) / 1e6))
            }
        case "hide":
            NSApp.hide(nil)
        case "unhide":
            NSApp.unhide(nil)
        case "minimize":
            mainWindow?.miniaturize(nil)
        case "restore":
            mainWindow?.deminiaturize(nil)
        case "lose":
            model.mapView?.loseWhatItMayLose()
        case "redraw":
            model.mapView?.startAnimating()
        case "stopwhenhidden":
            // As in real use, where nothing is drawn while the window can't be seen.
            MapHostView.drawsWhenHidden = false
        case "frames":
            print("frames drawn \(argument): \(model.mapView?.framesDrawn ?? -1)")
        case "frame":
            // Where the window is, whether it fills the screen, and whether it has been told to move.
            if let w = mainWindow {
                print("frame \(argument): \(Int(w.frame.minX)),\(Int(w.frame.minY)) \(Int(w.frame.width))x\(Int(w.frame.height)) zoomed \(w.isZoomed); moves started \(model.mapView?.windowMovesStarted ?? -1); selected \(model.selected.map { model.displayName($0) } ?? "nothing")")
            }
        case "press":
            // press x y clicks [dx dy]: a click, double-click or drag at points from the window's top left, given straight to
            // the app. Your real pointer doesn't move. `press piece` picks the middle of the biggest piece on the ring.
            guard let w = mainWindow else { return }
            var parts = argument.split(separator: " ").map(String.init)
            var x = 0.0, y = 0.0
            if parts.first == "piece" {
                parts.removeFirst()
                let layout = model.engine.layout
                guard let piece = layout.pieces.filter({ !$0.isSmaller && !$0.isMark && $0.style == 0 }).max(by: { $0.bytes < $1.bytes }) else {
                    print("press: no piece among \(layout.pieces.count)")
                    return
                }
                let angle = Double(piece.a0 + piece.a1) / 2, radius = Double(piece.r0 + piece.r1) / 2 * model.ring.radius
                x = model.ring.center.x + sin(angle) * radius
                y = model.ring.center.y - cos(angle) * radius
            } else {
                guard parts.count >= 3, let px = Double(parts[0]), let py = Double(parts[1]) else { return }
                x = px
                y = py
                parts.removeFirst(2)
            }
            let clicks = Int(parts.first ?? "1") ?? 1
            let dx = parts.count > 2 ? Double(parts[1]) ?? 0 : 0, dy = parts.count > 2 ? Double(parts[2]) ?? 0 : 0
            func send(_ type: NSEvent.EventType, _ px: Double, _ py: Double, count: Int) {
                let at = NSPoint(x: px, y: w.frame.height - py)
                if let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1) {
                    NSApp.sendEvent(event)
                }
            }
            let target = w.contentView?.superview?.hitTest(NSPoint(x: x, y: w.frame.height - y))
            print("press at \(Int(x)),\(Int(y)) lands on \(target.map { String(describing: type(of: $0)) } ?? "nothing")")
            for click in 1...max(clicks, 1) {
                send(.leftMouseDown, x, y, count: click)
                if dx != 0 || dy != 0 {
                    for step in 1...6 { send(.leftMouseDragged, x + dx * Double(step) / 6, y + dy * Double(step) / 6, count: click) }
                }
                send(.leftMouseUp, x + dx, y + dy, count: click)
                try? await Task.sleep(for: .milliseconds(80))
            }
        case "footprint":
            // What the memory is made of, by the tool macOS has for it.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
            process.arguments = [String(ProcessInfo.processInfo.processIdentifier)]
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            print(String(decoding: data, as: UTF8.self))
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
        if tree.isPartial { print("still reading \(formatBytes(tree.totals[Int(tree.hidden)])), \(model.scanFiles) files so far") }
        print(String(format: "pieces %d, labels %d, last scan loaded in %.1f ms", model.engine.layout.pieces.count, model.labels.count, model.cacheLoadMilliseconds))
        print("focus \(model.displayName(model.focus)), planned \(model.plan.count), you'd get back \(formatBytes(model.planBytes)), message: \(model.message ?? "none")")
        print("plan:")
        for item in model.plan.items {
            let check = model.checks[item.id]
            print("  \(item.title) — \(formatBytes(model.planBytesByItem[item.id] ?? 0)) step=\(item.step) paths=\(item.paths.count) excluded=\(item.excluded.count) problems=\(check?.problems.map(\.text) ?? [])")
        }
        if let after = model.afterClean { print("after clean: \(formatBytes(after.bytes)) in the Trash, \(after.things.count) things, failed \(after.failed), state \(after.state)") }
        print("disks: \(model.otherDisks(for: "/").map { "\($0.name) \($0.isPluggedIn ? "plugged in" : "away")" })")
        print("kept: \(model.plan.kept.map(\.title))  other copies: \(model.otherCopies.map { "\($0.key) → \($0.value.title) \(formatBytes($0.value.bytes))" })")
        if let tree = model.tree {
            var denied = 0
            for i in 0..<tree.count where tree.nodes[i].has(NodeFlag.denied) { denied += 1 }
            print("folders that wouldn't open: \(denied), of \(tree.count) nodes, \(tree.totalFiles[0]) files, hidden \(formatBytes(tree.totals[Int(tree.hidden)]))")
        }
        print("boxes: " + model.boxes.map { "\($0.title) \(formatBytes($0.bytes)) [\($0.rows.count)] \(model.rowStates[$0.id] ?? .none)" }.joined(separator: " | "))
        print("shown \(model.shownRows.count) of \(model.suggestions.everything.count) suggestions:")
        for row in model.shownRows {
            print("  [\(row.tier.title)\(row.isQuick ? " quick" : "")\(row.inUse != nil ? " in use: \(row.inUse!)" : "")] \(row.title) — \(formatBytes(row.bytes)) (paper \(formatBytes(row.paperBytes))) \(row.subtitle) action=\(row.action) tick=\(model.rowStates[row.id] ?? .none)\(row.otherCopies.isEmpty ? "" : " copies: \(row.otherCopiesTitle ?? "") \(row.otherCopiesNote ?? "")")")
            for part in row.parts { print("      · \(part.title) — \(formatBytes(part.bytes)) \(part.subtitle)\(part.alsoTitle.map { " | " + $0 } ?? "")") }
        }
        print("changes (\(model.changeCaption)):")
        for row in model.changeRows.prefix(12) { print("  +\(formatBytes(UInt64(max(row.delta, 0)))) \(row.title)  \(row.subtitle)") }
    }
}
