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
    /// The path as macOS shows it, without the data volume your home folder really sits on.
    static func visible(_ path: String) -> String {
        path.hasPrefix("/System/Volumes/Data/") ? String(path.dropFirst("/System/Volumes/Data".count)) : path
    }

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

    /// What's on the ring at this spot. The middle of it is the folder you're in.
    func thing(at polar: (angle: Float, radius: Float)) -> NamedThing? {
        if polar.radius < RingLayout.hole { return NamedThing(focus) }
        let pieces = engine.layout.pieces
        guard let index = engine.layout.hit(angle: polar.angle, radius: polar.radius), index < pieces.count, !pieces[index].isSmaller,
              tree?.path(pieces[index].node) != nil else { return nil }
        return NamedThing(pieces[index].node)
    }

    func realName(of node: UInt32) -> String {
        if node == 0 { return volume?.shownName ?? "Disk" }
        guard !HiddenNames.isOn, let path = tree?.path(node) else { return displayName(node) }
        return ThingText.name(ofPath: ThingText.visible(path))
    }

    func realPath(of node: UInt32) -> String? {
        if node == 0 { return volume?.mountPath }
        return tree?.path(node).map(ThingText.visible)
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
            add("Reveal in Finder", "folder", .revealThing, startsGroup: true) { self.reveal(thing) }
            if thing.toggle != nil { list.append(selectAction(for: thing, startsGroup: true, tree: tree)) }
            return list
        }

        add("Open", "arrow.up.forward.app", .openThing, startsGroup: true) { self.open(thing) }
        add("Reveal in Finder", "folder", .revealThing) { self.reveal(thing) }
        add("Quick Look", "eye", .quickLook) { self.openLook(thing) }
        if node == 0 || tree.nodes[Int(node)].has(NodeFlag.directory) {
            add("Open in Terminal", "terminal") { self.openInTerminal(path) }
        }
        if node != 0 {
            let name = realName(of: node)
            add("Find Others With This Name", "magnifyingglass") { self.findOthers(named: name) }
        }
        if node != 0, !tree.links.isEmpty {
            for place in Accounting.story(node, in: tree).placesWorthNaming(size: tree.totals[Int(node)]) {
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
            let why = isFolder ? "Can't go as a whole. Open this folder to choose what's inside." : "Protected, so this can't go."
            return [ThingAction(title: why, symbol: "lock", isNote: true)]
        }
        return [
            ThingAction(title: "Send to Trash", symbol: "trash", run: stillThisScan(tree) { self.sendToTrash(thing) }),
            ThingAction(title: freesText(node, in: tree), symbol: "info.circle", isNote: true),
            selectAction(for: thing, startsGroup: true, tree: tree),
        ]
    }

    private func selectAction(for thing: NamedThing, startsGroup: Bool, tree: DiskTree) -> ThingAction {
        let isOn = plannedTest()
        let planned = thing.nodes.allSatisfy { isOn($0) }
        let place = lens == .freeUp ? "" : " in Free Up"
        return ThingAction(title: (planned ? "Unselect" : "Select") + place, symbol: planned ? "minus.circle" : "plus.circle", shortcut: .selectThing,
                           startsGroup: startsGroup, run: stillThisScan(tree) { self.toggleSelection(of: thing) })
    }

    /// What you'd really get back, said before you choose.
    private func freesText(_ node: UInt32, in tree: DiskTree) -> String {
        let size = tree.totals[Int(node)]
        guard !tree.links.isEmpty else { return "Frees \(formatBytes(size)) once the Trash is emptied" }
        let story = Accounting.story(node, in: tree)
        if Double(story.reclaim) < Double(size) * 0.9, let place = story.sharedPlace {
            return "Frees \(formatBytes(story.reclaim)): the same files are in \(place)"
        }
        return "Frees \(formatBytes(story.reclaim)) once the Trash is emptied"
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
            showTip("\(thing.title ?? thing.single.map(displayName) ?? "This") isn't a place on the disk.")
            return
        }
        copy(paths.joined(separator: "\n"), saying: paths.count == 1 ? "Copied: \(first)" : "Copied \(paths.count) paths")
    }

    func copyList() {
        guard let list = listText() else {
            showTip("There's no list to copy here.")
            return
        }
        copy(list.text, saying: "Copied the list: \(list.count) \(list.count == 1 ? "line" : "lines")")
    }

    /// What the side panel is listing, as text.
    func listText() -> (text: String, count: Int)? {
        guard let tree else { return nil }
        let most = 1000
        var title: String
        var rows: [(name: String, size: String)] = []
        if searchActive && !searchText.isEmpty {
            title = "\"\(searchText)\": \(searchResults.count.formatted()) found"
            rows = searchResults.prefix(most).map { (tree.friendlyPath($0), formatBytes(tree.totals[Int($0)])) }
        } else {
            switch lens {
            case .map:
                let folder = RingLayout.chainTail(tree: tree, focus)
                title = (focus == 0 ? realName(of: 0) : tree.friendlyPath(folder)) + ", " + formatBytes(tree.totals[Int(focus)])
                rows = panelNodes(tree).prefix(most).map { (displayName($0), tree.sizeText($0)) }
                let own = tree.nodes[Int(folder)].bytes
                if focus != 0, own > 0 { rows.append(("Smaller items here", formatBytes(own))) }
            case .changes:
                title = "What changed"
                rows = changeRows.prefix(most).map { ($0.title, "+" + formatBytes(UInt64(max($0.delta, 0)))) }
            case .freeUp:
                title = "Free Up"
                rows = boxes.flatMap(\.rows).prefix(most).map { ($0.title, formatBytes($0.gain)) }
            }
        }
        guard !rows.isEmpty else { return nil }
        return (ThingText.list(title: title, rows: rows), rows.count)
    }

    /// What the Map's list shows: what's in the folder you're in, or the biggest of everything at the top of the disk.
    func panelNodes(_ tree: DiskTree) -> [UInt32] {
        if focus == 0 { return flatTop(tree) }
        return tree.children(RingLayout.chainTail(tree: tree, focus)).filter { tree.totals[Int($0)] > 0 }
    }

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

    func openInTerminal(_ path: String) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        handOver("open \(path) in Terminal") {
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Going places

    func findOthers(named name: String) {
        searchActive = true
        panelOpen = true
        searchText = name
        runSearch()
    }

    /// The other side of a hard link or a clone. Back comes back here.
    func goToPlace(_ node: UInt32) {
        guard let tree else { return }
        zoom(into: RingLayout.chainTail(tree: tree, node))
    }

    // MARK: Selecting

    /// What Send to Trash in the File menu means right now, where the pointer can't be on anything else.
    /// Whether this can be sent to the Trash as it is, which the Delete submenu and the File menu both go by.
    func canSendToTrash(_ node: UInt32) -> Bool {
        guard node != 0, let tree, let raw = tree.path(node) else { return false }
        return Safety.canTrash(raw)
    }

    var trashTitle: String {
        let node = selected ?? focus
        return node == 0 ? "Send to Trash" : "Send “\(realName(of: node))” to Trash"
    }

    // MARK: Back and forward

    var canGoBack: Bool { visitAt > 0 }
    var canGoForward: Bool { visitAt + 1 < visited.count }

    func goBack() { walkVisits(-1) }
    func goForward() { walkVisits(1) }

    /// Skips anything that has gone since.
    private func walkVisits(_ step: Int) {
        guard let tree else { return }
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
        guard let old = tree else {
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
            withAnimation(.snappy(duration: 0.18)) { toggle() }
            return
        }
        guard let node = thing.single, node != 0 else { return }
        let before = isPlanned(node)
        withAnimation(.snappy(duration: 0.2)) { togglePiece(node) }
        guard isPlanned(node) != before else { return }
        showTip(before ? "Taken out: \(displayName(node))" : "Selected: \(displayName(node)). Nothing goes until you clean.")
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
