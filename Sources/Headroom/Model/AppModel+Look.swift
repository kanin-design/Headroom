import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The card Space opens: what something is, and what you can do about it.
struct Look: Equatable {
    var node: UInt32
    /// Where you stepped in from, inside the card.
    var back: [UInt32] = []
    /// Which side of the ring the card sits on, so that the piece it's about stays in sight.
    var onLeft = true
}

/// What the card works out about what it shows, beyond what the map knows: a film's or a picture's shape and size, when it
/// was last opened, and what deleting it would give back.
struct LookDetails: Equatable {
    var node: UInt32?
    /// Width over height, as shown, so the card's window can take that shape.
    var aspect: CGFloat?
    /// A film's length, pixels and frames a second, or a picture's pixels.
    var media: String?
    /// When it was last opened, watched or played, as far as macOS and the apps that keep count can say.
    var lastUse: String?
    /// What sending it to the Trash and emptying it would give back, with other copies counted.
    var frees: UInt64?
}

/// What the card shows. It all comes from the map, so nothing has to be counted again.
enum LookContents {
    static func isFolder(_ node: UInt32, in tree: DiskTree) -> Bool {
        node == 0 || tree.nodes[Int(node)].has(NodeFlag.directory)
    }

    /// What's inside, biggest first. A folder that's nearly all one folder shows what's in that one, as the ring does.
    static func rows(of node: UInt32, in tree: DiskTree) -> [UInt32] {
        guard isFolder(node, in: tree) else { return [] }
        return biggestFirst(tree.children(RingLayout.chainTail(tree: tree, node)), in: tree)
    }

    private static func biggestFirst(_ nodes: [UInt32], in tree: DiskTree) -> [UInt32] {
        nodes.filter { tree.totals[Int($0)] > 0 }.sorted { tree.totals[Int($0)] > tree.totals[Int($1)] }
    }

    /// The things next to this one, in the order the ring has them.
    static func siblings(of node: UInt32, in tree: DiskTree) -> [UInt32] {
        guard node != 0 else { return [] }
        return biggestFirst(tree.children(tree.nodes[Int(node)].parent), in: tree)
    }

    /// What to show once this has gone: the next one along, then the one before, then what held it.
    static func next(after node: UInt32, in tree: DiskTree) -> UInt32? {
        let row = siblings(of: node, in: tree)
        if let at = row.firstIndex(of: node) {
            if at + 1 < row.count { return row[at + 1] }
            if at > 0 { return row[at - 1] }
        }
        guard node != 0 else { return nil }
        let parent = tree.nodes[Int(node)].parent
        return parent == 0 ? nil : parent
    }

    /// The biggest photos and videos anywhere inside, when that's mostly what a folder is, so it can be recognised at a glance.
    static func media(in node: UInt32, tree: DiskTree, limit: Int = 6) -> [UInt32] {
        guard node != 0, isFolder(node, in: tree) else { return [] }
        let kinds = tree.kindBytes(node)
        let everything = kinds.reduce(0, +)
        let pictures = kinds[Int(Kind.image.rawValue)] &+ kinds[Int(Kind.video.rawValue)]
        guard everything > 0, pictures >= everything / 2 else { return [] }
        var found: [(node: UInt32, bytes: UInt64)] = []
        var folders = [node]
        var seen = 0
        while let folder = folders.popLast(), seen < 20_000 {
            var child = tree.nodes[Int(folder)].firstChild
            while child != 0 {
                seen += 1
                let n = tree.nodes[Int(child)]
                if n.has(NodeFlag.directory) {
                    folders.append(child)
                } else if canDraw(tree.name(child), kind: n.kind) {
                    found.append((child, max(n.bytes, n.aliasBytes)))
                }
                child = n.nextSibling
            }
        }
        return found.sorted { $0.bytes > $1.bytes }.prefix(limit).map(\.node)
    }

    /// macOS has no picture to give of the likes of .mkv, so those stay out.
    private static func canDraw(_ name: String, kind: UInt8) -> Bool {
        if kind == Kind.image.rawValue { return true }
        guard kind == Kind.video.rawValue else { return false }
        return ["mov", "mp4", "m4v"].contains((name as NSString).pathExtension.lowercased())
    }

