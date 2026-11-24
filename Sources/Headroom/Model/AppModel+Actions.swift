import AppKit
import SwiftUI

/// Something on screen with a name. Nearly always one file or folder, though a row in Free Up can stand for several.
struct NamedThing {
    var nodes: [UInt32]
    /// What to call it when it's several, or when what it stood for has gone.
    var title: String?
    /// What selecting it means, when that's more than selecting one file or folder.
    var toggle: (() -> Void)?

    init(_ node: UInt32) { nodes = [node] }

    init(nodes: [UInt32], title: String, toggle: (() -> Void)? = nil) {
        self.nodes = nodes
        self.title = title
        self.toggle = toggle
    }

    var single: UInt32? { nodes.count == 1 ? nodes[0] : nil }
}

/// One thing you can do with something that has a name. It's the same list wherever that name is on screen.
struct ThingAction: Identifiable {
    let title: String
    let symbol: String
    var shortcut: KeyboardShortcut?
    /// With a line above it in the menu.
    var startsGroup = false
    /// A grey line that only says something.
    var isNote = false
    /// A submenu instead, so that what's in it takes a second, deliberate step.
    var submenu: [ThingAction] = []
    var run: () -> Void = {}
    var id: String { title }
}

/// Where you were: the folder on the ring, and what's selected in it.
struct Visit: Equatable {
    var focus: UInt32 = 0
    var selected: UInt32?
}

extension KeyboardShortcut {
    static let copyName = KeyboardShortcut("c")
    static let copyPath = KeyboardShortcut("c", modifiers: [.command, .option])
    static let copyList = KeyboardShortcut("c", modifiers: [.command, .shift])
    static let openThing = KeyboardShortcut("o")
    static let revealThing = KeyboardShortcut("r", modifiers: [.command, .option])
    static let quickLook = KeyboardShortcut("y")
    static let selectThing = KeyboardShortcut(.delete, modifiers: .command)
}

/// The words that get copied.
enum ThingText {

    /// The name on disk, which can be plainer than what the ring calls it.
    static func name(ofPath path: String) -> String { (path as NSString).lastPathComponent }

    /// A list you can paste: what it is, then a name and a size to a line. A tab between them lets a spreadsheet take it too.
    static func list(title: String, rows: [(name: String, size: String)]) -> String {
        ([title] + rows.map { "\($0.name)\t\($0.size)" }).joined(separator: "\n")
    }
}

extension AppModel {
    // MARK: What an action applies to

    /// What you're pointing at, otherwise what's selected, otherwise the folder you're in.
    var actionTarget: NamedThing {
        if let pointedThing { return pointedThing }
        if let look { return NamedThing(look.node) }
        let pieces = engine.layout.pieces
        if let hover, hover.pieceIndex < pieces.count, !pieces[hover.pieceIndex].isSmaller, tree?.path(hover.node) != nil {
            return NamedThing(hover.node)
        }
        return NamedThing(selected ?? focus)
    }

    /// What a node the ring points to stands for, for its menu or a ⌘-click: the middle is the folder you're in, and a piece
    /// is its thing when it has a place on the disk.
    func thing(onRing node: UInt32) -> NamedThing? {
        if node == focus { return NamedThing(focus) }
        guard tree?.path(node) != nil else { return nil }
        return NamedThing(node)
    }

    func realName(of node: UInt32) -> String {
        if node == 0 { return volume?.shownName ?? "Disk" }
        guard !HiddenNames.isOn, let path = tree?.path(node) else { return displayName(node) }
        return ThingText.name(ofPath: PathMath.visible(path))
    }

    func realPath(of node: UInt32) -> String? {
        if node == 0 { return volume?.mountPath }
        return tree?.path(node).map(PathMath.visible)
    }

    // MARK: The list

