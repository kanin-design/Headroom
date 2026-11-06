import AppKit
import Foundation
import SwiftUI

/// Runs the real app through a written list of steps and photographs its window, so the whole interface can be
/// checked by eye without anyone at the mouse. Started with `--script steps.txt`, and it keeps its data apart from yours.
/// It can look and click, but it can't move your files: the app may hold Full Disk Access, and that shouldn't be
/// something another program can script. Its clean, empty and undo steps are stopped by `Cleaner.onlyInside` anywhere but
/// a throwaway test disk. `--no-cache` starts without the saved scan, and `--locked` acts as if Full Disk Access were off,
/// so nothing is read, as on a first launch without it.
///
///     wait 1.5                 pause, in seconds
///     scanned                  wait until the running scan has finished
///     lens map|changes|freeUp
///     focus ~/some/folder      zoom straight to a folder
///     up
///     bench                    what everything costs on this disk, in milliseconds
///     meter start, meter name  how busy the main thread was between the two, and its longest stall
///     pacing start, pacing name  whether every frame of the ring reached the screen on time between the two, what each
///                              cost, and how busy the main thread was
///     sweep ring 5             the pointer travelling over the ring or the panel, without your real one moving
///     back, forward            the arrows at the top of the panel
///     select ~/some/file       as if it had been clicked: the panel shows it
///     hover ~/some/folder
///     links ~/some/folder      what the middle of the ring says about its hard links or clones, and how long that takes
///     lastuse ~/some/folder    what the middle of the ring says about when it was last used, and how long that takes
///     pointname ~/some/folder  as if the pointer were on a row with this name. Nothing after it: the pointer leaves
///     moveto x y               tell the window the pointer is here, without moving your real one
///     rightclick x y           right-click here, say what the menu offers, and close it
///     target                   what an action would apply to now
///     where                    which folder it's in, and what's selected
///     menu ~/some/folder       what a right-click offers for it, or for what an action would apply to now
///     action Copy Path         do this from that list, to what an action would apply to now
///     clipboard                what's been copied, on a clipboard of its own, and what the pill says
///     menubar                  what's in the File and Edit menus
///     key c cmd opt            give the menu bar this shortcut
///     menuitem Edit Copy List  choose this from the menu bar
///     copyroute                what ⌘C would copy now
///     tick 0                 tick the nth row in Free Up, or the row with this title
///     plan ~/some/folder       add it to the planned actions, or take it out
///     box quick                tick a box in the panel, by id or title
///     point models             point at a box in the panel. Nothing after it: the pointer leaves
///     pointat Caches           point at one thing in the panel
///     press x y clicks dx dy   a click, double-click or drag on the window, given to the app alone. `press piece 1` hits the ring
///     frame                    where the window is, and whether it fills the screen
///     memory, footprint        how much memory it uses, and what that's made of
///     open models              open a box
///     review                   check what's selected
///     labelpoint 2             the pointer on a name around the ring, and what's lit while it moves there
///     labelleave 2, ringpoint  the pointer leaves that name, or moves onto the ring itself, and what's lit then
///     panelhover 2             the pointer on that thing's row in the panel, moving a little, and what's lit
///     labelclick 2             what a click on that name does. `labelclick 2 2` is the second click of a double-click
///     ringclick 2              a click on this piece of the ring. `ringclick 2 2` is a double-click
///     button                   how much of what's selected is ready, and why the rest isn't
///     busy anyway              what Send to Trash asks when something is using the folder, and the answer: anyway or cancel
///     cleananyway /some/path   the Clean anyway button, for something selected that's in use
///     leaks                    with --hide-names, look for real names in everything the app has ready to show
///     about picture.png        open About Headroom from the app menu, and take its picture
///     clean, empty, undo       only ever act inside the throwaway test disk
///     keep Title               keep a suggestion
///     after on|off             show the disk as it will be after the clean
///     expand Title             open a suggestion
///     window 7                 pick a Changes window, in days, or 0 for the last scan
///     search text
///     panel on|off
///     size 1440 900            the window's size. size 1440 900 0 40 also puts its top left corner there on the screen,
///                              away from wherever your real pointer is resting
///     timescale 0.1            slow every animation down
///     mouse x y                move the real pointer path, in window points
///     click x y
///     activate                 bring the app to the front
///     look ~/some/file         open the card Space opens, for this or for what an action would apply to now
///     card                     what the card is showing
///     keydown 49               a key as the app gets it, by key code. 49 is space
///     volume /Volumes/Name     switch to another disk
///     shot file.png
///     film 3 0.1 name          keep photographing in the background without holding anything up: 3 s, every 0.1 s
///     memory label             say how much memory is in use, and the most so far
///     quit
/// How busy the main thread is, and the longest it has been away: what you'd feel as a hitch.
final class MainThreadMeter {
    private var observer: CFRunLoopObserver?
    private var wokeAt = 0.0
    private(set) var busy = 0.0, longest = 0.0, over16 = 0, over50 = 0
    /// When each stall over 16 ms began, in ms from the start, and how long it was.
    private(set) var stalls: [(at: Double, ms: Double)] = []
    private let began = CFAbsoluteTimeGetCurrent()
    private let cpuAtStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)

    init() {
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, activity in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if activity == .afterWaiting {
                self.wokeAt = now
            } else if self.wokeAt > 0 {
                let ms = (now - self.wokeAt) * 1000
                self.busy += ms
                self.longest = max(self.longest, ms)
                if ms > 16 {
                    self.over16 += 1
                    self.stalls.append(((self.wokeAt - self.began) * 1000, ms))
                }
                if ms > 50 { self.over50 += 1 }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func report(_ label: String) {
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        let total = (CFAbsoluteTimeGetCurrent() - began) * 1000
        let cpu = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuAtStart) / 1e6
        print(String(format: "meter %-30@ cpu %5.1f%%, main %4.1f%%, longest %5.1f ms, over 16 ms %3d, over 50 ms %3d", label as NSString, cpu / total * 100, busy / total * 100, longest, over16, over50))
        if !stalls.isEmpty { print("  stalls at " + stalls.map { String(format: "%.0f ms for %.0f", $0.at, $0.ms) }.joined(separator: ", ")) }
    }
}

enum ScriptRunner {
    @MainActor private static var meter: MainThreadMeter?
    @MainActor private static var pacingStarted: CFTimeInterval = 0