    /// How many files and when something last changed, or what kind of file it is.
    static func facts(of node: UInt32, in tree: DiskTree) -> String? {
        guard node != 0 else { return nil }
        var bits: [String] = []
        if isFolder(node, in: tree) {
            let files = tree.totalFiles[Int(node)]
            if files > 0 { bits.append("\(files.formatted()) \(files == 1 ? "file" : "files")") }
        } else {
            let type = (tree.name(node) as NSString).pathExtension
            if !type.isEmpty, let words = UTType(filenameExtension: type)?.localizedDescription {
                bits.append(words.prefix(1).uppercased() + words.dropFirst())
            }
        }
        let newest = newestChange(of: node, in: tree)
        if newest > 0 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            bits.append("changed " + formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(newest)), relativeTo: Date()))
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private static func newestChange(of node: UInt32, in tree: DiskTree) -> UInt32 {
        var newest = tree.nodes[Int(node)].modTime
        guard isFolder(node, in: tree) else { return newest }
        var folders = [node]
        var seen = 0
        while let folder = folders.popLast(), seen < 300_000 {
            var child = tree.nodes[Int(folder)].firstChild
            while child != 0 {
                seen += 1
                let n = tree.nodes[Int(child)]
                newest = max(newest, n.modTime)
                if n.has(NodeFlag.directory) { folders.append(child) }
                child = n.nextSibling
            }
        }
        return newest
    }
}

extension AppModel {
    // MARK: Opening and closing

    func toggleLook() {
        if look != nil { closeLook() } else { openLook(actionTarget) }
    }

    func openLook(_ thing: NamedThing) {
        if let node = thing.single { openLook(node) }
    }

    func openLook(_ node: UInt32, onLeft keptSide: Bool? = nil) {
        guard tree != nil else { return }
        // On the far side of the ring from the piece it's about.
        var onLeft = true
        if let piece = engine.layout.pieces.first(where: { $0.node == node && !$0.isSmaller }), node != focus {
            onLeft = sin(piece.midAngle) >= 0
        }
        lookCursor = nil
        Motion.animate(.spring(response: 0.32, dampingFraction: 0.86)) { look = Look(node: node, onLeft: keptSide ?? onLeft) }
        LookPanel.shared.show(for: self)
        mapView?.window?.makeFirstResponder(mapView)
        watchLookEvents()
        setHover(lookPieceIndex)
    }

    func closeLook() {
        guard look != nil else { return }
        lookCursor = nil
        LookPanel.shared.hide()
        Motion.animate(.spring(response: 0.28, dampingFraction: 0.9)) { look = nil }
        if let lookWatch { NSEvent.removeMonitor(lookWatch) }
        lookWatch = nil
        pointedThing = nil
        setHover(nil)
        // A click on a preview gives it the keyboard, and it keeps it after the card has gone, so Space would no longer
        // reach the ring to open the card again. Unless you're typing in the search field, the keys go back to the ring.
        if let window = mapView?.window, !(window.firstResponder is NSText) { window.makeFirstResponder(mapView) }
    }

    /// What the card shows changed. It's selected, so the inspector says the same, and what the map doesn't know about it
    /// is worked out afresh, off the main thread.
    func lookMoved() {
        lookDetailsTask?.cancel()
        guard let look, let tree else {
            lookDetails = LookDetails()
            return
        }
        let node = look.node
        if node != 0, node != focus, selected != node { selected = node }
        lookDetails = LookDetails(node: node, frees: node == 0 ? nil : Accounting.reclaimable([node], in: tree))
        guard hasFullAccess, !HiddenNames.isOn, let path = realPath(of: node) else { return }
        let url = URL(fileURLWithPath: path)
        lookDetailsTask = Task { [weak self] in
            async let media = LookMedia.read(url)
            async let use = Task.detached(priority: .userInitiated) { LastUse.line(node, in: tree, orChange: false) }.value
            let (found, used) = await (media, use)
            guard let self, !Task.isCancelled, self.look?.node == node else { return }
            self.lookDetails.aspect = found?.aspect
            self.lookDetails.media = found?.text
            self.lookDetails.lastUse = used
        }
    }

    // MARK: Moving around

    /// Stepping in remembers where from. Moving along, or clicking something else on the ring, starts afresh.
    func showInLook(_ node: UInt32, steppingIn: Bool = true) {
        guard var current = look, current.node != node else { return }
        if steppingIn { current.back.append(current.node) } else { current.back = [] }
        current.node = node
        lookCursor = nil
        look = current
        setHover(lookPieceIndex)
    }

    func lookBack() {
        guard var current = look, let tree else { return }
        while let previous = current.back.popLast() {
            guard tree.totals[Int(previous)] > 0 || previous == 0 else { continue }
            current.node = previous
            lookCursor = nil
            look = current
            setHover(lookPieceIndex)
            return
        }
    }

    func stepLook(by step: Int) {
        guard let current = look, let tree else { return }
        let row = LookContents.siblings(of: current.node, in: tree)
        guard let at = row.firstIndex(of: current.node), row.indices.contains(at + step) else { return }
        showInLook(row[at + step], steppingIn: false)
    }