    /// What a right-click offers, wherever the name is.
    func actions(for thing: NamedThing) -> [ThingAction] {
        guard let tree else { return [] }
        var list: [ThingAction] = []
        func add(_ title: String, _ symbol: String, _ shortcut: KeyboardShortcut? = nil, startsGroup: Bool = false, _ work: @escaping () -> Void) {
            list.append(ThingAction(title: title, symbol: symbol, shortcut: shortcut, startsGroup: startsGroup, run: stillThisScan(tree, work)))
        }

        add("Copy Name", "textformat", .copyName) { self.copyName(of: thing) }
        let paths = thing.nodes.compactMap(realPath(of:))
        guard !paths.isEmpty else { return list }
        add(paths.count == 1 ? "Copy Path" : "Copy Paths", "doc.on.doc", .copyPath) { self.copyPath(of: thing) }

        guard let node = thing.single, let path = paths.first else {
            add("Show in Finder", "folder", .revealThing, startsGroup: true) { self.reveal(thing) }
            if thing.toggle != nil { list.append(selectAction(for: thing, startsGroup: true, tree: tree)) }
            return list
        }

        add("Open", "arrow.up.forward.app", .openThing, startsGroup: true) { self.open(thing) }
        add("Show in Finder", "folder", .revealThing) { self.reveal(thing) }
        add("Quick Look", "eye", .quickLook) { self.openLook(thing) }
        if node == 0 || tree.nodes[Int(node)].has(NodeFlag.directory) {
            add("Open in Terminal", "terminal") { self.openInTerminal(path) }
        }
        if node != 0 {
            let name = realName(of: node)
            add("Find Others With This Name", "magnifyingglass") { self.findOthers(named: name) }
        }
        if node != 0, !tree.links.isEmpty {
            for place in storyForMenu(node, in: tree).placesWorthNaming(size: tree.totals[Int(node)]) {
                add("Go to \(place.path)", "arrow.right") { self.goToPlace(place.node) }
            }
        }

        let deleting = deleteActions(for: thing)
        if !deleting.isEmpty {
            list.append(ThingAction(title: "Delete", symbol: "trash", startsGroup: true, submenu: deleting))
        }
        if node != 0, let raw = tree.path(node), Safety.canTrash(raw) {
            for disk in otherDisks(for: raw) {
                add("Move to \(disk.name)", "externaldrive") { self.planMove(node: node, to: disk) }
            }
        }
        return list
    }

    /// What's in the Delete submenu. Sending something to the Trash takes that second step on purpose, and has no shortcut.
    func deleteActions(for thing: NamedThing) -> [ThingAction] {
        guard let tree, let node = thing.single, node != 0, let raw = tree.path(node) else { return [] }
        guard Safety.canTrash(raw) else {
            let isFolder = tree.nodes[Int(node)].firstChild != 0
            let why = isFolder ? "Protected folder: open it to choose items" : "Protected"
            return [ThingAction(title: why, symbol: "lock", isNote: true)]
        }
        return [
            ThingAction(title: "Move to Trash", symbol: "trash", run: stillThisScan(tree) { self.sendToTrash(thing) }),
            ThingAction(title: freesText(node, in: tree), symbol: "info.circle", isNote: true),
            selectAction(for: thing, startsGroup: true, tree: tree),
        ]
    }

    private func selectAction(for thing: NamedThing, startsGroup: Bool, tree: DiskTree) -> ThingAction {
        let isOn = mode == .backup ? backupPlanned() : plannedTest()
        let planned = thing.nodes.allSatisfy { isOn($0) }
        return ThingAction(
            title: planned ? "Deselect" : "Select", symbol: planned ? "minus.circle" : "plus.circle", shortcut: .selectThing,
            startsGroup: startsGroup, run: stillThisScan(tree) { self.toggleSelection(of: thing) })
    }

    /// What you'd really get back, said before you choose.
    private func freesText(_ node: UInt32, in tree: DiskTree) -> String {
        let size = tree.totals[Int(node)]
        guard !tree.links.isEmpty else { return "Frees \(formatBytes(size)) once the Trash is emptied" }
        let story = storyForMenu(node, in: tree)
        if Double(story.reclaim) < Double(size) * 0.9, let place = story.sharedPlace {
            return "Frees \(formatBytes(story.reclaim)): hardlinked or cloned with \(place)"
        }
        return "Frees \(formatBytes(story.reclaim)) once the Trash is emptied"
    }

    /// What a menu says about a thing's hard links and clones takes a pass over every link on the disk, and one menu asks
    /// twice: for what it frees, and for where its other copies are.
    private func storyForMenu(_ node: UInt32, in tree: DiskTree) -> LinkStory {
        if let known = menuStory, known.node == node, known.version == treeVersion { return known.story }
        let story = Accounting.story(node, in: tree)
        menuStory = (node, treeVersion, story)
        return story
    }