    static var path: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--script"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor
    static func startIfAsked() {
        guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        // Each line as it's written, so a run that gets stuck still says how far it got.
        setvbuf(stdout, nil, _IOLBF, 0)
        let model = AppModel.shared
        Task { @MainActor in
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                print("step \(line)")
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                let argument = parts.count > 1 ? parts[1] : ""
                await run(parts[0], argument, model)
            }
        }
    }

    /// How evenly the ring's frames reached the screen. A frame that came a refresh or more late is one you'd see as a hitch.
    private static func pacing(_ notes: [RingDrawer.FrameNote], interval: Double, since start: CFTimeInterval, label: String) -> String {
        func percentile(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * p)]
        }
        var hitches = 0, missed = 0, longest = 0.0, uneven = 0
        var when: [String] = []
        for i in notes.indices.dropFirst() where !notes[i].restarted && notes[i].presented > 0 && notes[i - 1].presented > 0 {
            let gap = notes[i].presented - notes[i - 1].presented
            longest = max(longest, gap)
            let refreshes = Int((gap / interval).rounded())
            if refreshes > 1 {
                hitches += 1
                missed += refreshes - 1
                when.append(String(format: "%.0f ms (frame %d of its run)", (notes[i].target - start) * 1000, i - (notes[...i].lastIndex(where: \.restarted) ?? 0)))
            }
            // The picture moved on by a different time than passed on screen: it would look uneven even with no frame missed.
            if abs(notes[i].dt - gap) > interval * 0.5 { uneven += 1 }
        }
        let runs = notes.filter(\.restarted).count
        let unseen = notes.filter { $0.presented == 0 }.count
        let cpu = notes.map(\.cpu), gpu = notes.map(\.gpu).filter { $0 > 0 }
        return String(format: "pacing %@: %d frames in %d runs, %d hitches (%d refreshes missed), longest gap %.1f ms, %d never shown, %d uneven; each frame cpu %.2f/%.2f/%.2f ms, gpu %.2f/%.2f/%.2f ms (median/95%%/most)",
                      label as NSString, notes.count, runs, hitches, missed, longest * 1000, unseen, uneven,
                      percentile(cpu, 0.5), percentile(cpu, 0.95), cpu.max() ?? 0, percentile(gpu, 0.5), percentile(gpu, 0.95), gpu.max() ?? 0)
            + (when.isEmpty ? "" : "\n  hitches at " + when.joined(separator: ", "))
            + "\n  runs start at " + notes.indices.filter { notes[$0].restarted }.map { String(format: "%.0f ms", (notes[$0].target - start) * 1000) }.joined(separator: ", ")
    }

    @MainActor
    private static func resolve(_ path: String, _ model: AppModel) -> UInt32? {
        guard let tree = model.tree else { return nil }
        var p = path
        if p.hasPrefix("~") { p = "/System/Volumes/Data" + NSHomeDirectory() + p.dropFirst() }
        return tree.find(path: p) ?? (p.hasPrefix("/System/Volumes/Data/") ? nil : tree.find(path: "/System/Volumes/Data" + p))
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
            // As a click on the switcher does it.
            let lens: Lens = argument == "changes" ? .changes : argument == "freeUp" ? .freeUp : .map
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { model.setLens(lens) }
        case "focus":
            if let node = resolve(argument, model), let tree = model.tree { model.zoom(into: RingLayout.chainTail(tree: tree, node)) }
            else { print("no such folder: \(argument)") }
        case "up":
            model.goUp()
        case "hover":
            if argument.isEmpty { model.setHover(nil) }
            else if let node = resolve(argument, model) { model.highlight(node: node) }
            else { print("no such folder: \(argument)") }
        case "links":
            if let node = resolve(argument, model), let tree = model.tree {
                let started = CFAbsoluteTimeGetCurrent()
                let line = Accounting.hoverLine(node, bytes: tree.totals[Int(node)], in: tree)
                let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
                print("links \(argument): \(formatBytes(tree.totals[Int(node)])), \(line ?? "says nothing"), \(String(format: "%.1f", ms)) ms")
            } else { print("no such folder: \(argument)") }
        case "lastuse":
            if let node = resolve(argument, model), let tree = model.tree {
                let started = CFAbsoluteTimeGetCurrent()
                let line = LastUse.line(node, in: tree)
                let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
                print("last use \(argument): \(line ?? "says nothing"), \(String(format: "%.3f", ms)) ms")
            } else { print("no such folder: \(argument)") }
        case "pointname":
            model.pointedThing = resolve(argument, model).map { NamedThing($0) }
        case "moveto":
            guard let w = mainWindow else { return }
            let parts = argument.split(separator: " ").compactMap { Double($0) }
            guard parts.count == 2 else { return }
            let at = NSPoint(x: parts[0], y: w.frame.height - parts[1])
            guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return }
            let view = w.contentView?.superview?.hitTest(at)
            print("moveto \(argument): lands on \(view.map { String(describing: type(of: $0)).prefix(30) } ?? "nothing")")
            view?.mouseMoved(with: event)
            w.contentView?.mouseMoved(with: event)
            try? await Task.sleep(for: .milliseconds(60))
        case "rightclick":
            guard let w = mainWindow else { return }
            let parts = argument.split(separator: " ").compactMap { Double($0) }
            guard parts.count == 2 else { return }
            let at = NSPoint(x: parts[0], y: w.frame.height - parts[1])
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            // An event made this way can't say which button it is, and SwiftUI asks. For as long as this takes, it's the right one.
            let button = class_getInstanceMethod(NSEvent.self, #selector(getter: NSEvent.buttonNumber))!
            let usual = method_getImplementation(button)
            let right: @convention(block) (NSEvent) -> Int = { _ in 1 }
            method_setImplementation(button, imp_implementationWithBlock(right))
            defer { method_setImplementation(button, usual) }
            var opened = false
            let watch = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                guard let menu = note.object as? NSMenu, !opened else { return }
                opened = true
                print("right-click \(argument): " + menu.items.map { item in
                    item.isSeparatorItem ? "|" : item.title + (item.keyEquivalent.isEmpty ? "" : " [key]")
                }.joined(separator: ", "))
                menu.perform(#selector(NSMenu.cancelTracking), with: nil, afterDelay: 0.05, inModes: [.eventTracking, .common])
            }
            if let down = event(.rightMouseDown) { NSApp.sendEvent(down) }
            if let up = event(.rightMouseUp) { NSApp.sendEvent(up) }
            NotificationCenter.default.removeObserver(watch)
            if !opened { print("right-click \(argument): no menu") }
        case "target":
            print("target \(argument):\(model.actionTarget.nodes.map { model.realName(of: $0) })")
        case "where":
            print("where \(argument): in \(model.realName(of: model.focus)), selected \(model.selected.map { model.realName(of: $0) } ?? "nothing"), \(model.plan.items.count) planned, back \(model.canGoBack), forward \(model.canGoForward), \(model.afterClean?.things.count ?? 0) in the Trash from here")
        case "select":
            model.selected = resolve(argument, model)
            try? await Task.sleep(for: .milliseconds(100))
        case "back":
            model.goBack()
            try? await Task.sleep(for: .milliseconds(400))
        case "forward":
            model.goForward()
            try? await Task.sleep(for: .milliseconds(400))
        case "menu":
            let thing = resolve(argument, model).map { NamedThing($0) } ?? model.actionTarget
            let titles = model.actions(for: thing).map { action in
                (action.startsGroup ? "| " : "") + action.title + (action.submenu.isEmpty ? "" : " > [" + action.submenu.map { ($0.startsGroup ? "| " : "") + ($0.isNote ? "(\($0.title))" : $0.title) }.joined(separator: ", ") + "]")
            }
            print("menu \(argument): \(titles.joined(separator: ", "))")
        case "action":
            let actions = model.actions(for: model.actionTarget)
            if let action = (actions + actions.flatMap(\.submenu)).first(where: { $0.title == argument }) { action.run() }
            else { print("no such action: \(argument)") }
            try? await Task.sleep(for: .milliseconds(60))
        case "clipboard":
            print("clipboard \(argument): \(AppModel.clipboard.string(forType: .string) ?? "nothing") | pill: \(model.tip ?? "none")")
        case "menubar":
            for title in (NSApp.mainMenu?.items ?? []).map(\.title) {
                let items = NSApp.mainMenu?.items.first { $0.title == title }?.submenu?.items ?? []
                func refresh(_ menu: NSMenu) {
                    menu.delegate?.menuNeedsUpdate?(menu)
                    menu.update()
                    menu.items.compactMap(\.submenu).forEach(refresh)
                }
                NSApp.mainMenu?.items.first { $0.title == title }?.submenu.map(refresh)
                func words(_ items: [NSMenuItem]) -> String {
                    // Hidden items are only there for their keys, such as the Globe key's, and nobody sees them.
                    items.filter { !$0.isSeparatorItem && !$0.isHidden }.map { item in
                        var keys = ""
                        if item.keyEquivalentModifierMask.contains(.shift) { keys += "⇧" }
                        if item.keyEquivalentModifierMask.contains(.option) { keys += "⌥" }
                        if item.keyEquivalentModifierMask.contains(.command) { keys += "⌘" }
                        let key = item.keyEquivalent.isEmpty ? "" : " [\(keys)\(item.keyEquivalent == "\u{7F}" || item.keyEquivalent == "\u{8}" ? "⌫" : item.keyEquivalent)]"
                        return item.title + (item.isEnabled ? "" : " (off)") + key + (item.submenu.map { " > (" + words($0.items) + ")" } ?? "")
                    }.joined(separator: ", ")
                }
                print("\(title): " + words(items))
            }
        case "key":
            guard let w = mainWindow else { return }
            let parts = argument.split(separator: " ").map(String.init)
            guard let key = parts.first else { return }
            var flags: NSEvent.ModifierFlags = []
            if parts.contains("cmd") { flags.insert(.command) }
            if parts.contains("opt") { flags.insert(.option) }
            if parts.contains("shift") { flags.insert(.shift) }
            let characters = key == "delete" ? String(KeyEquivalent.delete.character) : (parts.contains("shift") ? key.uppercased() : key)
            let codes: [String: UInt16] = ["c": 8, "o": 31, "r": 15, "y": 16, "z": 6, "[": 33, "]": 30, "delete": 51]
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: codes[key] ?? 0) else { return }
            print("key \(argument): \(NSApp.mainMenu?.performKeyEquivalent(with: event) == true ? "handled" : "not handled")")
            try? await Task.sleep(for: .milliseconds(60))
        case "menuitem":
            let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let menu = NSApp.mainMenu?.items.first(where: { $0.title == parts[0] })?.submenu,
                  let at = menu.items.firstIndex(where: { $0.title == parts[1] }) else {
                print("no such menu item: \(argument)")
                return
            }
            menu.performActionForItem(at: at)
            try? await Task.sleep(for: .milliseconds(60))
        case "copyroute":
            print("⌘C \(argument): \(model.wouldCopySelectedText ? "selected text" : "the name of \(model.actionTarget.nodes.map { model.realName(of: $0) })"), first responder \(mainWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
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
        case "meter":
            // meter start, then meter what it was
            if argument == "start" {
                meter = MainThreadMeter()
            } else {
                meter?.report(argument)
                meter = nil
            }
        case "pacing":
            guard let view = model.mapView else { return }
            if argument == "start" {
                view.drawer.beginNotes()
                meter = MainThreadMeter()
                pacingStarted = CACurrentMediaTime()
                return
            }
            // The last frames say when they reached the screen a moment after they're drawn.
            try? await Task.sleep(for: .milliseconds(200))
            print(pacing(view.drawer.endNotes(), interval: mainWindow?.screen?.minimumRefreshInterval ?? 1.0 / 60, since: pacingStarted, label: argument))
            meter?.report(argument)
            meter = nil
        case "benchcopy":
            // benchcopy /from -> /into: the real copy and check, timed. Only ever inside the throwaway test disk.
            let parts = argument.components(separatedBy: " -> ")
            guard parts.count == 2 else { return }
            let started = DispatchTime.now()
            do {
                try Cleaner.copyAndVerify(parts[0], into: parts[1], stop: LockedFlag()) { _ in }
                print(String(format: "benchcopy: %.0f ms", Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6))
            } catch {
                print("benchcopy failed: \(error)")
            }
        case "touch":
            // So that something outside can tell how far this has got.
            FileManager.default.createFile(atPath: argument, contents: nil)
        case "sweep":
            // sweep ring 5, sweep panel 5: the pointer travelling over it for that many seconds, without your real one moving.
            guard let w = mainWindow else { return }
            let parts = argument.split(separator: " ").map(String.init)
            let seconds = Double(parts.last ?? "") ?? 3
            let start = Date()
            var step = 0.0
            var moves = 0
            var busy = 0.0
            while Date().timeIntervalSince(start) < seconds {
                step += 1
                let at: NSPoint
                if parts.first == "panel" {
                    at = NSPoint(x: w.frame.width - 180, y: w.frame.height - (300 + (step.truncatingRemainder(dividingBy: 40)) * 12))
                } else {
                    let angle = step * 0.19, radius = model.ring.radius * (0.45 + 0.45 * abs(sin(step * 0.03)))
                    at = NSPoint(x: model.ring.center.x + sin(angle) * radius, y: w.frame.height - (model.ring.center.y - cos(angle) * radius))
                }
                guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { continue }
                let began = DispatchTime.now()
                if parts.first == "panel" { w.contentView?.mouseMoved(with: event) } else { model.mapView?.mouseMoved(with: event) }
                busy += Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1e6
                moves += 1
                try? await Task.sleep(for: .milliseconds(12))
            }
            print(String(format: "sweep %@: %d moves, %.2f ms each in the call itself", argument, moves, busy / Double(max(moves, 1))))
        case "bench":
            // What everything costs on this disk, in milliseconds. Nothing here changes anything on disk.
            guard let tree = model.tree else { return }
            func time(_ label: String, rounds: Int = 5, _ body: () -> Void) {
                let start = DispatchTime.now()
                for _ in 0..<rounds { body() }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6 / Double(rounds)
                print(String(format: "bench %-34@ %9.2f ms", label as NSString, ms))
            }
            let home = NSHomeDirectory()
            let facts = model.facts
            let biggest = model.flatTop(tree).first ?? 0
            let library = tree.find(path: "/System/Volumes/Data" + home + "/Library") ?? biggest
            time("reclaimable, biggest") { _ = Accounting.reclaimable([biggest], in: tree) }
            time("story, biggest") { _ = Accounting.story(biggest, in: tree) }
            time("hover line, biggest") { _ = Accounting.hoverLine(biggest, bytes: tree.totals[Int(biggest)], in: tree) }
            time("the top list") { _ = model.flatTop(tree) }
            time("what's inside, Library") { _ = LookContents.rows(of: library, in: tree) }
            time("facts, Library") { _ = LookContents.facts(of: library, in: tree) }
            time("facts, your files") { _ = LookContents.facts(of: tree.home, in: tree) }
            time("pictures, biggest") { _ = LookContents.media(in: biggest, tree: tree) }
            time("the menu for it") { _ = model.actions(for: NamedThing(biggest)) }
            time("kinds, biggest") { _ = tree.kindBytes(biggest) }
            time("find by path") { _ = tree.find(path: "/System/Volumes/Data" + home + "/Library/Caches") }
            time("search: a", rounds: 3) { _ = Search.run("a", in: tree) }
            time("search: mkv", rounds: 3) { _ = Search.run("mkv", in: tree) }
            time("search: node_modules", rounds: 3) { _ = Search.run("node_modules", in: tree) }
            time("search: ø", rounds: 3) { _ = Search.run("ø", in: tree) }
            time("search: blåbær", rounds: 3) { _ = Search.run("blåbær", in: tree) }
            time("one picture") { _ = model.drawing(tree) }
            time("the names around it") { _ = model.makeLabels() }
            let pieces = model.engine.layout.pieces.count
            time("hover on, hover off", rounds: 20) { model.setHover(pieces / 2); model.setHover(nil) }
            time("zoom in and back", rounds: 3) { model.zoom(into: RingLayout.chainTail(tree: tree, biggest)); model.go(to: 0) }
            time("the list for this picture") { model.refreshShownRows() }
            time("Map to Free Up and back", rounds: 3) { model.setLens(.freeUp); model.setLens(.map) }
            time("open files", rounds: 3) { _ = OpenFiles.snapshot() }
            time("check one thing", rounds: 1) {
                let item = PlanItem(id: "bench", title: "bench", note: "", tierRaw: Tier.yourCall.rawValue, paths: [home + "/Library"], lastKnownBytes: 0)
                _ = PlanChecks.run(items: [item], trueBytes: [:], otherCopy: [:], runningApps: [], fullAccess: true)
            }
            let everything = model.flatRows.filter(\.isPlannable).compactMap { row -> PlanItem? in
                let paths = row.nodes.compactMap { tree.path($0).map(ThingText.visible) }
                return paths.isEmpty ? nil : PlanItem(id: row.id, title: row.title, note: "", tierRaw: row.tier.rawValue, paths: paths, lastKnownBytes: row.bytes)
            }
            print("bench \(everything.count) things could be ticked, \(everything.reduce(0) { $0 + $1.paths.count }) paths")
            time("check them all, first time", rounds: 1) { _ = PlanChecks.run(items: everything, trueBytes: [:], otherCopy: [:], runningApps: [], fullAccess: true) }
            time("check them all, again", rounds: 3) { _ = PlanChecks.run(items: everything, trueBytes: [:], otherCopy: [:], runningApps: [], fullAccess: true) }
            time("check them all, while ticking", rounds: 3) { _ = PlanChecks.run(items: everything, trueBytes: [:], otherCopy: [:], runningApps: [], fullAccess: true, fresh: false) }
            let tops = model.flatRows.filter(\.isPlannable).flatMap(\.nodes)
            print("bench \(tops.count) nodes in those")
            time("what they'd free", rounds: 3) { _ = Accounting.effect(of: tops, except: [], in: tree) }
            let effect = Accounting.effect(of: tops, except: [], in: tree)
            time("the disk as it'd be after", rounds: 3) { _ = AfterPlan(tree: tree, ids: tops, excluded: [], effect: effect) }
            time("the other copies of each", rounds: 1) { for row in model.flatRows { _ = Accounting.otherCopies(of: row.nodes, in: tree) } }
            if let volume = model.volume { time("save the map", rounds: 1) { TreeCache.save(tree, for: volume) } }
            if let volume = model.volume { time("read the saved map", rounds: 3) { _ = TreeCache.load(for: volume) } }
            time("gather facts, afresh", rounds: 1) { _ = Facts.gather(tree: tree, running: [], fullAccess: true, reusing: nil) }
            time("gather facts, again", rounds: 2) { _ = Facts.gather(tree: tree, running: [], fullAccess: true, reusing: facts) }
            time("newest change, 40,000 files", rounds: 1) { _ = Walker.newestChange(in: home + "/Library", limit: 40_000) }
            time("size of ~/Media", rounds: 3) { _ = Walker.size(of: home + "/Media") }
            time("size of ~/dev", rounds: 1) { _ = Walker.size(of: home + "/dev") }
            time("size of ~/Library", rounds: 1) { _ = Walker.size(of: home + "/Library") }
            time("suggestions", rounds: 3) { _ = Wins.build(tree: tree, rules: model.rules, running: [], facts: facts) }
            let all = Wins.build(tree: tree, rules: model.rules, running: [], facts: facts)
            time("sorting them into boxes", rounds: 3) { _ = Sections.build(from: all, tree: tree, facts: facts) }
            time("changes map", rounds: 3) { _ = ChangeMap(tree: tree, window: model.changeWindow) }
            time("untouched for a year", rounds: 3) { _ = AppModel.changeMap(tree: tree, window: .untouched(365), rules: model.rules, facts: model.facts) }
            // What you've used lately counts as touched, so it has to be found on the map.
            let known = model.facts
            let since = Date().addingTimeInterval(-91 * 86_400)
            let apps = known.apps.filter { $0.isRunning || ($0.newestSign ?? .distantPast) >= since }.count
            let watched = known.plexFiles.values.filter { ($0.lastViewed ?? .distantPast) >= since }.count
            let played = known.games.filter { ($0.lastPlayed ?? .distantPast) >= since }.count
            let opened = known.lastOpened.values.filter { $0 >= since }.count
            let found = ChangeMap.usedRecently(known, in: tree, days: 91).count
            print("used in the last 3 months: \(apps) apps, \(watched) watched, \(played) played, \(opened) opened; \(found) of them found on the map")
        case "refreshcheck":
            // A refresh of the map on screen, then a full read straight after, and what differs between them. Reads only.
            guard let tree = model.tree, let volume = model.volume, let journal = model.journal, journal.base == tree.journal else {
                print("refreshcheck: nothing to refresh (whole \(model.tree?.isWhole ?? false), journal \(model.journal != nil))")
                return
            }
            let rules = model.rules
            let access = model.hasFullAccess
            let result = await Task.detached(priority: .userInitiated) { () -> String in
                Self.compareRefresh(of: tree, volume: volume, journal: journal, rules: rules, fullAccess: access)
            }.value
            print(result)
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
            // window 7 is the last week, 0 the last scan, and -365 what's been untouched for a year.
            if let d = Int(argument) { model.setChangeWindow(d == 0 ? .lastScan : d < 0 ? .untouched(-d) : .days(d)) }
        case "search":
            model.searchActive = true
            model.searchText = argument
            model.runSearch()
        case "panel":
            model.panelOpen = argument != "off"
        case "size":
            let numbers = argument.split(separator: " ").compactMap { Double($0) }
            if numbers.count == 2 || numbers.count == 4, let w = mainWindow {
                var frame = w.frame
                frame.origin.y += frame.height - numbers[1]
                frame.size = CGSize(width: numbers[0], height: numbers[1])
                if numbers.count == 4, let screen = w.screen ?? NSScreen.main {
                    frame.origin = CGPoint(x: screen.frame.minX + numbers[2], y: screen.frame.maxY - numbers[3] - numbers[1])
                }
                w.setFrame(frame, display: true)
            }
        case "timescale":
            model.engine.timeScale = Float(argument) ?? 1
        case "checkupdates":
            Updater.shared.checkNow()
            Updater.shared.bringForward()
        case "installupdate":
            if case .available(let release) = Updater.shared.state { Updater.shared.install(release) } else { print("no update to install: \(Updater.shared.state)") }
        case "signedlikethis":
            // Whether the updater would take the app at this path.
            print("signed like this app: \(Updater.isSignedLikeThis(URL(fileURLWithPath: argument))) — \(argument)")
        case "updatestate":
            print("update state \(Updater.shared.state)")
        case "shotwindow":
            // A picture of another window, by its title: "shotwindow Update Headroom /path.png".
            guard let cut = argument.range(of: " /") else { print("shotwindow needs a title and a path"); return }
            let title = String(argument[..<cut.lowerBound]), path = String(argument[argument.index(after: cut.lowerBound)...])
            guard let w = NSApp.windows.first(where: { $0.title == title && $0.isVisible }) else { print("no window called \(title)"); return }
            await picture(of: w, to: path)
            print("shot \(path)")
        case "shot":
            guard let w = mainWindow else { print("no window"); return }
            await picture(of: w, to: argument)
            print("shot \(argument)")
        case "leaks":
            findLeaks(in: model)
        case "format":
            // format wide|narrow|auto: the picture on screen in one format, for comparing them.
            MapHostView.forcedFormat = argument == "wide" ? MapRenderer.outputFormat : argument == "narrow" ? MapRenderer.narrowOutputFormat : nil
            model.engine.requestFrame()
            try? await Task.sleep(for: .milliseconds(400))
        case "gpu":
            // What the GPU holds for the ring, texture by texture.
            print("gpu \(model.engine.allocations())")
        case "headroom":
            // How far above white this screen can go now, and at most: what the picture's format has to hold.
            if let screen = mainWindow?.screen {
                print("headroom now \(screen.maximumExtendedDynamicRangeColorComponentValue), at most \(screen.maximumPotentialExtendedDynamicRangeColorComponentValue), reference \(screen.maximumReferenceExtendedDynamicRangeColorComponentValue)")
            }
        case "labelpoint":
            // labelpoint 2: the pointer arrives on the name around the ring with this number, and moves a little while it's there.
            guard let w = mainWindow, let at = labelPoint(argument, model) else { print("no such name: \(argument)"); return }
            func move(_ x: Double, _ y: Double) {
                let p = NSPoint(x: x, y: w.frame.height - y)
                guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return }
                w.contentView?.superview?.hitTest(p)?.mouseMoved(with: event)
                model.mapView?.mouseMoved(with: event)
            }
            let label = at.label
            print("name \"\(label.title)\" at \(Int(at.x)),\(Int(at.y)), lands on \(w.contentView?.superview?.hitTest(NSPoint(x: at.x, y: w.frame.height - at.y)).map { String(describing: type(of: $0)).prefix(24) } ?? "nothing")")
            model.enterLabel(piece: label.pieceIndex)
            print("arrived: lit \(model.hover?.title ?? "nothing")")
            move(at.x, at.y)
            try? await Task.sleep(for: .milliseconds(60))
            print("after a small move: lit \(model.hover?.title ?? "nothing")")
            move(at.x + 2, at.y)
            try? await Task.sleep(for: .milliseconds(60))
            print("after another: lit \(model.hover?.title ?? "nothing")")
        case "labelleave":
            // labelleave 2: the pointer goes from that name to empty space beside the ring.
            guard let w = mainWindow, let at = labelPoint(argument, model) else { print("no such name: \(argument)"); return }
            model.leaveLabel(piece: at.label.pieceIndex)
            let p = NSPoint(x: 8, y: w.frame.height - 400)
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { model.mapView?.mouseMoved(with: event) }
            print("left: lit \(model.hover?.title ?? "nothing")")
        case "panelhover":
            // panelhover 2: the pointer on the row in the panel for that name, then moving about on the row a little.
            guard let w = mainWindow, let at = labelPoint(argument, model) else { print("no such name: \(argument)"); return }
            model.highlight(node: at.label.node)
            print("on the row for \"\(at.label.title)\": lit \(model.hover?.title ?? "nothing")")
            for nudge in [0.0, 3.0, 6.0] {
                let p = NSPoint(x: w.frame.width - 200 + nudge, y: w.frame.height - 500)
                if let event = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { model.mapView?.mouseMoved(with: event) }
                try? await Task.sleep(for: .milliseconds(60))
                print("  after a move on the row: lit \(model.hover?.title ?? "nothing")")
            }
            model.highlight(node: nil)
            print("off the row: lit \(model.hover?.title ?? "nothing")")
        case "ringpoint":
            // The pointer on the biggest piece of the ring itself.
            guard let w = mainWindow, let piece = model.engine.layout.pieces.filter({ !$0.isSmaller && !$0.isMark && $0.style == 0 }).max(by: { $0.bytes < $1.bytes }) else { return }
            let angle = Double(piece.a0 + piece.a1) / 2, radius = Double(piece.r0 + piece.r1) / 2 * model.ring.radius
            let p = NSPoint(x: model.ring.center.x + sin(angle) * radius, y: w.frame.height - (model.ring.center.y - cos(angle) * radius))
            print("ring: lands on \(w.contentView?.superview?.hitTest(p).map { String(describing: type(of: $0)).prefix(24) } ?? "nothing")")
            if let event = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { model.mapView?.mouseMoved(with: event) }
            print("on the ring: lit \(model.hover?.title ?? "nothing")")
        case "ringclick":
            // ringclick 2 2: a double-click on this piece of the ring, counting what can be clicked. `ringclick 2` is one click.
            let numbers = argument.split(separator: " ").map(String.init)
            let pieces = model.engine.layout.pieces.filter { !$0.isSmaller && !$0.isMark }
            guard let at = Int(numbers.first ?? ""), pieces.indices.contains(at), let tree = model.tree else { print("no such piece: \(argument)"); return }
            let piece = pieces[at]
            let angle = Double(piece.a0 + piece.a1) / 2, radius = Double(piece.r0 + piece.r1) / 2 * model.ring.radius
            print("on the ring at \"\(tree.name(piece.node))\", in \(model.displayName(model.focus)), \(model.plan.count) selected")
            await run("press", "\(model.ring.center.x + sin(angle) * radius) \(model.ring.center.y - cos(angle) * radius) \(numbers.count > 1 ? numbers[1] : "1")", model)
            try? await Task.sleep(for: .milliseconds(700))
            print("now in \(model.displayName(model.focus)), selected thing \(model.selected.map(model.displayName) ?? "none"), \(model.plan.count) selected")
        case "labelclick":
            // labelclick 2: what a click on that name does. `labelclick 2 2` is the second click of a double-click.
            let numbers = argument.split(separator: " ").map(String.init)
            guard let at = labelPoint(numbers.first ?? "", model) else { print("no such name: \(argument)"); return }
            print("clicking \"\(at.label.title)\", in \(model.displayName(model.focus)), \(model.plan.count) selected")
            model.openLabel(piece: at.label.pieceIndex, count: numbers.count > 1 ? Int(numbers[1]) ?? 1 : 1)
            try? await Task.sleep(for: .milliseconds(700))
            print("now in \(model.displayName(model.focus)), selected thing \(model.selected.map(model.displayName) ?? "none"), \(model.plan.count) selected")
        case "busy":
            // busy anyway|cancel: what Send to Trash is asking, because something is using the folder, and the answer.
            print("busy: \(model.busyToSend.map { "\($0.title) is in use. \($0.why)" } ?? "nothing asked")")
            guard let busy = model.busyToSend else { return }
            if argument.hasPrefix("/") {
                // A picture of the question, which stays open.
                try? await Task.sleep(for: .milliseconds(500))
                if let sheet = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent != nil }) { await picture(of: sheet, to: argument) } else { print("no sheet to picture: \(NSApp.windows.map(\.title))") }
                return
            }
            model.busyToSend = nil
            if argument == "anyway" {
                model.sendAnyway(busy)
                while model.cleanProgress != nil { try? await Task.sleep(for: .milliseconds(50)) }
            }
        case "cleananyway":
            if let item = model.plan.items.first(where: { $0.paths.first == argument }) { model.acceptInUse(for: item.id) } else { print("no such planned thing: \(argument)") }
        case "button":
            // What the button under the Free Up list says, what's held back, and why.
            print("ready \(model.readyItems.count) of \(model.plan.count); held: \(model.heldBackItems.map { "\($0.title): \(model.checks[$0.id]?.problems.map(\.text) ?? [])" })")
        case "about":
            // about /path/to/picture.png: About Headroom from the app menu, as a click on it would open it.
            let titles = { NSApp.windows.filter(\.isVisible).map(\.title) }
            print("open before: \(titles())")
            guard let menu = NSApp.mainMenu?.items.first?.submenu, let at = menu.items.firstIndex(where: { $0.title == "About Headroom" }) else {
                print("no About item")
                return
            }
            menu.performActionForItem(at: at)
            try? await Task.sleep(for: .milliseconds(600))
            print("open after: \(titles())")
            guard let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "About Headroom" }) else {
                print("no About window")
                return
            }
            print("about: \(w.frame.size), resizable \(w.styleMask.contains(.resizable)), minimize \(w.standardWindowButton(.miniaturizeButton)?.isEnabled == true), zoom \(w.standardWindowButton(.zoomButton)?.isEnabled == true)")
            await picture(of: w, to: argument)
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
        case "look":
            if let node = resolve(argument, model) { model.openLook(node) } else { model.toggleLook() }
            try? await Task.sleep(for: .milliseconds(400))
        case "card":
            // What the card is showing, and what its first button would do.
            if let look = model.look, let tree = model.tree {
                print("card \(argument): \(model.realName(of: look.node)) on the \(look.onLeft ? "left" : "right"), \(model.lookRows(of: look.node, in: tree).count) rows, \(look.back.count) back, cursor \(model.lookCursor.map(String.init) ?? "none"), facts: \(model.facts(of: look.node) ?? "none"), lit: \(model.hover?.title ?? "nothing")")
            } else {
                print("card \(argument): closed")
            }
        case "keydown":
            // A key as the app gets it, not the menu bar: keydown 49 is space.
            guard let w = mainWindow, let code = UInt16(argument) else { return }
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code) {
                NSApp.sendEvent(event)
            }
            try? await Task.sleep(for: .milliseconds(120))
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
            print("frames drawn \(argument): \(model.mapView?.framesDrawn ?? -1), ring at \(model.engine.placeNow)")
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
            var flags: NSEvent.ModifierFlags = []
            if parts.first == "cmd" {
                parts.removeFirst()
                flags = .command
            }
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
                if let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1) {
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

    /// Somewhere on a name around the ring, by its number among those names.
    @MainActor
    private static func labelPoint(_ argument: String, _ model: AppModel) -> (label: MapLabel, x: Double, y: Double)? {
        let names = model.labels.filter { $0.place != .inside }
        guard let at = Int(argument), names.indices.contains(at) else { return nil }
        let label = names[at]
        return (label, label.position.x + (label.place == .right ? 18 : -18), label.position.y)
    }

    /// With --hide-names: everything the app has ready to show, checked against the real names on this disk. A hit is printed to
    /// be read, because a real folder can have an everyday name.
    @MainActor
    private static func findLeaks(in model: AppModel) {
        guard let tree = model.tree else { return }
        var real = Set<String>()
        for id in tree.displayNames.keys {
            let raw = tree.rawName(id).lowercased()
            guard raw.count >= 4, !raw.hasPrefix("/") else { continue }
            real.insert(raw)
            real.insert((raw as NSString).deletingPathExtension)
        }
        real.insert(NSUserName().lowercased())
        for volume in model.volumes where !volume.isBoot { real.insert(volume.name.lowercased()) }
        for disk in model.facts.knownDisks { real.insert(disk.lowercased()) }

        // Strings that are never shown: what things are known by, and where they are for doing something with them.
        let unshown: Set<String> = ["id", "command", "bundleID", "appPath", "previewPath", "otherCopiesPath", "extraPaths", "key"]
        var lines: [(place: String, text: String)] = []
        func collect(_ place: String, _ value: Any) {
            if let text = value as? String {
                lines.append((place, text))
                return
            }
            for child in Mirror(reflecting: value).children {
                if let label = child.label, unshown.contains(label) { continue }
                collect(place, child.value)
            }
        }
        // Everything big enough to have a name on screen, and what's right inside it.
        var things = model.flatTop(tree)
        for top in things.prefix(60) { things += tree.children(top).prefix(12) }
        for lens in [Lens.map, .changes, .freeUp] {
            model.setLens(lens)
            collect("list", model.shownRows)
            collect("names around the ring", model.makeLabels())
        }
        for window in [ChangeWindow.lastScan, .days(7), .days(30), .untouched(365)] {
            collect("changes", AppModel.changeMap(tree: tree, window: window, rules: model.rules, facts: model.facts).rows(tree: tree, rules: model.rules))
        }
        model.setLens(.map)
        collect("suggestions", model.flatRows)
        collect("boxes", Sections.build(from: Wins.build(tree: tree, rules: model.rules, running: [], facts: model.facts), tree: tree, facts: model.facts))
        collect("copy list", model.listText()?.text ?? "")
        for node in things {
            let thing = NamedThing(node)
            collect("name", [model.displayName(node), model.realName(of: node), tree.friendlyPath(node)])
            collect("menu", model.actions(for: thing).map(\.title))
            collect("delete menu", model.deleteActions(for: thing).map(\.title))
            collect("story", Accounting.story(node, in: tree))
            collect("middle of the ring", Accounting.hoverLine(node, bytes: tree.totals[Int(node)], in: tree) ?? "")
            collect("facts", LookContents.facts(of: node, in: tree))
            model.copyPath(of: thing)
            collect("tip", model.tip ?? "")
        }
        for query in ["a", "e", "s"] {
            for found in Search.run(query, in: tree).prefix(200) {
                collect("search", [tree.name(found), tree.path(tree.nodes[Int(found)].parent).map(DiskTree.friendly) ?? ""])
            }
        }
        collect("disks", model.volumes.map(\.shownName))

        var seen = Set<String>()
        var hits = 0
        for line in lines {
            let words = line.text.lowercased().split { " /,:;()\"“”›…·\n".contains($0) }.map { $0.hasSuffix(".") ? String($0.dropLast()) : String($0) }
            for start in words.indices {
                var run = ""
                for end in start..<min(start + 8, words.count) {
                    run += (end == start ? "" : " ") + words[end]
                    if real.contains(run), seen.insert(run + "|" + line.place).inserted {
                        hits += 1
                        print("leak? \"\(run)\" in \(line.place): \(line.text)")
                    }
                }
            }
        }
        print("leaks: looked at \(lines.count) lines against \(real.count) real names, \(hits) to read")
    }

    /// With the display off for a moment, as on a locked screen, a picture can fail. It works when it's back on.
    @MainActor
    private static func picture(of window: NSWindow, to path: String) async {
        for _ in 0..<8 where !FileManager.default.fileExists(atPath: path) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try? task.run()
            task.waitUntilExit()
            if !FileManager.default.fileExists(atPath: path) { try? await Task.sleep(for: .seconds(1)) }
        }
    }

    @MainActor
    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }
    }

    /// What a refresh costs and whether it comes out as a full read does. Between the two, the disk carries on changing, so
    /// what differs is listed where it starts, to tell a busy folder from a mistake.
    nonisolated private static func compareRefresh(of tree: DiskTree, volume: VolumeFacts, journal: ChangeJournal.Watcher, rules: RuleBook,
                                                   fullAccess: Bool) -> String {
        func seconds(_ since: DispatchTime) -> Double { Double(DispatchTime.now().uptimeNanoseconds - since.uptimeNanoseconds) / 1e9 }
        guard let facts = VolumeFacts.read(path: volume.mountPath) else { return "refreshcheck: no disk" }
        var out: [String] = []
        let asked = DispatchTime.now()
        guard let place = tree.journal, let taken = journal.take(from: place) else { return "refreshcheck: the journal lost track" }
        let askedFor = seconds(asked)
        let refresh = DiskScan(facts: facts, rules: rules, fullAccess: fullAccess)
        guard refresh.refresh(from: tree, changes: taken.changes, place: taken.next) else { return "refreshcheck: the refresh said no" }
        var folders = 0
        for i in 0..<tree.count where tree.nodes[i].has(NodeFlag.directory) { folders += 1 }
        let started = DispatchTime.now()
        refresh.run(mode: .full)
        out.append(String(format: "refresh %.2f s, after asking the journal for %.3f s: %d folders changed, %d with everything under; read %d of %d folders again, surprised: %@",
                          seconds(started), askedFor, taken.changes.folders.count, taken.changes.everythingUnder.count, refresh.foldersToRead, folders,
                          refresh.surprised ? "yes" : "no"))
        out.append("  read again: " + refresh.whyRead)
        guard !refresh.surprised else { return out.joined(separator: "\n") }
        let a = refresh.tree
        let saveStart = DispatchTime.now()
        TreeCache.save(a, for: facts)
        let saved = seconds(saveStart)
        let loadStart = DispatchTime.now()
        let loaded = TreeCache.load(for: facts)
        let size = (try? FileManager.default.attributesOfItem(atPath: TreeCache.url(facts.name).path)[.size] as? Int) ?? 0
        out.append(String(format: "saved map %.1f MB, saved in %.2f s, read back in %.2f s%@", Double(size) / 1e6, saved, seconds(loadStart),
                          loaded == nil ? ", but it didn't read back" : ""))
        let full = DiskScan(facts: facts, rules: rules, fullAccess: fullAccess)
        let fullStart = DispatchTime.now()
        full.run(mode: .full)
        out.append(String(format: "full read %.2f s", seconds(fullStart)))
        let b = full.tree

        // The same path has the same key in both.
        let keysA = vmAlloc(UInt64.self, max(a.count, 1)), keysB = vmAlloc(UInt64.self, max(b.count, 1))
        defer { vmFree(keysA, max(a.count, 1)); vmFree(keysB, max(b.count, 1)) }
        History.fillKeys(tree: a, into: keysA)
        History.fillKeys(tree: b, into: keysB)
        var inB = [UInt64: UInt32](minimumCapacity: b.count)
        for i in 0..<b.count { inB[keysB[i]] = UInt32(i) }
        let differs = Mapped<Bool>(count: a.count)
        var differing = 0, missing = 0
        for i in 0..<a.count {
            guard let j = inB[keysA[i]] else { differs[i] = true; missing += 1; continue }
            if a.totals[i] != b.totals[Int(j)] || a.totalFiles[i] != b.totalFiles[Int(j)] { differs[i] = true; differing += 1 }
        }
        var sources: [(id: UInt32, change: Int64)] = []
        for i in 0..<a.count where differs[i] {
            var inside = false
            var c = a.nodes[i].firstChild
            while c != 0 { if differs[Int(c)] { inside = true; break }; c = a.nodes[Int(c)].nextSibling }
            if inside { continue }
            let other = inB[keysA[i]].map { Int64(b.totals[Int($0)]) } ?? 0
            sources.append((UInt32(i), Int64(a.totals[i]) - other))
        }
        let total = Int64(a.totals[0]) - Int64(b.totals[0])
        out.append("differences: \(differing) nodes add up differently, \(missing) only in the refresh, \(b.count - (a.count - missing)) only in the read; whole disk \(total) bytes; \(sources.count) places they start")
        for source in sources.sorted(by: { abs($0.change) > abs($1.change) }).prefix(12) {
            out.append("  \(source.change > 0 ? "+" : "")\(formatBytes(UInt64(abs(source.change)))) \(source.change < 0 ? "less" : "more") in the refresh: \(a.friendlyPath(source.id))")
        }
        let rowA = a.statRow(0), rowB = b.statRow(0)
        out.append("whole disk by kind and date, refresh: \((0..<DiskTree.statStride).map { String(rowA[$0]) }.joined(separator: " "))")
        out.append("whole disk by kind and date, read:    \((0..<DiskTree.statStride).map { String(rowB[$0]) }.joined(separator: " "))")
        out.append("links \(a.links.count) and \(a.singleLinks.count) single in the refresh, \(b.links.count) and \(b.singleLinks.count) in the read")
        return out.joined(separator: "\n")
    }

    @MainActor
    private static func report(_ model: AppModel) {
        guard let tree = model.tree else { print("no tree"); return }
        print(String(format: "scan %.2fs, %d files, %d nodes, %d link records", tree.scanSeconds, tree.totalFiles[0], tree.count, tree.links.count))
        if tree.isPartial { print("still reading \(formatBytes(tree.totals[Int(tree.hidden)])), \(model.scanFiles) files so far") }
        print(String(format: "pieces %d, labels %d, last scan loaded in %.1f ms", model.engine.layout.pieces.count, model.labels.count, model.cacheLoadMilliseconds))
        print("last scan \(model.lastScanNote); read in full \(Int(Date().timeIntervalSince(tree.fullReadAt))) s ago, journal \(tree.journal == nil ? "none" : "kept"), whole \(tree.isWhole)")
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