    /// Whether there's a list to move through. In a preview, the arrows belong to the preview.
    private func moveLookCursor(by step: Int) -> Bool {
        guard let current = look, let tree else { return false }
        let rows = lookRows(of: current.node, in: tree)
        guard !rows.isEmpty else { return false }
        let at = min(max(lookCursor.map { $0 + step } ?? (step > 0 ? 0 : rows.count - 1), 0), rows.count - 1)
        lookCursor = at
        setHover(engine.layout.pieces.firstIndex { $0.node == rows[at] && !$0.isSmaller })
        return true
    }

    func lookRows(of node: UInt32, in tree: DiskTree) -> [UInt32] {
        node == 0 ? flatTop(tree) : LookContents.rows(of: node, in: tree)
    }

    /// A folder with folders or big files in it can be gone into on the ring.
    func lookGoesIn(_ node: UInt32, in tree: DiskTree) -> Bool {
        node == 0 || (tree.nodes[Int(node)].has(NodeFlag.directory) && tree.nodes[Int(node)].firstChild != 0)
    }

    /// A double-click, Return and the card's first button: a file opens in its app, and the ring goes into a folder.
    func openLooked() {
        guard let node = look?.node, let tree else { return }
        guard lookGoesIn(node, in: tree) else {
            open(NamedThing(node))
            return
        }
        closeLook()
        if node == 0 {
            go(to: 0)
        } else {
            zoom(into: RingLayout.chainTail(tree: tree, node))
        }
    }

    private func lookPrimary() {
        guard let current = look, let tree else { return }
        if let lookCursor {
            let rows = lookRows(of: current.node, in: tree)
            if rows.indices.contains(lookCursor) {
                showInLook(rows[lookCursor])
                return
            }
        }
        openLooked()
    }

    /// The piece to keep lit while the card is open. Something too small to draw lights what holds it.
    var lookPieceIndex: Int? {
        guard let look, let tree else { return nil }
        let pieces = engine.layout.pieces
        var target = look.node
        while target != focus, target != 0 {
            if let at = pieces.firstIndex(where: { $0.node == target && !$0.isSmaller }) { return at }
            target = tree.nodes[Int(target)].parent
        }
        return nil
    }

    // MARK: Keys and clicks

    /// While the card is open, the keys are the card's, wherever the keyboard happens to be, and a double-click on what it
    /// shows opens that. A preview is drawn by macOS, which has its own ideas about both.
    private func watchLookEvents() {
        guard lookWatch == nil else { return }
        lookWatch = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.look != nil else { return event }
            return self.handleLookEvent(event) ? nil : event
        }
    }

    private func handleLookEvent(_ event: NSEvent) -> Bool {
        // The keys come to the main window, which keeps the keyboard. The card's own window gets its clicks.
        guard let main = mapView?.window, let window = event.window, window === main || window === LookPanel.shared.window else { return false }
        let onCard = window === LookPanel.shared.window
        let at = CGPoint(x: event.locationInWindow.x, y: window.frame.height - event.locationInWindow.y)
        switch event.type {
        case .keyDown:
            if window.firstResponder is NSText || event.modifierFlags.contains(.command) { return false }
            switch event.keyCode {
            case 49, 53: closeLook()                    // space, escape
            case 123: stepLook(by: -1)                  // left
            case 124: stepLook(by: 1)                   // right
            case 125: return moveLookCursor(by: 1)      // down
            case 126: return moveLookCursor(by: -1)     // up
            case 36, 76: lookPrimary()                  // return, enter
            case 51:                                    // delete
                guard look?.back.isEmpty == false else { return false }
                lookBack()
            default: return false
            }
            return true
        case .leftMouseDown:
            guard onCard, event.clickCount == 2, lookContentFrame.contains(at) else { return false }
            openLooked()
            return true
        case .rightMouseDown:
            // The rows have their own menu. A preview would offer macOS's.
            guard onCard, let node = look?.node, let tree, !LookContents.isFolder(node, in: tree), lookContentFrame.contains(at),
                  let view = window.contentView, let menu = menu(for: NamedThing(node)) else { return false }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return true
        default:
            return false
        }
    }

    // MARK: What the side panel and the card both say

    func facts(of node: UInt32) -> String? {
        guard let tree, !tree.isPartial else { return nil }
        if factsVersion != treeVersion {
            factsCache = [:]
            factsVersion = treeVersion
        }
        if let known = factsCache[node] { return known }
        let words = LookContents.facts(of: node, in: tree)
        factsCache[node] = words
        return words
    }

    func listColor(_ node: UInt32, in tree: DiskTree) -> Color {
        if let matching = mapColor(node) { return matching.swiftUI }
        let n = tree.nodes[Int(node)]
        if n.has(NodeFlag.directory) { return Palette.blend(tree.statRow(node)).swiftUI }
        if n.has(NodeFlag.synthetic) { return Palette.color(.system).swiftUI }
        return Palette.color(Kind(rawValue: n.kind) ?? .other).swiftUI
    }
}
