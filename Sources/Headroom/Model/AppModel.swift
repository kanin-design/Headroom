import AppKit
import Observation
import QuickLookUI
import SwiftUI

/// The three questions the map can answer. The geometry stays put, so changing the question never loses your place.
enum Lens: String, CaseIterable, Identifiable {
    case map = "Map"
    case changes = "Changes"
    case freeUp = "Free Up"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .map: "circle.circle"
        case .changes: "flame"
        case .freeUp: "sparkles"
        }
    }
}

/// Where the ring sits in the window. The panel takes the right side, and the ring stays centred in what's left.
struct RingGeometry: Equatable {
    var center: CGPoint
    var radius: CGFloat
    var mapWidth: CGFloat
    var windowHeight: CGFloat

    static let panelWidth: CGFloat = 348

    static func make(size: CGSize, panelOpen: Bool) -> RingGeometry {
        let panel = panelOpen ? panelWidth + 28 : 0
        let usable = max(size.width - panel, 320)
        let top: CGFloat = 60, bottom: CGFloat = 46
        let height = max(size.height - top - bottom, 240)
        // Room at the sides for names around the ring.
        let side: CGFloat = usable > 1040 ? 168 : (usable > 820 ? 132 : 40)
        let radius = max(min(height / 2 - 12, (usable - 2 * side) / 2), 120)
        return RingGeometry(center: CGPoint(x: usable / 2, y: top + height / 2), radius: radius, mapWidth: usable, windowHeight: size.height)
    }
}

struct HoverInfo: Equatable {
    var pieceIndex: Int
    var node: UInt32
    var title: String
    var bytes: UInt64
    var share: String
    var note: String
    var reclaim: UInt64?
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // Disk
    var volumes: [VolumeFacts] = []
    var volume: VolumeFacts?
    private(set) var tree: DiskTree?
    /// Goes up whenever the tree's numbers change, so views can follow along.
    var treeVersion = 0
    var isScanning = false
    /// You asked for this scan, so it isn't being quiet about it.
    var scanIsHurrying = false
    var scanFiles = 0
    var hasFullAccess = false
    var askPerFolder = UserDefaults.standard.bool(forKey: "askPerFolder")
    var accessCardDismissed = false

    // Where you are
    var focus: UInt32 = 0
    /// Where you've been, so Back returns to the picture you came from.
    @ObservationIgnored private var trail: [UInt32] = []
    var lens: Lens = .map
    var panelOpen = true
    var hover: HoverInfo?
    var selected: UInt32? { didSet { if oldValue != selected { refreshStory() } } }
    var ring = RingGeometry(center: .zero, radius: 0, mapWidth: 0, windowHeight: 0)

    // Free Up
    var wins: [WinRow] = []
    var ticked: Set<String> = []
    var tickedReclaim: UInt64 = 0
    var trashBytesAdded: UInt64 = 0
    var message: String?
    var isTrashing = false
    var trashProgress = ""
    /// The link story behind whatever the panel is showing.
    var story: LinkStory?

    // Changes
    var changeWindow: ChangeWindow = .days(7)
    var changeRows: [ChangeRow] = []
    var changeTotal: Int64 = 0
    var changeCaption = ""
    var history: [HistoryPoint] = []

    // Names around the ring
    var labels: [MapLabel] = []
    var labelsVisible = false

    // Search
    var searchText = ""
    var searchActive = false
    var searchResults: [UInt32] = []

    @ObservationIgnored let engine = MapEngine()
    @ObservationIgnored let rules = RuleBook(homePath: NSHomeDirectory())
    @ObservationIgnored private var activeScan: DiskScan?
    @ObservationIgnored private var labelTask: Task<Void, Never>?
    @ObservationIgnored private var reclaimTask: Task<Void, Never>?
    @ObservationIgnored private var reclaim: ReclaimMap?
    @ObservationIgnored private var changes: ChangeMap?
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var didStart = false
    /// A tree on its way to the screen, so a scan starting now knows the ring won't be empty.
    @ObservationIgnored private var treeOnItsWay = false
    @ObservationIgnored private var zoomedAt = Date.distantPast
    @ObservationIgnored private var heldPicture: DiskTree?
    @ObservationIgnored private var insightsRunning = false
    @ObservationIgnored private var insightsAt = Date.distantPast
    /// The Map view's colours for the picture on screen, so the list on the right can match the ring.
    @ObservationIgnored private var ringColours: RingColours?
    @ObservationIgnored private let colourMemory = ColourMemory()
    @ObservationIgnored var forceTouchGuarded = false
    @ObservationIgnored var cacheLoadMilliseconds = 0.0
    @ObservationIgnored private var lastHoverIndex: Int?
    @ObservationIgnored private var lastPointer: (angle: Float, radius: Float)?
    @ObservationIgnored var nameCache: [UInt32: String] = [:]
    @ObservationIgnored weak var mapView: MapHostView?