    /// The map can change while a menu is open, and node numbers only mean something in the scan they came from.
    private func stillThisScan(_ tree: DiskTree, _ work: @escaping () -> Void) -> () -> Void {
        let scan = tree.scanID
        return { [weak self] in
            guard self?.tree?.scanID == scan else { return }
            work()
        }
    }

    /// The same list, for the ring, which is drawn by AppKit.
    func menu(for thing: NamedThing) -> NSMenu? {
        let actions = actions(for: thing)
        guard !actions.isEmpty else { return nil }
        return nsMenu(of: actions)
    }

    private func nsMenu(of actions: [ThingAction]) -> NSMenu {
        let menu = NSMenu()
        for action in actions {
            if action.startsGroup { menu.addItem(.separator()) }
            let item = NSMenuItem(title: action.title, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)
            if !action.submenu.isEmpty {
                item.submenu = nsMenu(of: action.submenu)
            } else if !action.isNote {
                item.action = #selector(MenuTarget.run(_:))
                item.target = MenuTarget.shared
                item.representedObject = MenuAction(action.run)
            }
            if let shortcut = action.shortcut {
                item.keyEquivalent = String(shortcut.key.character)
                var flags: NSEvent.ModifierFlags = []
                if shortcut.modifiers.contains(.command) { flags.insert(.command) }
                if shortcut.modifiers.contains(.option) { flags.insert(.option) }
                if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
                item.keyEquivalentModifierMask = flags
            }
            menu.addItem(item)
        }
        return menu
    }

    // MARK: Copying

    /// A scripted check keeps to a clipboard of its own, so that running one never costs you what you'd copied.
    static let clipboard = ScriptRunner.path == nil ? NSPasteboard.general : NSPasteboard(name: NSPasteboard.Name("Headroom-check"))

    private func copy(_ text: String, saying note: String) {
        Self.clipboard.clearContents()
        Self.clipboard.setString(text, forType: .string)
        showTip(note, for: 1.8)
    }

    func copyName(of thing: NamedThing) {
        let name = thing.single.map(realName(of:)) ?? thing.title ?? ""
        guard !name.isEmpty else { return }
        copy(name, saying: "Copied: \(name)")
    }

    func copyPath(of thing: NamedThing) {
        let paths = thing.nodes.compactMap(realPath(of:)).map { HiddenNames.isOn ? DiskTree.friendly($0) : $0 }
        guard let first = paths.first else {
            showTip("\(thing.title ?? thing.single.map(displayName) ?? "This") has no path.")
            return
        }
        copy(paths.joined(separator: "\n"), saying: paths.count == 1 ? "Copied: \(first)" : "Copied \(paths.count) paths")
    }

    func copyList() {
        guard let list = listText() else {
            showTip("Nothing to copy.")
            return
        }
        copy(list.text, saying: "Copied \(list.count) \(list.count == 1 ? "line" : "lines")")
    }

    /// What the side panel is listing, as text.
    func listText() -> (text: String, count: Int)? {
        guard let tree else { return nil }
        let most = 1000
        var title: String
        var rows: [(name: String, size: String)] = []
        if isSearching {
            title = "\"\(searchText)\": \(searchResults.count.formatted()) found" + (searchFolderName.map { " in " + $0 } ?? "")
            rows = searchResults.prefix(most).map { (tree.friendlyPath($0), formatBytes(tree.totals[Int($0)])) }
        } else {
            // What the panel shows: the mode's, or in Copies with Free Up, the duplicates.
            switch mode == .backup ? Lens.backup : (view == .copies ? Lens.copies : Lens.freeUp) {
            case .map, .changes, .freeUp:
                title = "Free Up"
                rows = boxes.flatMap(\.rows).prefix(most).map { ($0.title, formatBytes($0.gain)) }
            case .backup:
                title = "Backup" + (backup.destination.map { " to " + $0.title } ?? "")
                rows =
                    backup.items.prefix(most).map { (DiskTree.friendly($0.path), formatBytes($0.bytes)) }
                    + movedNotes.prefix(most).map { ("Moved: " + DiskTree.friendly($0.originalPath) + " → " + $0.driveName, formatBytes($0.size)) }
            case .copies:
                title = focus == 0 ? "Copies" : "Copies in " + displayName(RingLayout.chainTail(tree: tree, focus))
                // Every copy and name of each, where it is, so the list says everything the panel does.
                rows = copyGroupsHere.prefix(most).flatMap { g -> [(name: String, size: String)] in
                    let value = g.kind == .duplicate ? formatBytes(g.back) + " back" : g.kind.title.lowercased()
                    let places = g.nodes.map { "  " + tree.friendlyPath($0) }
                    return [(g.title, value)] + places.map { ($0, "") }
                }
            }
        }
        guard !rows.isEmpty else { return nil }
        return (ThingText.list(title: title, rows: rows), rows.count)
    }

