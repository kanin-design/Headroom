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
    /// Free Up holds more: evidence, ticks and the plan.
    static let wideWidth: CGFloat = 420

    static func panelWidth(for lens: Lens) -> CGFloat { lens == .freeUp ? wideWidth : panelWidth }

    static func make(size: CGSize, panelOpen: Bool, lens: Lens = .map) -> RingGeometry {
        let panel = panelOpen ? panelWidth(for: lens) + 28 : 0
        let usable = max(size.width - panel, 320)
        let top: CGFloat = 60, bottom: CGFloat = 46
        let height = max(size.height - top - bottom, 240)
        // Room at the sides for names around the ring.
        let side: CGFloat = usable > 1040 ? 168 : (usable > 900 ? 150 : (usable > 820 ? 132 : 40))
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
    var focus: UInt32 = 0 { didSet { if oldValue != focus { refreshShownRows() } } }
    /// Where you've been, so Back returns to the picture you came from.
    @ObservationIgnored var trail: [UInt32] = []
    var lens: Lens = .map
    var panelOpen = true
    var hover: HoverInfo?
    var selected: UInt32? { didSet { if oldValue != selected { refreshStory() } } }
    var ring = RingGeometry(center: .zero, radius: 0, mapWidth: 0, windowHeight: 0)

    // Free Up
    /// Everything that could go, sorted by what it is. The panel and the ring are both drawn from this.
    var suggestions = Suggestions()
    /// The same, for the picture on screen.
    var boxes: [Box] = []
    /// Every suggestion in those boxes, and what can't be ticked.
    var shownRows: [WinRow] = []
    var openBoxes: Set<String> = []
    /// What you're pointing at in the panel, so the ring and its middle can say so too.
    var pointing: Pointing?
    /// What's under the pointer on the ring, so the panel can say so too.
    var hotBox: String?
    var hotRow: String?
    var message: String?
    /// The link story behind whatever the panel is showing.
    var story: LinkStory?

    // Planned actions
    var plan = PlanList()
    /// What you'd really get back.
    var planBytes: UInt64 = 0
    var planBytesByItem: [String: UInt64] = [:]
    var rowStates: [String: TickState] = [:]
    var checks: [String: ItemCheck] = [:]
    var isChecking = false
    var cleanProgress: CleanProgress?
    var afterClean: AfterClean?
    /// A few words beside the ring, for when a click can't do what you asked.
    var tip: String?
    var expandedRow: String?
    var previewingAfter = false

    @ObservationIgnored var planNodes: [String: [UInt32]] = [:]
    @ObservationIgnored var planExcluded: [UInt32] = []
    @ObservationIgnored var planSet: NodeSet?
    @ObservationIgnored var planBack: NodeSet?
    @ObservationIgnored var nodeOfPath: [String: UInt32] = [:]
    /// You unticked these, so they don't tick themselves again.
    @ObservationIgnored var refusedRows: Set<String> = []
    /// Each thing's colour on the ring for the picture on screen, and the same by the map's numbering.
    @ObservationIgnored var rowColours: [String: Lab] = [:]
    @ObservationIgnored var mapColours: [SIMD3<Float>?] = []
    /// Which box in the panel a thing is in.
    @ObservationIgnored var boxOfRow: [String: String] = [:]
    @ObservationIgnored var checkTask: Task<Void, Never>?
    @ObservationIgnored var pointingTask: Task<Void, Never>?
    /// Every suggestion on screen with its parts spelled out, and which one a node belongs to.
    @ObservationIgnored var flatRows: [WinRow] = []
    /// Which scan's node numbers the suggestions use.
    @ObservationIgnored var winsScanID: UUID?
    @ObservationIgnored var quitAfterClean = false
    @ObservationIgnored var scanWasStopped = false

    @ObservationIgnored var rowOfNode: [UInt32: Int] = [:]
    @ObservationIgnored var checkGeneration = 0
    @ObservationIgnored var effectGeneration = 0
    @ObservationIgnored var tipTask: Task<Void, Never>?
    @ObservationIgnored var focusBeforeExpanding: UInt32?
    @ObservationIgnored var cleanStop = LockedFlag()
    @ObservationIgnored var takenOut: [(node: UInt32, bytes: UInt64, tree: DiskTree, heldBy: UInt32?, heldBytes: UInt64)] = []
    @ObservationIgnored var clearedItems: [PlanItem] = []
    @ObservationIgnored var rescanWhenBack = false
    @ObservationIgnored var cachedAfterPlan: AfterPlan?
    @ObservationIgnored var facts: Facts = .none
    @ObservationIgnored var factsRunning = false
    @ObservationIgnored var factsWanted = false
    @ObservationIgnored var factsOfSavedMap = false
    @ObservationIgnored var isReadingOtherDisk = false
    @ObservationIgnored var lastPlanItems: [PlanItem] = []
    @ObservationIgnored var pendingCleaned: [CleanedThing] = []
    /// Why things didn't go in the last clean, by planned thing. It shows on the list until you say try again.
    @ObservationIgnored var cleanFailures: [String: CheckProblem] = [:]
    @ObservationIgnored var lastCleanFrame = Date.distantPast
    @ObservationIgnored var lastCleanSave = Date.distantPast
    var otherCopies: [String: OtherCopy] = [:]
    var cursorRow: String?

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
    @ObservationIgnored var activeScan: DiskScan?
    @ObservationIgnored private var labelTask: Task<Void, Never>?
    @ObservationIgnored private var reclaimTask: Task<Void, Never>?
    @ObservationIgnored var reclaim: ReclaimMap?
    @ObservationIgnored private var changes: ChangeMap?
    @ObservationIgnored var scanGeneration = 0
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
    @ObservationIgnored var lastHoverIndex: Int?
    @ObservationIgnored var lastPointer: (angle: Float, radius: Float)?
    @ObservationIgnored var nameCache: [UInt32: String] = [:]
    @ObservationIgnored weak var mapView: MapHostView?

    // MARK: Starting

    func start() {
        guard !didStart else { return }
        didStart = true
        // A scripted run has to know this before its first scan, whichever gets going first.
        if ScriptRunner.path != nil { forceTouchGuarded = !CommandLine.arguments.contains("--locked") }
        loadPlan()
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
        readOtherDisksQuietly()
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
        // Nothing replaces the map while things are leaving it. The disk is read again when that's done.
        if cleanProgress != nil || afterClean?.isEmptying == true { return }
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
            // A picture is a copy of the whole tree, so there's never a second one waiting behind one nobody has looked at yet.
            let pictureWaiting = LockedFlag()
            scan.run(mode: mode, tick: {
                let files = Int(scan.scanner.filesSoFar)
                let picture = showPictures && !pictureWaiting.value ? scan.picture() : nil
                if picture != nil { pictureWaiting.value = true }
                DispatchQueue.main.async {
                    if picture != nil { pictureWaiting.value = false }
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
            if complete {
                TreeCache.save(tree, for: facts)
                DiskIndex.save(tree)
            }
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
        if HiddenNames.isOn {
            HiddenNames.apply(to: picture)
            nameCache = [:]
        }
        guard let current = tree else {
            tree = picture
            nameCache = [:]
            treeVersion += 1
            resolvePlanSynchronously(in: picture)
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
            // The scan started over, so its folders have new numbers, and nothing that holds the old ones can stay.
            focus = 0
            trail = []
            selected = nil
            nameCache = [:]
            suggestions = Suggestions()
            boxes = []
            winsScanID = nil
            flatRows = []
            rowOfNode = [:]
            shownRows = []
            otherCopies = [:]
        }
        tree = picture
        treeVersion += 1
        if !plan.isEmpty { resolvePlanSynchronously(in: picture) }
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
        let running = runningBundleIDs()
        let facts = self.facts
        let kept = plan.kept
        Task.detached(priority: .utility) {
            let (wins, map) = Self.suggest(tree: picture, rules: rules, running: running, facts: facts, kept: kept)
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
    func restartScan(hurry: Bool = false) {
        activeScan?.scanner.cancel()
        isScanning = false
        activeScan = nil
        scan(hurry: hurry)
    }

    /// Shows a new tree. What the views ask of it is worked out first, so the tree and everything derived from it
    /// change in one step and nothing ever reads one tree with another tree's numbers.
    private func present(_ newTree: DiskTree, transition: RingTransition) {
        if HiddenNames.isOn { HiddenNames.apply(to: newTree) }
        let rules = self.rules
        let window = changeWindow
        let running = runningBundleIDs()
        let facts = self.facts
        let kept = plan.kept
        treeOnItsWay = true
        Task.detached(priority: .userInitiated) {
            let (wins, map) = Self.suggest(tree: newTree, rules: rules, running: running, facts: facts, kept: kept)
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
                self.resolvePlanSynchronously(in: newTree)
                self.adopt(map, wins, change, rows)
                // A saved map leaves out the smallest folders, so a finished scan is worth a second look.
                var isFresh = true
                if case .appear = transition { isFresh = false }
                self.gatherFacts(for: newTree, afresh: isFresh)
                if sameScan {
                    self.refreshLive()
                    self.refreshStory()
                } else {
                    self.relayout(transition)
                }
            }
        }
    }

    private func adopt(_ map: ReclaimMap, _ new: Suggestions, _ change: ChangeMap, _ rows: [ChangeRow]) {
        reclaim = map
        suggestions = new
        winsScanID = tree?.scanID
        changes = change
        changeRows = rows
        changeTotal = change.usesHistory ? change.total : rows.reduce(0) { $0 + $1.delta }
        changeCaption = change.caption
        refreshShownRows()
        tickTheTrash()
        refreshPlanNumbers()
    }

    /// What could go in this tree, and which suggestion each folder belongs to. One piece of work, so the two always match.
    nonisolated static func suggest(tree: DiskTree, rules: RuleBook, running: Set<String>, facts: Facts, kept: [PlanList.KeptThing]) -> (Suggestions, ReclaimMap) {
        let wins = Wins.build(tree: tree, rules: rules, running: running, facts: facts)
        let built = Sections.build(from: wins, tree: tree, facts: facts)
        return (built, reclaimMap(tree: tree, built, kept: kept))
    }

    nonisolated static func reclaimMap(tree: DiskTree, _ suggestions: Suggestions, kept: [PlanList.KeptThing]) -> ReclaimMap {
        let ids = Set(kept.map(\.id))
        return ReclaimMap(tree: tree, rows: suggestions.rows.filter { !ids.contains($0.id) })
    }

    func runningBundleIDs() -> Set<String> {
        var running = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { running.insert(id) }
            if let name = app.localizedName { running.insert(Wins.runningKey(name: name)) }
        }
        return running
    }

    func switchVolume(_ facts: VolumeFacts) {
        guard facts.mountPath != volume?.mountPath else { return }
        activeScan?.scanner.cancel()
        isScanning = false
        volume = facts
        tree = nil
        // The plan's node numbers belong to the disk that was on screen, and so does everything worked out from them.
        planNodes = [:]
        planExcluded = []
        planSet = nil
        planBack = nil
        nodeOfPath = [:]
        cachedAfterPlan = nil
        flatRows = []
        rowOfNode = [:]
        winsScanID = nil
        otherCopies = [:]
        takenOut = []
        expandedRow = nil
        focus = 0
        trail = []
        selected = nil
        suggestions = Suggestions()
        boxes = []
        shownRows = []
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
        readOtherDisksQuietly()
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
        if age > 900 || rescanWhenBack {
            rescanWhenBack = false
            scan()
        }
        if lens == .freeUp, !plan.isEmpty { runChecks() }
    }

    // MARK: Insights, worked out off the main thread

    /// Numbers changed within the same tree, after moving something to the Trash.
    func rebuildInsights() {
        guard let tree else { return }
        let rules = self.rules
        let version = treeVersion
        let window = changeWindow
        let running = runningBundleIDs()
        let facts = self.facts
        let kept = plan.kept
        Task.detached(priority: .userInitiated) {
            let (wins, map) = Self.suggest(tree: tree, rules: rules, running: running, facts: facts, kept: kept)
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
    func drawing(_ tree: DiskTree, after: AfterPlan? = nil) -> RingLayout {
        let planned = plannedTest()
        var layout = RingLayout.build(tree: tree, focus: focus, colorer: colorer(tree), planned: after == nil ? planned : nil, after: after)
        if lens == .map { layout.calmTinyPieces(viewBytes: tree.totals[Int(focus)]) }
        if after == nil { layout.addMarks(ringMarks(), tree: tree) }
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
            return Lenses.reclaimColorer(map: reclaim, colours: mapColours, planned: plannedTest())
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

    func placeLabels(after delay: Double) {
        labelTask?.cancel()
        withAnimation(.easeOut(duration: 0.1)) { labelsVisible = false }
        labelTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.labels = self.makeLabels()
            withAnimation(.easeOut(duration: 0.28)) { self.labelsVisible = true }
        }
    }

    func makeLabels() -> [MapLabel] {
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
            hotBox = nil
            hotRow = nil
            return
        }
        let layout = engine.layout
        let p = layout.pieces[index]
        // The list says so too: one set of data, shown two ways.
        if lens == .freeUp, let at = reclaim?.rowIndex(of: p.node), let id = reclaim?.rowIDs[at] {
            hotRow = id
            hotBox = boxOfRow[id]
        } else {
            hotRow = nil
            hotBox = nil
        }
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
        if lens == .freeUp, !p.isSmaller, !p.isMark, !n.has(NodeFlag.free), tree.path(p.node) != nil {
            note = isPlanned(p.node) ? "Selected. Click to take it out." : "Click to select it. Double-click to open."
        } else if lens == .changes, let changes {
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

    /// Lights up many things at once: every node_modules on the disk. Whatever is too small to draw lights what holds it.
    func highlight(nodes: [UInt32]) {
        guard let tree, !nodes.isEmpty else { setHover(nil); engine.setEmphasis(primary: nil, related: []); return }
        lastHoverIndex = nil
        hover = nil
        hotBox = nil
        hotRow = nil
        let lit = engine.layout.lit(by: nodes, tree: tree)
        engine.setEmphasis(primary: nil, related: lit.full, ancestors: lit.holding)
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

    func click(at polar: (angle: Float, radius: Float)?, count: Int = 1) {
        guard let polar else { return }
        if polar.radius < RingLayout.hole {
            goUp()
            return
        }
        guard let index = engine.layout.hit(angle: polar.angle, radius: polar.radius) else {
            selected = nil
            return
        }
        click(piece: index, count: count)
    }

    func click(piece index: Int, count: Int = 1) {
        guard let tree, index < engine.layout.pieces.count else { return }
        let p = engine.layout.pieces[index]
        let n = tree.nodes[Int(p.node)]
        // In Free Up a click means "this too", and a double-click opens it, as in the Finder.
        if lens == .freeUp, !n.has(NodeFlag.free), !p.isSmaller {
            if count == 1 || count == 2 { togglePiece(p.node) }
            if count < 2 { return }
        }
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
        pointing = nil
        hotBox = nil
        hotRow = nil
        engine.setCalm(new == .map ? 1 : (new == .freeUp ? 0.55 : 0))
        engine.setPreview(0, color: .zero)
        refreshGhost()
        if new == .freeUp, !plan.isEmpty { runChecks() }
        relayout(.recolor, labelDelay: 0.2)
        // Free Up and Changes want the whole picture, so now you're waiting on the scan.
        if tree?.isPartial == true, !scanIsHurrying { activeScan?.scanner.setHurry(new != .map) }
    }

    // MARK: Taking things out of the picture

    /// Takes something out of the picture, and into the Trash piece. If you were looking inside it, you step back to the
    /// folder that held it. What another copy still holds stays on the disk, and shows up there.
    func takeOut(_ node: UInt32, from tree: DiskTree, trueBytes: UInt64? = nil) -> UInt64 {
        let bytes = tree.totals[Int(node)]
        let real = min(trueBytes ?? bytes, bytes)
        if focus != 0, tree.isInside(focus, node) {
            focus = tree.nodes[Int(node)].parent
            trail = []
        }
        if let chosen = selected, tree.isInside(chosen, node) { selected = nil }
        var stillHeld: UInt32?
        if real &+ 1_000_000 < bytes { stillHeld = Accounting.otherCopies(of: [node], in: tree).folders.first }
        tree.remove(node)
        if let trash = trashNode(in: tree) { tree.add(real, to: trash) }
        let heldBy = stillHeld ?? tree.hidden
        tree.add(bytes &- real, to: heldBy)
        takenOut.append((node, real, tree, heldBy, bytes &- real))
        // Nothing left to show here.
        while focus != 0, tree.totals[Int(focus)] == 0 { focus = tree.nodes[Int(focus)].parent }
        return real
    }

    func trashNode(in tree: DiskTree) -> UInt32? {
        func child(of parent: UInt32, named name: String) -> UInt32? {
            var c = tree.nodes[Int(parent)].firstChild
            while c != 0 {
                if tree.name(c) == name { return c }
                c = tree.nodes[Int(c)].nextSibling
            }
            return nil
        }
        if tree.home != 0 { return child(of: tree.home, named: ".Trash") }
        // On any other disk it's a folder at the top of the disk.
        for top in tree.children(0) where tree.nodes[Int(top)].has(NodeFlag.anchor) {
            if let trashes = child(of: top, named: ".Trashes") { return trashes }
        }
        return nil
    }

    func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
    }

    func openApp(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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
        if let path = tree.path(p.node), Safety.canTrash(path) {
            menu.addItem(.separator())
            // The map can change while a menu is open, and these numbers only mean something in this one.
            if isPlanned(p.node) {
                add("Unselect it", "minus.circle") { if self.tree === tree { self.togglePiece(p.node) } }
            } else {
                add("Select it", "plus.circle") { if self.tree === tree { self.togglePiece(p.node) } }
            }
            for disk in otherDisks(for: path) {
                add("Move to \(disk.name)", "externaldrive") { if self.tree === tree { self.planMove(node: p.node, to: disk) } }
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
    /// An app's own settings live in a folder nothing else is allowed to touch.
    static func canUninstall(_ path: String) -> Bool {
        if canTrash(path) { return true }
        if HiddenNames.isOn { return false }
        let visible = path.hasPrefix("/System/Volumes/Data/") ? String(path.dropFirst("/System/Volumes/Data".count)) : path
        return visible.hasPrefix(NSHomeDirectory() + "/Library/Preferences/") && visible.hasSuffix(".plist")
    }

    static func canTrash(_ path: String) -> Bool {
        if HiddenNames.isOn { return false }
        let visible = path.hasPrefix("/System/Volumes/Data/") ? String(path.dropFirst("/System/Volumes/Data".count)) : path
        let home = NSHomeDirectory()
        let protected: Set<String> = [
            "/", home, "/Users", "/Applications", "/Library", "/System", "/private", "/usr", "/opt", "/bin", "/sbin", "/etc", "/var",
            home + "/Library", home + "/Desktop", home + "/Documents", home + "/Downloads", home + "/Pictures", home + "/Movies",
            home + "/Music", home + "/.Trash", home + "/Library/Application Support", home + "/Library/Caches", home + "/Library/Preferences",
            home + "/Library/Containers", home + "/Library/Group Containers", home + "/.config", home + "/.ssh", home + "/dev",
        ]
        if protected.contains(visible) { return false }
        for keep in ["/.Trash", "/.ssh", "/.gnupg", "/Library/Keychains", "/Library/Preferences", "/Library/Mail", "/Library/Messages", "/Library/Safari",
                     "/Library/Mobile Documents", "/Library/CloudStorage", "/Library/Calendars", "/Library/Reminders", "/Library/Accounts", "/Library/Cookies",
                     "/Music/Music"]
        where PathMath.isInside(visible, home + keep) { return false }
        // A package is one thing to the Finder. What's inside isn't yours to pick apart, and a library of photos is only
        // safe in the hands of its own app.
        let parts = visible.split(separator: "/")
        for (at, part) in parts.enumerated() {
            if part.hasSuffix(".photoslibrary") || part.hasSuffix(".musiclibrary") || part.hasSuffix(".tvlibrary") || part.hasSuffix(".imovielibrary") { return false }
            if at < parts.count - 1, part.hasSuffix(".app") || part.hasSuffix(".framework") || part.hasSuffix(".fcpbundle") || part.hasSuffix(".logicx")
                || part.hasSuffix(".sparsebundle") || part.hasSuffix(".xcarchive") || part.hasSuffix(".band") { return false }
        }
        if visible.hasPrefix(home + "/") { return true }
        if visible.hasPrefix("/Applications/") { return true }
        if visible.hasPrefix("/Volumes/") { return visible.split(separator: "/").count > 2 }
        return false
    }
}