    // MARK: Starting

    func start() {
        guard !didStart else { return }
        didStart = true
        hasFullAccess = DiskScan.hasFullDiskAccess()
        volumes = VolumeFacts.available()
        volume = volumes.first
        guard let volume else { return }
        history = History.points(for: volume)
        let launch = DispatchTime.now()
        if !CommandLine.arguments.contains("--no-cache"), let cached = TreeCache.load(for: volume) {
            present(cached, transition: .appear)
            cacheLoadMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - launch.uptimeNanoseconds) / 1e6
        }
        scan()
    }

    /// Reads the disk. With no map on screen, you get a picture from the first frame that fills in as the scan goes, and it
    /// works like any other map. With a map on screen, the scan stays out of the way and the map glides to the new numbers
    /// at the end. `hurry` is for when you asked: it runs at full power, even if a quiet scan is already under way.
    func scan(hurry: Bool = false) {
        if isScanning {
            if hurry {
                scanIsHurrying = true
                activeScan?.scanner.setHurry(true)
            }
            return
        }
        guard let volume else { return }
        guard let facts = VolumeFacts.read(path: volume.mountPath) else { return }
        self.volume = facts
        hasFullAccess = DiskScan.hasFullDiskAccess()
        let scan = DiskScan(facts: facts, rules: rules, fullAccess: hasFullAccess, askPerFolder: askPerFolder || forceTouchGuarded)
        activeScan = scan
        isScanning = true
        scanIsHurrying = hurry
        scanFiles = 0
        scanGeneration += 1
        heldPicture = nil
        let generation = scanGeneration
        let showPictures = (tree == nil || tree?.isPartial == true) && !treeOnItsWay
        let mode: ScanMode = hurry ? .full : (showPictures ? .firstLook : .quiet)
        // Free space, macOS and swap come straight from the disk, so the very first frame already has them.
        if showPictures { show(scan.picture()) }

        Thread.detachNewThread { [weak self] in
            Thread.current.qualityOfService = .userInitiated
            scan.run(mode: mode, tick: {
                let files = Int(scan.scanner.filesSoFar)
                let picture = showPictures ? scan.picture() : nil
                DispatchQueue.main.async {
                    guard let self, self.scanGeneration == generation else { return }
                    self.scanFiles = files
                    if let picture { self.show(picture) }
                }
            })
            let tree = scan.tree
            // A scan that was stopped, or a disk that was unplugged halfway, has only part of the picture. Keeping it
            // would show the wrong map on the next launch and spoil the next comparison.
            let complete = !scan.scanner.wasCancelled && VolumeFacts.read(path: facts.mountPath) != nil
            let snapshot = complete ? History.record(tree: tree, facts: facts) : []
            if complete { TreeCache.save(tree, for: facts) }
            DispatchQueue.main.async {
                guard let self, self.scanGeneration == generation else { return }
                guard complete else {
                    self.isScanning = false
                    self.activeScan = nil
                    self.volumesChanged()
                    return
                }
                self.isScanning = false
                self.scanIsHurrying = false
                self.heldPicture = nil
                self.scanFiles = Int(tree.totalFiles[0])
                self.activeScan = nil
                self.history = snapshot
                self.present(tree, transition: .settle)
            }
        }
    }

    /// One more step of the scan that's running. Whatever you're doing carries on, and the numbers only get fuller.
    private func show(_ picture: DiskTree) {
        guard let current = tree else {
            tree = picture
            nameCache = [:]
            treeVersion += 1
            relayout(.appear)
            workOutInsights(from: picture)
            return
        }
        guard current.isPartial else { return }
        // A zoom is under way. New numbers wait a moment, so they don't bend its path.
        let sinceZoom = Date().timeIntervalSince(zoomedAt)
        if sinceZoom < 0.5 {
            let alreadyWaiting = heldPicture != nil
            heldPicture = picture
            if !alreadyWaiting {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(0.5 - sinceZoom))
                    guard let self, let held = self.heldPicture else { return }
                    self.heldPicture = nil
                    self.show(held)
                }
            }
            return
        }
        if current.scanID != picture.scanID {
            // The scan started over, so its folders have new numbers.
            focus = 0
            trail = []
            selected = nil
            nameCache = [:]
        }
        tree = picture
        treeVersion += 1
        refreshLive()
        workOutInsights(from: picture)
    }

    /// New numbers for the picture you're already looking at.
    private func refreshLive() {
        guard let tree else { return }
        engine.apply(drawing(tree), .live)
        // Pieces have new places, so whatever is lit gets looked up again: under the pointer, or from a row in the panel.
        lastHoverIndex = -1
        if let pointer = lastPointer, let index = engine.layout.hit(angle: pointer.angle, radius: pointer.radius) {
            setHover(index)
        } else if let node = hover?.node {
            highlight(node: node)
        } else {
            lastHoverIndex = nil
        }
        // The same spring as the ring's, so names stay with their pieces.
        if labelsVisible { withAnimation(.spring(response: 0.81, dampingFraction: 1)) { labels = makeLabels() } }
    }

    /// Free Up and Changes during a scan: off the main thread and low priority, every couple of seconds.
    private func workOutInsights(from picture: DiskTree) {
        guard !insightsRunning, Date().timeIntervalSince(insightsAt) >= 2 else { return }
        insightsRunning = true
        let rules = self.rules
        let window = changeWindow
        Task.detached(priority: .utility) {
            let map = ReclaimMap(tree: picture, rules: rules)
            let wins = Wins.build(tree: picture, rules: rules)
            let change = ChangeMap(tree: picture, window: window)
            let rows = change.rows(tree: picture, rules: rules)
            await MainActor.run {
                self.insightsRunning = false
                self.insightsAt = Date()
                guard self.tree?.isPartial == true, self.tree?.scanID == picture.scanID else { return }
                self.adopt(map, wins, change, rows)
                if self.searchActive { self.runSearch() }
                if self.lens != .map { self.refreshLive() }
            }
        }
    }

    /// While a scan is showing its progress, what you're looking at is read first.
    private func readFocusFirst() {
        guard let scan = activeScan, let tree, tree.isPartial, tree.scanID == scan.tree.scanID else { return }
        let folder: UInt32? = focus == 0 ? nil : focus
        DispatchQueue.global(qos: .userInitiated).async {
            scan.scanner.prioritize(folder)
            scan.tickSoon()
        }
    }

    /// Stops a running scan and starts again.
    private func restartScan(hurry: Bool = false) {
        activeScan?.scanner.cancel()
        isScanning = false
        activeScan = nil
        scan(hurry: hurry)
    }

    /// Shows a new tree. What the views ask of it is worked out first, so the tree and everything derived from it
    /// change in one step and nothing ever reads one tree with another tree's numbers.
    private func present(_ newTree: DiskTree, transition: RingTransition) {
        let rules = self.rules
        let window = changeWindow
        treeOnItsWay = true
        Task.detached(priority: .userInitiated) {
            let map = ReclaimMap(tree: newTree, rules: rules)
            let wins = Wins.build(tree: newTree, rules: rules)
            let change = ChangeMap(tree: newTree, window: window)
            let rows = change.rows(tree: newTree, rules: rules)
            await MainActor.run {
                self.treeOnItsWay = false
                // You may have picked another disk while this was being worked out.
                guard newTree.rootPath == self.volume?.mountPath else { return }
                // The end of a scan you've been watching: its folders are the same ones, so you simply stay where you are.
                let sameScan = self.tree?.scanID == newTree.scanID
                if !sameScan {
                    // Keep your place, if the folder you were looking at still exists.
                    var keepPath: String?
                    if self.focus != 0, let tree = self.tree { keepPath = tree.path(self.focus) }
                    self.focus = keepPath.flatMap { newTree.find(path: $0) } ?? 0
                    self.trail = []
                    self.selected = nil
                }
                self.tree = newTree
                self.nameCache = [:]
                self.treeVersion += 1
                self.adopt(map, wins, change, rows)
                if sameScan {
                    self.refreshLive()
                    self.refreshStory()
                } else {
                    self.relayout(transition)
                }
            }
        }
    }

    private func adopt(_ map: ReclaimMap, _ newWins: [WinRow], _ change: ChangeMap, _ rows: [ChangeRow]) {
        reclaim = map
        wins = newWins
        ticked = ticked.intersection(Set(newWins.map(\.id)))
        changes = change
        changeRows = rows
        changeTotal = change.usesHistory ? change.total : rows.reduce(0) { $0 + $1.delta }
        changeCaption = change.caption
        updateTickedReclaim()
    }

    func switchVolume(_ facts: VolumeFacts) {
        guard facts.mountPath != volume?.mountPath else { return }
        activeScan?.scanner.cancel()
        isScanning = false
        volume = facts
        tree = nil
        focus = 0
        trail = []
        selected = nil
        wins = []
        ticked = []
        changeRows = []
        labels = []
        engine.apply(RingLayout(), .settle)
        history = History.points(for: facts)
        if let cached = TreeCache.load(for: facts) { present(cached, transition: .appear) }
        scan()
    }

    /// A disk was plugged in or removed. If it was the one on screen, go back to the startup disk.
    func volumesChanged() {
        volumes = VolumeFacts.available()
        guard let volume, !volumes.contains(where: { $0.mountPath == volume.mountPath }), let boot = volumes.first else { return }
        switchVolume(boot)
    }

    /// The app came to the front again. If a while has passed, or the Trash may have been emptied, refresh quietly.
    func didBecomeActive() {
        guard didStart, let tree else { return }
        // Coming back from System Settings with Full Disk Access switched on: read the rest straight away.
        let access = DiskScan.hasFullDiskAccess()
        if access != hasFullAccess {
            hasFullAccess = access
            restartScan(hurry: true)
            return
        }
        guard !isScanning else { return }
        let age = Date().timeIntervalSince(tree.finishedAt)
        if age > 900 || trashBytesAdded > 0 {
            trashBytesAdded = 0
            scan()
        }
    }

    // MARK: Insights, worked out off the main thread

    /// Numbers changed within the same tree, after moving something to the Trash.
    private func rebuildInsights() {
        guard let tree else { return }
        let rules = self.rules
        let version = treeVersion
        let window = changeWindow
        Task.detached(priority: .userInitiated) {
            let map = ReclaimMap(tree: tree, rules: rules)
            let wins = Wins.build(tree: tree, rules: rules)
            let change = ChangeMap(tree: tree, window: window)
            let rows = change.rows(tree: tree, rules: rules)
            await MainActor.run {
                guard self.treeVersion == version, self.tree === tree else { return }
                self.adopt(map, wins, change, rows)
                if self.lens != .map { self.relayout(.recolor) }
            }
        }
    }

    func setChangeWindow(_ window: ChangeWindow) {
        changeWindow = window
        guard let tree else { return }
        let change = ChangeMap(tree: tree, window: window)
        changes = change
        changeRows = change.rows(tree: tree, rules: rules)
        changeTotal = change.usesHistory ? change.total : changeRows.reduce(0) { $0 + $1.delta }
        changeCaption = change.caption
        if lens == .changes { relayout(.recolor) }
    }

    // MARK: Drawing

    func relayout(_ transition: RingTransition, labelDelay: Double = 0.18) {
        guard let tree else { return }
        let layout = drawing(tree)
        engine.apply(layout, transition)
        lastHoverIndex = nil
        hover = nil
        placeLabels(after: labelDelay)
        refreshStory()
        refreshHover(after: 0.42)
    }

    /// The picture for the folder in view.
    private func drawing(_ tree: DiskTree) -> RingLayout {
        var layout = RingLayout.build(tree: tree, focus: focus, colorer: colorer(tree))
        if lens == .map { layout.calmTinyPieces(viewBytes: tree.totals[Int(focus)]) }
        return layout
    }

    private func colorer(_ tree: DiskTree) -> RingLayout.Colorer {
        switch lens {
        case .map:
            let colours = RingColours(tree: tree, focus: focus, memory: colourMemory)
            ringColours = colours
            return { colours.lab($0).linearP3 }
        case .changes:
            guard let changes else { return Lenses.kindColorer(tree: tree) }
            return Lenses.changeColorer(tree: tree, changes: changes)
        case .freeUp:
            guard let reclaim else { return Lenses.kindColorer(tree: tree) }
            let chosen = wins.filter { ticked.contains($0.id) }.flatMap(\.nodes)
            return Lenses.reclaimColorer(tree: tree, map: reclaim, rules: rules, ticked: chosen)
        }
    }

    /// A row's dot in the panel: the same colour as its piece on the ring.
    func mapColor(_ node: UInt32) -> Lab? { ringColours?.lab(node) }

    func setRing(_ geometry: RingGeometry) {
        guard geometry != ring else { return }
        let moved = abs(geometry.radius - ring.radius) > 0.5 || abs(geometry.center.x - ring.center.x) > 0.5 || abs(geometry.center.y - ring.center.y) > 0.5
        ring = geometry
        if moved { placeLabels(after: 0.12) }
    }

    private func placeLabels(after delay: Double) {
        labelTask?.cancel()
        withAnimation(.easeOut(duration: 0.1)) { labelsVisible = false }
        labelTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.labels = self.makeLabels()
            withAnimation(.easeOut(duration: 0.28)) { self.labelsVisible = true }
        }
    }

    private func makeLabels() -> [MapLabel] {
        guard let tree else { return [] }
        return LabelPlacer.place(layout: engine.layout, ring: ring, lens: lens, tree: tree, model: self)
    }

    /// Works out the link story for what the panel is showing. It takes a moment, so it never holds up the zoom.
    func refreshStory() {
        guard let tree, !tree.links.isEmpty else { story = nil; return }
        let node = selected ?? focus
        guard node != 0, !tree.nodes[Int(node)].has(NodeFlag.synthetic) else { story = nil; return }
        Task.detached(priority: .userInitiated) {
            let found = Accounting.story(node, in: tree)
            await MainActor.run {
                if (self.selected ?? self.focus) == node { self.story = found }
            }
        }
    }

    // MARK: Names

    /// A piece's name, as you'd say it: the app's name for a cache, both ends of a chain.
    func displayName(_ node: UInt32) -> String {
        if let cached = nameCache[node] { return cached }
        guard let tree else { return "" }
        let n = tree.nodes[Int(node)]
        var name = tree.name(node)
        if n.has(NodeFlag.ruleRoot), rules.rule(n.rule).namedByBundleID {
            name = Wins.appName(forFolder: name) + " cache"
        }
        nameCache[node] = name
        return name
    }

    func displayName(piece p: Piece) -> String {
        guard let tree else { return "" }
        if p.isSmaller {
            return "Smaller items"
        }
        if p.tail != p.node {
            let top = displayName(p.node), bottom = tree.name(p.tail)
            return "\(top) › \(bottom)"
        }
        return displayName(p.node)
    }

    // MARK: Pointer

    func polar(_ p: CGPoint) -> (angle: Float, radius: Float)? {
        guard ring.radius > 0 else { return nil }
        let dx = Float(p.x - ring.center.x), dy = Float(p.y - ring.center.y)
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        return (angle, (dx * dx + dy * dy).squareRoot() / Float(ring.radius))
    }

    func pointerMoved(to polar: (angle: Float, radius: Float)?) {
        lastPointer = polar
        guard let polar else { setHover(nil); return }
        setHover(engine.layout.hit(angle: polar.angle, radius: polar.radius))
    }

    /// The picture changed under a pointer that hasn't moved, so it may be over something new.
    private func refreshHover(after delay: Double) {
        guard lastPointer != nil else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, let pointer = self.lastPointer else { return }
            self.setHover(self.engine.layout.hit(angle: pointer.angle, radius: pointer.radius))
        }
    }

    func setHover(_ index: Int?) {
        guard index != lastHoverIndex else { return }
        lastHoverIndex = index
        reclaimTask?.cancel()
        guard let index, let tree, index < engine.layout.pieces.count else {
            engine.setEmphasis(primary: nil, related: [])
            hover = nil
            return
        }
        let layout = engine.layout
        let p = layout.pieces[index]
        var chain: [Int] = []
        var a = p.parent
        while a >= 0 {
            chain.append(Int(a))
            a = layout.pieces[Int(a)].parent
        }
        engine.setEmphasis(primary: index, related: [index..<Int(p.end)], ancestors: chain)
        var info = describe(p, index: index, tree: tree)
        hover = info
        // What you'd really get back takes a moment to work out, so it waits until the pointer rests.
        if !p.isSmaller, p.style != 1, p.style != 2, !tree.links.isEmpty, tree.nodes[Int(p.node)].flags & NodeFlag.synthetic == 0 {
            let node = p.node
            reclaimTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(90))
                guard let self, !Task.isCancelled else { return }
                let value = await Task.detached(priority: .userInitiated) { Accounting.reclaimable([node], in: tree) }.value
                guard !Task.isCancelled, self.lastHoverIndex == index else { return }
                info.reclaim = value
                self.hover = info
            }
        }
    }

    private func describe(_ p: Piece, index: Int, tree: DiskTree) -> HoverInfo {
        let n = tree.nodes[Int(p.node)]
        let base = tree.totals[Int(focus)]
        let percent = base > 0 ? Double(p.bytes) / Double(base) * 100 : 0
        let percentText = percent >= 10 ? String(format: "%.0f%%", percent) : String(format: "%.1f%%", percent)
        let scope = focus == 0 ? "of the disk" : "of \(displayName(focus))"
        var share = "\(percentText) \(scope)"
        if tree.isPartial, !p.isSmaller {
            if p.node == tree.hidden { share = "not read yet" }
            else if tree.isStillGrowing(p.node) { share = "so far" }
        }
        var note = ""
        if lens == .changes, let changes {
            let delta = changes.value(of: p.node)
            if delta > 0 { note = "+\(formatBytes(UInt64(delta))) \(changes.shortCaption)" }
            else if delta < 0 { note = "−\(formatBytes(UInt64(-delta))) \(changes.shortCaption)" }
        } else if n.rule != 0, !p.isSmaller {
            let rule = rules.rule(n.rule)
            if rule.tier != .none && rule.tier != .handsOff { note = rule.tier.title }
        }
        return HoverInfo(pieceIndex: index, node: p.node, title: displayName(piece: p), bytes: p.bytes,
                         share: share, note: note, reclaim: nil)
    }

    /// Lights up one thing from the panel or a label, as if the pointer were on it.
    func highlight(node: UInt32?) {
        guard let node, let tree else { setHover(nil); return }
        let layout = engine.layout
        var target = node
        while true {
            if let index = layout.pieces.firstIndex(where: { $0.node == target && !$0.isSmaller }) {
                setHover(index)
                return
            }
            if target == 0 || target == focus { break }
            target = tree.nodes[Int(target)].parent
        }
        setHover(nil)
    }

    /// Lights up many things at once: every node_modules on the disk, or everything of one kind.
    func highlight(nodes: [UInt32]) {
        guard let tree, !nodes.isEmpty else { setHover(nil); engine.setEmphasis(primary: nil, related: []); return }
        lastHoverIndex = nil
        hover = nil
        let layout = engine.layout
        let set = NodeSet(nodes, in: tree)
        var ranges: [Range<Int>] = []
        var i = 0
        while i < layout.pieces.count {
            let p = layout.pieces[i]
            if !p.isSmaller, set.contains(p.node) {
                ranges.append(i..<Int(p.end))
                i = Int(p.end)
            } else {
                i += 1
            }
        }
        engine.setEmphasis(primary: nil, related: ranges)
    }

    func highlight(kind: Kind?) {
        guard let kind, let tree else { engine.setEmphasis(primary: nil, related: []); return }
        let layout = engine.layout
        var ranges: [Range<Int>] = []
        for (i, p) in layout.pieces.enumerated() {
            let isLeaf = Int(p.end) == i + 1
            if isLeaf && !p.isSmaller && p.style != 1 && p.style != 2 && tree.dominantKind(p.node) == kind { ranges.append(i..<i + 1) }
        }
        engine.setEmphasis(primary: nil, related: ranges)
    }

    func click(at polar: (angle: Float, radius: Float)?) {
        guard let polar else { return }
        if polar.radius < RingLayout.hole {
            goUp()
            return
        }
        guard let index = engine.layout.hit(angle: polar.angle, radius: polar.radius) else {
            selected = nil
            return
        }
        click(piece: index)
    }

    func click(piece index: Int) {
        guard let tree, index < engine.layout.pieces.count else { return }
        let p = engine.layout.pieces[index]
        let n = tree.nodes[Int(p.node)]
        if n.has(NodeFlag.free) {
            setLens(.freeUp)
            return
        }
        if p.isSmaller {
            if p.node != focus { zoom(into: p.node) }
            return
        }
        if !n.has(NodeFlag.directory) || n.firstChild == 0 {
            selected = p.node
            panelOpen = true
            return
        }
        zoom(into: p.tail, from: p)
    }

    func zoom(into node: UInt32, from piece: Piece? = nil) {
        guard node != focus else { return }
        let source = piece ?? engine.layout.pieces.first(where: { $0.node == node && !$0.isSmaller })
        let mapping = source.map { ZoomMapping(a0: $0.a0, a1: $0.a1, r1: $0.r1) }
        trail.append(focus)
        focus = node
        selected = nil
        zoomedAt = Date()
        relayout(.zoomIn(mapping), labelDelay: 0.34)
        readFocusFirst()
    }

    func goUp() {
        if selected != nil {
            selected = nil
            return
        }
        guard let tree, focus != 0 else { return }
        if let back = trail.popLast() {
            go(to: back, keepingTrail: true)
            return
        }
        var up = tree.nodes[Int(focus)].parent
        // Skip folders that would draw exactly the same picture.
        while up != 0, RingLayout.chainTail(tree: tree, up) == RingLayout.chainTail(tree: tree, focus) {
            up = tree.nodes[Int(up)].parent
        }
        go(to: up, keepingTrail: true)
    }

    func go(to node: UInt32, keepingTrail: Bool = false) {
        guard let tree, node != focus else { return }
        if !keepingTrail { trail = [] }
        let old = focus
        focus = node
        selected = nil
        let layout = drawing(tree)
        // The piece that holds where you were tells the zoom which way to go.
        var mapping: ZoomMapping?
        var search = old
        while mapping == nil {
            if let p = layout.pieces.first(where: { $0.node == search && !$0.isSmaller }) {
                mapping = ZoomMapping(a0: p.a0, a1: p.a1, r1: p.r1)
                break
            }
            if search == 0 { break }
            search = tree.nodes[Int(search)].parent
        }
        zoomedAt = Date()
        engine.apply(layout, .zoomOut(mapping))
        lastHoverIndex = nil
        hover = nil
        placeLabels(after: 0.34)
        refreshStory()
        refreshHover(after: 0.42)
        readFocusFirst()
    }

    func setLens(_ new: Lens) {
        guard new != lens else { return }
        lens = new
        selected = nil
        panelOpen = true
        engine.setCalm(new == .map)
        relayout(.recolor, labelDelay: 0.2)
        // Free Up and Changes want the whole picture, so now you're waiting on the scan.
        if tree?.isPartial == true, !scanIsHurrying { activeScan?.scanner.setHurry(new != .map) }
    }

    // MARK: Free Up

    func toggle(_ row: WinRow) {
        if ticked.contains(row.id) { ticked.remove(row.id) } else { ticked.insert(row.id) }
        updateTickedReclaim()
        if lens == .freeUp, let tree {
            let layout = drawing(tree)
            engine.apply(layout, .recolor)
            lastHoverIndex = nil
        }
    }

    private func updateTickedReclaim() {
        guard let tree else { return }
        let chosen = wins.filter { ticked.contains($0.id) }
        let nodes = chosen.flatMap(\.nodes)
        let simple = chosen.reduce(UInt64(0)) { $0 &+ $1.bytes }
        tickedReclaim = simple
        engine.setGhost(Float(simple) / Float(max(tree.capacityBytes, 1)))
        guard !nodes.isEmpty else { return }
        // Removing several things together can free more than the sum: files that only link to each other.
        Task.detached(priority: .userInitiated) {
            let exact = Accounting.reclaimable(nodes, in: tree)
            await MainActor.run {
                guard self.wins.filter({ self.ticked.contains($0.id) }).flatMap(\.nodes) == nodes else { return }
                self.tickedReclaim = exact
                self.engine.setGhost(Float(exact) / Float(max(tree.capacityBytes, 1)))
            }
        }
    }

    /// Apps that should be closed before their files are touched.
    func runningApps(for rows: [WinRow]) -> [NSRunningApplication] {
        var out: [NSRunningApplication] = []
        for row in rows {
            guard let id = row.bundleID else { continue }
            out += NSRunningApplication.runningApplications(withBundleIdentifier: id)
        }
        return out
    }

    /// Moves what's ticked to the Trash, off the main thread: thousands of folders take a moment, and the app stays
    /// usable. Nothing is deleted, and it can all be put back from there.
    func moveTickedToTrash() {
        guard let tree, !isTrashing else { return }
        let rows = wins.filter { ticked.contains($0.id) && $0.action == .trash }
        var items: [(UInt32, String?)] = []
        var skipped = 0
        for row in rows {
            for node in row.nodes {
                // A group of small caches can't ask each app to quit, so it leaves the ones in use alone.
                if row.id == Wins.smallerCachesID, !NSRunningApplication.runningApplications(withBundleIdentifier: tree.name(node)).isEmpty {
                    skipped += 1
                    continue
                }
                items.append((node, tree.path(node)))
            }
        }
        isTrashing = true
        trashProgress = "Moving to the Trash"
        Task.detached(priority: .userInitiated) {
            var moved: [UInt32] = []
            var failed = 0
            for (at, item) in items.enumerated() {
                guard let path = item.1, Safety.canTrash(path) else { failed += 1; continue }
                do {
                    var result: NSURL?
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
                    moved.append(item.0)
                } catch {
                    failed += 1
                }
                if at % 25 == 0 {
                    let text = "Moving \(at + 1) of \(items.count) to the Trash"
                    await MainActor.run { self.trashProgress = text }
                }
            }
            let done = moved
            let failures = failed
            await MainActor.run { self.finishTrash(moved: done, failed: failures, skipped: skipped, in: tree) }
        }
    }

    private func finishTrash(moved: [UInt32], failed: Int, skipped: Int, in movedFrom: DiskTree) {
        isTrashing = false
        ticked = []
        tickedReclaim = 0
        engine.setGhost(0)
        // A scan may have finished while this ran. Its numbers are for another tree, so read the disk again instead.
        guard tree === movedFrom else {
            message = moved.isEmpty ? nil : "That's in the Trash now. Empty it to get the space back."
            restartScan()
            return
        }
        var bytes: UInt64 = 0
        for node in moved { bytes &+= takeOut(node, from: movedFrom) }
        trashBytesAdded &+= bytes
        var text = moved.isEmpty ? "" : "\(formatBytes(bytes)) is in the Trash. Empty it to get the space back."
        if failed > 0 { text += (text.isEmpty ? "" : " ") + "\(failed) couldn't be moved." }
        if skipped > 0 { text += (text.isEmpty ? "" : " ") + "\(skipped) left alone, because their apps are open." }
        message = text.isEmpty ? nil : text
        treeVersion += 1
        rebuildInsights()
        relayout(.settle)
        // A scan that's running may already have read those files, and would bring them back.
        if isScanning, !moved.isEmpty { restartScan() }
    }

    /// Takes something out of the picture. If you were looking inside it, you step back to the folder that held it.
    private func takeOut(_ node: UInt32, from tree: DiskTree) -> UInt64 {
        let bytes = tree.totals[Int(node)]
        if focus != 0, tree.isInside(focus, node) {
            focus = tree.nodes[Int(node)].parent
            trail = []
        }
        if let chosen = selected, tree.isInside(chosen, node) { selected = nil }
        tree.remove(node)
        if let trash = trashNode(in: tree) { tree.add(bytes, to: trash) }
        // Nothing left to show here.
        while focus != 0, tree.totals[Int(focus)] == 0 { focus = tree.nodes[Int(focus)].parent }
        return bytes
    }

    private func trashNode(in tree: DiskTree) -> UInt32? {
        guard tree.home != 0 else { return nil }
        var c = tree.nodes[Int(tree.home)].firstChild
        while c != 0 {
            if tree.nodes[Int(c)].nameLength == 6, tree.name(c) == ".Trash" { return c }
            c = tree.nodes[Int(c)].nextSibling
        }
        return nil
    }

    func moveToTrash(node: UInt32) {
        guard let tree, let path = tree.path(node), Safety.canTrash(path) else { return }
        do {
            var result: NSURL?
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &result)
            let bytes = takeOut(node, from: tree)
            trashBytesAdded &+= bytes
            message = "\(formatBytes(bytes)) is in the Trash. Empty it to get the space back."
            treeVersion += 1
            rebuildInsights()
            relayout(.settle)
            if isScanning { restartScan() }
        } catch {
            message = "That couldn't be moved to the Trash."
        }
    }

    func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
    }

    func openSoftwareUpdate() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
    }

    /// Scan the guarded folders too, and let macOS ask about each one.
    func useFolderPrompts() {
        askPerFolder = true
        UserDefaults.standard.set(true, forKey: "askPerFolder")
        restartScan(hurry: true)
    }

    // MARK: Finder

    func reveal(_ node: UInt32) {
        guard let path = tree?.path(node) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Self.visiblePath(path))])
    }

    private static func visiblePath(_ path: String) -> String {
        path.hasPrefix("/System/Volumes/Data/") ? String(path.dropFirst("/System/Volumes/Data".count)) : path
    }

    func copyPath(_ node: UInt32) {
        guard let path = tree?.path(node) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.visiblePath(path), forType: .string)
    }

    func quickLookHovered() {
        guard let node = hover?.node ?? selected, let path = tree?.path(node) else { return }
        QuickLook.shared.show(URL(fileURLWithPath: Self.visiblePath(path)))
    }

    func contextMenu(forPiece index: Int) -> NSMenu? {
        guard let tree, index < engine.layout.pieces.count else { return nil }
        let p = engine.layout.pieces[index]
        guard !p.isSmaller, tree.path(p.node) != nil else { return nil }
        let menu = NSMenu()
        let target = MenuTarget.shared
        func add(_ title: String, _ symbol: String, _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(MenuTarget.run(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.target = target
            item.representedObject = MenuAction(action)
            menu.addItem(item)
        }
        add("Reveal in Finder", "folder") { self.reveal(p.node) }
        add("Quick Look", "eye") {
            self.selected = p.node
            if let path = tree.path(p.node) { QuickLook.shared.show(URL(fileURLWithPath: Self.visiblePath(path))) }
        }
        add("Copy Path", "doc.on.doc") { self.copyPath(p.node) }
        if !tree.isPartial, let path = tree.path(p.node), Safety.canTrash(path) {
            menu.addItem(.separator())
            add("Move to Trash…", "trash") {
                let alert = NSAlert()
                alert.messageText = "Move \(self.displayName(p.node)) to the Trash?"
                alert.informativeText = "\(tree.friendlyPath(p.node))\n\(formatBytes(tree.totals[Int(p.node)])). You can put it back from the Trash until you empty it."
                alert.addButton(withTitle: "Move to Trash")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { self.moveToTrash(node: p.node) }
            }
        }
        return menu
    }

    // MARK: Search

    func runSearch() {
        guard let tree else { return }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard query.count >= 2 else {
            searchResults = []
            engine.setEmphasis(primary: nil, related: [])
            return
        }
        searchResults = Search.run(query, in: tree)
        highlight(nodes: Array(searchResults.prefix(400)))
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

final class MenuTarget: NSObject {
    static let shared = MenuTarget()
    @objc func run(_ sender: NSMenuItem) { (sender.representedObject as? MenuAction)?.run() }
}

/// macOS's own preview panel.
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var url: URL?

    @MainActor
    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        AppModel.shared.mapView?.window?.makeFirstResponder(AppModel.shared.mapView)
        panel.updateController()
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url as NSURL? }
}

/// The last check before anything moves. Only your own files, never the folders that hold everything together.
enum Safety {
    static func canTrash(_ path: String) -> Bool {
        let visible = path.hasPrefix("/System/Volumes/Data/") ? String(path.dropFirst("/System/Volumes/Data".count)) : path
        let home = NSHomeDirectory()
        let protected: Set<String> = [
            "/", home, "/Users", "/Applications", "/Library", "/System", "/private", "/usr", "/opt", "/bin", "/sbin", "/etc", "/var",
            home + "/Library", home + "/Desktop", home + "/Documents", home + "/Downloads", home + "/Pictures", home + "/Movies",
            home + "/Music", home + "/.Trash", home + "/Library/Application Support", home + "/Library/Caches", home + "/Library/Preferences",
            home + "/Library/Containers", home + "/Library/Group Containers", home + "/.config", home + "/.ssh", home + "/dev",
        ]
        if protected.contains(visible) { return false }
        for keep in ["/.Trash/", "/.ssh/", "/.gnupg/", "/Library/Keychains", "/Library/Preferences/", "/Library/Mail/", "/Library/Messages/"]
        where visible.hasPrefix(home + keep) { return false }
        if visible.hasPrefix(home + "/") { return true }
        if visible.hasPrefix("/Applications/") { return true }
        if visible.hasPrefix("/Volumes/") { return visible.split(separator: "/").count > 2 }
        return false
    }
}