    /// A row in one of the inspector's lists was clicked. A folder with something in it is gone into. Anything else is
    /// selected, in the folder it's in: a list that reaches beyond the folder in view goes there first.
    func openFromList(_ node: UInt32, goingToItsFolder: Bool = true) {
        guard let tree else { return }
        let n = tree.nodes[Int(node)]
        if n.has(NodeFlag.directory) && n.firstChild != 0 {
            zoom(into: RingLayout.chainTail(tree: tree, node))
        } else {
            if goingToItsFolder { zoom(into: n.parent) }
            selected = node
        }
    }

    /// What the whole disk's list shows: what's at the top, with your home folder and macOS's groups opened up, biggest first.
    func flatTop(_ tree: DiskTree) -> [UInt32] {
        var all: [UInt32] = []
        for top in tree.children(0) where top != tree.free && top != tree.hidden {
            let n = tree.nodes[Int(top)]
            if top == tree.home || n.has(NodeFlag.synthetic) { all += tree.children(top) } else { all.append(top) }
        }
        return all.filter { tree.totals[Int($0)] > 0 }.sorted { tree.totals[Int($0)] > tree.totals[Int($1)] }
    }

    // MARK: Handing things over

    /// Another app's job. A scripted check only says what it would have asked for.
    private func handOver(_ description: String, _ work: () -> Void) {
        if ScriptRunner.path != nil {
            print("would \(description)")
        } else {
            work()
        }
    }

    func reveal(_ node: UInt32) { reveal(NamedThing(node)) }

    func reveal(_ thing: NamedThing) {
        let paths = thing.nodes.compactMap(realPath(of:))
        guard !paths.isEmpty else { return }
        handOver("reveal \(paths)") { NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) }) }
    }

    func open(_ thing: NamedThing) {
        guard let path = thing.single.flatMap(realPath(of:)) else { return }
        handOver("open \(path)") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }

    // MARK: Small files

    /// A small file isn't on the map, so it goes by where it is: its folder's path and its name.
    func path(of file: SmallFile) -> String? { file.folderPath.isEmpty ? nil : (file.folderPath == "/" ? "/" : file.folderPath + "/") + file.name }

    func open(_ file: SmallFile) {
        guard let path = path(of: file) else { return }
        handOver("open \(path)") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }

    func reveal(_ file: SmallFile) {
        guard let path = path(of: file) else { return }
        handOver("reveal \(path)") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }

    func copyPath(of file: SmallFile) {
        guard let path = path(of: file).map({ HiddenNames.isOn ? DiskTree.friendly($0) : $0 }) else { return }
        copy(path, saying: "Copied: \(path)")
    }

    private func openInTerminal(_ path: String) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        handOver("open \(path) in Terminal") {
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: What comes back next time

    /// The inspector, shown or hidden and how wide, and the view you were in come back next time, as in Apple's apps, and
    /// so do the window's size and place, through the scene in `HeadroomApp`. A scripted check starts the same way every
    /// time, and leaves yours alone, unless it's started with `--remember-window`.
    static let remembersWindow = ScriptRunner.path == nil || CommandLine.arguments.contains("--remember-window")
    private static let inspectorShownKey = "inspectorShown", inspectorWidthKey = "inspectorWidth", viewKey = "view", modeKey = "mode"

    /// How wide the inspector opens: as you last left it, or wide enough for Free Up.
    static var savedInspectorWidth: CGFloat {
        let saved = remembersWindow ? UserDefaults.standard.double(forKey: inspectorWidthKey) : 0
        return saved >= 340 && saved <= 520 ? saved : SidePanel.idealWidth
    }

    /// The view and the inspector as you left them. Both are read first, because going to the view saves the window as it
    /// is at that moment.
    func restoreWindow() {
        guard Self.remembersWindow else { return }
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: Self.viewKey).flatMap(Lens.init(rawValue:))
        let savedMode = defaults.string(forKey: Self.modeKey).flatMap(Lens.init(rawValue:))
        let shown = defaults.object(forKey: Self.inspectorShownKey) as? Bool
        if let saved { setLens(saved) }
        if let savedMode { setMode(savedMode) }
        if let shown { panelOpen = shown }
    }

    func rememberWindow() {
        guard Self.remembersWindow else { return }
        UserDefaults.standard.set(panelOpen, forKey: Self.inspectorShownKey)
        UserDefaults.standard.set(view.rawValue, forKey: Self.viewKey)
        UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
    }

    /// The inspector's width once it has settled, so neither its slide nor a drag still going on is what's kept.
    func noteInspectorWidth(_ width: CGFloat) {
        guard Self.remembersWindow else { return }
        inspectorWidthTask?.cancel()
        inspectorWidthTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, self.panelOpen, width >= 340, width <= 520 else { return }
            UserDefaults.standard.set(Double(width), forKey: Self.inspectorWidthKey)
        }
    }

    // MARK: Going places

    /// The inspector slides in or out the same way whatever asks: its button, the menu, a search or a click on a file.
    func showPanel(_ open: Bool) {
        guard open != panelOpen else { return }
        // With Reduce Motion it's just there, or gone.
        if Motion.isReduced { panelOpen = open } else { Motion.animate(.smooth(duration: 0.25)) { panelOpen = open } }
    }

    private func findOthers(named name: String) {
        searchActive = true
        showPanel(true)
        searchText = name
        runSearch()
    }

    /// The other side of a hard link or a clone. Back comes back here.
    private func goToPlace(_ node: UInt32) {
        guard let tree else { return }
        zoom(into: RingLayout.chainTail(tree: tree, node))
    }

    // MARK: Selecting

    /// Whether this can be sent to the Trash as it is, which the Delete submenu and the File menu both go by.
    func canSendToTrash(_ node: UInt32) -> Bool {
        guard node != 0, let tree, let raw = tree.path(node) else { return false }
        return Safety.canTrash(raw)
    }

    /// What Send to Trash in the File menu means right now, where the pointer can't be on anything else.
    var trashTitle: String {
        let node = selected ?? focus
        return node == 0 ? "Move to Trash" : "Move “\(realName(of: node))” to Trash"
    }

    // MARK: Back and forward

    var canGoBack: Bool { visitAt > 0 }
    var canGoForward: Bool { visitAt + 1 < visited.count }

    func goBack() { walkVisits(-1) }
    func goForward() { walkVisits(1) }

    /// ⌘← and ⌘→ do what the arrows at the top of the window do, in every view and with the card open. While you type, as in
    /// the search field, they're the text's: to the start or the end of the line.
    func watchBackAndForwardKeys() {
        guard backForwardWatch == nil else { return }
        backForwardWatch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 123 || event.keyCode == 124,
                event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
                let window = event.window, window === self.mapView?.window || window === LookPanel.shared.window,
                !(window.firstResponder is NSText)
            else { return event }
            if event.keyCode == 123 { self.goBack() } else { self.goForward() }
            return nil
        }
    }

    /// Skips anything that has gone since.
    private func walkVisits(_ step: Int) {
        guard let tree else { return }
        // Both sides are a picture of their own, numbered apart from the map: back goes up in it, and forward waits.
        if showsPair {
            if step < 0 { goUp() }
            return
        }
        func isThere(_ node: UInt32) -> Bool { node == 0 || (Int(node) < tree.count && tree.totals[Int(node)] > 0) }
        var to = visitAt + step
        while visited.indices.contains(to) {
            let visit = visited[to]
            if isThere(visit.focus), visit.selected.map(isThere) ?? true {
                visitAt = to
                if visit.focus != focus {
                    if tree.isInside(visit.focus, focus) { zoom(into: visit.focus) } else { go(to: visit.focus) }
                }
                selected = visit.selected
                // With the card open, it goes back too, so it and the inspector still show the same thing.
                if look != nil { showInLook(visit.selected ?? focus, steppingIn: false) }
                return
            }
            to += step
        }
    }

    /// The folder and the selection often change together, so this looks once they've both settled.
    func visitChanged() {
        guard !visitPending else { return }
        visitPending = true
        DispatchQueue.main.async { [weak self] in self?.noteVisit() }
    }

    /// Going up to where you just came from is going back, so forward still leads down again.
    private func noteVisit() {
        visitPending = false
        // Places in the picture of both sides aren't places on the map.
        guard !showsPair else { return }
        let here = Visit(focus: focus, selected: selected)
        guard visited[visitAt] != here else { return }
        if visitAt > 0, visited[visitAt - 1] == here {
            visitAt -= 1
        } else if visitAt + 1 < visited.count, visited[visitAt + 1] == here {
            visitAt += 1
        } else {
            visited.removeSubrange((visitAt + 1)...)
            visited.append(here)
            if visited.count > 100 { visited.removeFirst(visited.count - 100) }
            visitAt = visited.count - 1
        }
    }

    /// A new scan numbers everything again, so what you visited is found again by path. What's gone is left out.
    func carryVisits(to new: DiskTree) {
        // The map the places were noted on, under whatever picture is on screen.
        guard let old = bareTree ?? tree else {
            resetVisits()
            return
        }
        var carried: [Visit] = []
        var at = 0
        for (index, visit) in visited.enumerated() {
            let focus = visit.focus == 0 ? 0 : old.path(visit.focus).flatMap { new.find(path: $0) }
            guard let focus else { continue }
            if index <= visitAt { at = carried.count }
            carried.append(Visit(focus: focus, selected: visit.selected.flatMap { old.path($0) }.flatMap { new.find(path: $0) }))
        }
        visited = carried.isEmpty ? [Visit()] : carried
        visitAt = min(at, visited.count - 1)
    }

    func resetVisits() {
        visited = [Visit()]
        visitAt = 0
    }

    func toggleSelection(of thing: NamedThing) {
        if let toggle = thing.toggle {
            Motion.animate(.snappy(duration: 0.18)) { toggle() }
            return
        }
        guard let node = thing.single, node != 0 else { return }
        if mode == .backup {
            // A folder is what's in it: Backup moves files.
            let isFolder = tree.map { $0.nodes[Int(node)].firstChild != 0 && !$0.isGhost(node) } ?? false
            Motion.animate(.snappy(duration: 0.2)) { isFolder ? toggleBackupFolder(node) : toggleBackup(node) }
            return
        }
        let before = isPlanned(node)
        Motion.animate(.snappy(duration: 0.2)) { togglePiece(node) }
        guard isPlanned(node) != before else { return }
        showTip(before ? "Deselected: \(displayName(node))" : "Selected: \(displayName(node))")
    }

    /// Space: selects what's under the pointer, or deselects it, for the mode you're in. With the card open and the pointer
    /// on nothing, it's what the card shows.
    func spaceSelect() {
        let pieces = engine.layout.pieces
        let hovered = hover.flatMap { $0.pieceIndex < pieces.count && !pieces[$0.pieceIndex].isSmaller ? NamedThing($0.node) : nil }
        guard let thing = pointedThing ?? hovered ?? look.map({ NamedThing($0.node) }) else {
            showTip("Point to an item first")
            return
        }
        toggleSelection(of: thing)
    }

    // MARK: The menu bar

    private var firstResponder: NSResponder? { (NSApp.keyWindow ?? mapView?.window)?.firstResponder }

    /// Selected text comes first, as it does in every other app. This asks what the Edit menu would ask.
    private var textToCopy: NSResponder? {
        let copy = #selector(NSText.copy(_:))
        var responder = firstResponder
        while let current = responder, !current.responds(to: copy) { responder = current.nextResponder }
        guard let responder else { return nil }
        let probe = NSMenuItem(title: "", action: copy, keyEquivalent: "")
        if let validating = responder as? NSMenuItemValidation { return validating.validateMenuItem(probe) ? responder : nil }
        if let validating = responder as? NSUserInterfaceValidations { return validating.validateUserInterfaceItem(probe) ? responder : nil }
        return responder
    }

    var wouldCopySelectedText: Bool { textToCopy != nil }

    func copyCommand() {
        if let textToCopy {
            handOver("copy the selected text") { NSApp.sendAction(#selector(NSText.copy(_:)), to: textToCopy, from: nil) }
        } else {
            copyName(of: actionTarget)
        }
    }

    /// While you're typing, ⌘⌫ means what it means in any text field.
    func selectCommand() {
        if firstResponder is NSText {
            NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
        } else {
            toggleSelection(of: actionTarget)
        }
    }
}
