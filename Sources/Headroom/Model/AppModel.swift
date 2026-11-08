import AppKit
import Observation
import SwiftUI

/// Something you asked to send to the Trash, and what's using it.
struct BusyThing {
    var path: String
    var title: String
    var why: String
}

/// A scan waiting to run, and how it was asked for.
struct ScanRequest {
    var hurry = false
    var readAll = false
}

/// The three questions the map can answer. The geometry stays put, so changing the question never loses your place.
enum Lens: String, CaseIterable, Identifiable {
    case map = "Map"
    case changes = "Changes"
    case freeUp = "Free Up"
    var id: String { rawValue }
    var help: String {
        switch self {
        case .map: "What's on the disk, by kind"
        case .changes: "What changed lately, and what hasn't for a long time"
        case .freeUp: "Get space back, what you'd miss least first"
        }
    }
}

/// Where the ring sits in the map's part of the window, which is all of it but the inspector. The ring stays centred there.
struct RingGeometry: Equatable {
    var center: CGPoint
    var radius: CGFloat
    var mapWidth: CGFloat
    var windowHeight: CGFloat

    static func make(size: CGSize) -> RingGeometry {
        let usable = max(size.width, 320)
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
    /// What it is, if its files also have another path.
    var links: String?
    /// Whether the line under the size says when it was last used, once that's worked out.
    var tellsUse = false
    /// It's in the Trash, which is all the line says.
    var inTrash = false
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
    /// Goes up each time the Full Disk Access guide should come forward.
    var accessGuideRequests = 0
    @ObservationIgnored var accessGuideShowing = false
    var accessCardDismissed = false

    // Where you are
    var focus: UInt32 = 0 { didSet { if oldValue != focus { pointedThing = nil; closeLook(); refreshShownRows(); refreshChangeRows(); visitChanged() } } }
    /// What the card Space opens is showing, when it's open.
    var look: Look?
    var lookCursor: Int?
    @ObservationIgnored var lookWatch: Any?
    @ObservationIgnored var checkRun: Task<Void, Never>?
    @ObservationIgnored var lookCardFrame = CGRect.zero
    @ObservationIgnored var lookContentFrame = CGRect.zero
    @ObservationIgnored var factsCache: [UInt32: String] = [:]
    @ObservationIgnored var factsVersion = -1
    /// Where you've been, for the back and forward arrows, and where in that you are now.
    var visited = [Visit()]
    var visitAt = 0
    @ObservationIgnored var visitPending = false
    /// Where you've been, so Back returns to the picture you came from.
    @ObservationIgnored var trail: [UInt32] = []
    var lens: Lens = .map
    var panelOpen = true { didSet { if oldValue != panelOpen { rememberWindow() } } }
    @ObservationIgnored var inspectorWidthTask: Task<Void, Never>?
    /// How the rings are sized, picked in View › Rings and kept for the next launch.
    var ringSizes = RingSizes.saved {
        didSet {
            guard ringSizes != oldValue else { return }
            ringSizes.save(changedFrom: oldValue)
            relayout(.settle)
        }
    }
    /// How many rings the picture has now, and how many it could fill. The menu offers no more than that.
    var ringsDrawn = RingSizes.saved.depth
    var ringReach = RingSizes.most
    var hover: HoverInfo?
    var selected: UInt32? { didSet { if oldValue != selected { refreshStory(); visitChanged() } } }
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
    /// A clean is being put back where it came from.
    var isPuttingBack = false
    /// A few words beside the ring, for when a click can't do what you asked.
    var tip: String?
    var tipOffersUndo = false
    /// Send to Trash found something using this, and is asking whether it should go anyway.
    var busyToSend: BusyThing?
    /// Whether the ring lit what's lit, or something drawn over it did: a name around the ring, a row in the panel or the
    /// card. The ring only puts out what it lit itself, so the pointer moving over that row doesn't put the row's light out.
    @ObservationIgnored private var ringLitIt = true
    /// The file the last click landed on, so that a second click can open that file and no other.
    @ObservationIgnored private var clickedFile: UInt32?
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
    /// The clean a quit was waiting for has stopped. The quit may still be waiting for a new version to go into place.
    @ObservationIgnored var cleanStoppedForQuit = false
    /// A scan held back while things leave the disk or come back to it: one a clean stopped, or one asked for meanwhile.
    @ObservationIgnored var scanAfterClean: ScanRequest?

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
    @ObservationIgnored let windowHidden = LockedFlag()
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
    /// What got smaller, when there's an earlier scan to compare with.
    var changeShrank: [ChangeRow] = []
    /// Whether Changes compares with an earlier scan, or goes by file dates.
    var changeUsesHistory = false
    var history: [HistoryPoint] = []

    // Names around the ring
    var labels: [MapLabel] = []
    var labelsVisible = false

    // Search
    var searchText = ""
    /// Whether the search field in the toolbar has the keyboard, as ⌘F gives it.
    var searchActive = false
    var searchResults: [UInt32] = []
    /// Something is typed in the search field, so the inspector lists what it finds, wherever the keyboard is.
    var isSearching: Bool { !searchText.isEmpty }

    @ObservationIgnored let engine = MapEngine()
    @ObservationIgnored let rules = RuleBook(homePath: NSHomeDirectory())
    @ObservationIgnored var activeScan: DiskScan?
    /// The startup disk's change journal, collected from where the map on screen was read, so that a refresh only reads
    /// what has changed since.
    @ObservationIgnored var journal: ChangeJournal.Watcher?
    @ObservationIgnored private var labelTask: Task<Void, Never>?
    @ObservationIgnored private var linksTask: Task<Void, Never>?
    /// The name under the pointer, off the ring: a row, a label, the path under the ring.
    @ObservationIgnored var pointedThing: NamedThing?
    @ObservationIgnored var reclaim: ReclaimMap?
    @ObservationIgnored private var changes: ChangeMap?
    /// Which scan's numbering the Changes map uses.
    @ObservationIgnored private var changesScanID: UUID?
    @ObservationIgnored var scanGeneration = 0
    @ObservationIgnored private var didStart = false
    /// Trees on their way to the screen, so a scan starting now knows the ring won't be empty. At launch there can be two:
    /// the saved map, and the scan that refreshes it.
    @ObservationIgnored private(set) var mapsOnTheirWay = 0
    @ObservationIgnored private var zoomedAt = Date.distantPast
    @ObservationIgnored private var heldPicture: DiskTree?
    @ObservationIgnored private var insightsRunning = false
    @ObservationIgnored private var insightsAt = Date.distantPast
    /// The Map view's colours for the picture on screen, so the list on the right can match the ring.
    @ObservationIgnored private var ringColours: RingColours?
    @ObservationIgnored private let colourMemory = ColourMemory()
    @ObservationIgnored var cacheLoadMilliseconds = 0.0
    /// How the last scan went about it, for a scripted check.
    @ObservationIgnored var lastScanNote = ""
    @ObservationIgnored var lastHoverIndex: Int?
    @ObservationIgnored var lastPointer: (angle: Float, radius: Float)?
    @ObservationIgnored var nameCache: [UInt32: String] = [:]
    @ObservationIgnored weak var mapView: MapHostView?

    // MARK: Starting

    func start() {
        guard !didStart else { return }
        didStart = true
        loadPlan()
        // Asking for each folder is gone: it brought up a prompt per folder, and still left the rest needing Full Disk Access.
        UserDefaults.standard.removeObject(forKey: "askPerFolder")
        hasFullAccess = Self.mayReadEverything()
        volumes = VolumeFacts.available()
        volume = volumes.first
        guard let volume else { return }
        if !hasFullAccess, volume.isBoot, Self.guideAtLaunch {
            // Once the window is up, so the guide opens over the map.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.accessGuideRequests += 1 }
        }
        history = History.points(for: volume)
        let launch = DispatchTime.now()
        var saved: DiskTree?
        // Without Full Disk Access nothing is read, the saved map included: whatever it names would be looked at.
        if hasFullAccess, !CommandLine.arguments.contains("--no-cache"), let cached = TreeCache.load(for: volume, rules: rules) {
            present(cached, transition: .appear)
            cacheLoadMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - launch.uptimeNanoseconds) / 1e6
            watchJournal(from: cached, on: volume)
            saved = cached
        }
        restoreWindow()
        scan(refreshing: saved)
        readOtherDisksQuietly()
    }

    /// For a saved map: what changed while the app was closed is in the journal, unless so much has happened that reading
    /// the disk is quicker than going through it.
    private func watchJournal(from map: DiskTree, on facts: VolumeFacts) {
        guard facts.isBoot, let place = map.journal, let behind = ChangeJournal.distance(from: place, for: facts.mountPath),
              behind < 3_000_000 else { return }
        journal?.stop()
        journal = ChangeJournal.Watcher(from: place, roots: ChangeJournal.roots(of: map))
    }

    /// The map a quiet scan can refresh, reading only what has changed since: one the startup disk's scan left whole, read
    /// in full within the last day, by this build and the same way, and that the journal has been watched from.
    private func refreshable(_ map: DiskTree?, facts: VolumeFacts, scan: DiskScan) -> DiskTree? {
        guard facts.isBoot, !HiddenNames.isOn, let map, map.isWhole, !map.isPartial, let place = map.journal,
              map.rootPath == facts.mountPath, Date().timeIntervalSince(map.fullReadAt) < 86_400,
              map.readGuarded == scan.scanner.touchGuarded,
              let journal, journal.base == place, journal.roots == scan.watchRoots else { return nil }
        return map
    }

    /// Reads the disk. With no map on screen, you get a picture from the first frame that fills in as the scan goes, and it
    /// works like any other map. With a map on screen, the scan stays out of the way and the map glides to the new numbers
    /// at the end, and it only reads what has changed since that map, when it can. `hurry` is for when you asked: it runs at
    /// full power and reads everything, even if a quiet scan is already under way. `readAll` reads everything quietly.
    func scan(hurry: Bool = false, readAll: Bool = false, refreshing given: DiskTree? = nil) {
        if isScanning {
            if hurry {
                scanIsHurrying = true
                activeScan?.scanner.setHurry(true)
            }
            return
        }
        // Nothing replaces the map while things are leaving it, so the scan waits until they've gone.
        if isCleaning {
            scanOnceCleaned(hurry: hurry, readAll: readAll)
            return
        }
        guard let volume else { return }
        guard let facts = VolumeFacts.read(path: volume.mountPath) else { return }
        self.volume = facts
        hasFullAccess = Self.mayReadEverything()
        guard hasFullAccess else {
            showWithoutAccess(facts)
            // Asking to read the disk again, with nothing allowed to be read, brings up the way to allow it.
            if hurry { accessGuideRequests += 1 }
            return
        }
        let scan = DiskScan(facts: facts, rules: rules, fullAccess: hasFullAccess)
        activeScan = scan
        isScanning = true
        scanIsHurrying = hurry
        scanFiles = 0
        scanGeneration += 1
        heldPicture = nil
        let generation = scanGeneration
        let showPictures = (tree == nil || tree?.isPartial == true) && mapsOnTheirWay == 0
        let mode: ScanMode = hurry ? .full : (showPictures ? .firstLook : .quiet)
        // Free space, macOS and swap come straight from the disk, so the very first frame already has them.
        if showPictures { show(scan.picture()) }
        let base = hurry || readAll ? nil : refreshable(given ?? tree, facts: facts, scan: scan)
        if base == nil, facts.isBoot {
            // Everything's read, and the journal is watched from here, for the refresh after.
            journal?.stop()
            journal = ChangeJournal.Watcher.starting(roots: scan.watchRoots)
            scan.place = journal?.base
        }
        let journal = base == nil ? nil : self.journal

        Thread.detachNewThread { [weak self] in
            Thread.current.qualityOfService = .userInitiated
            var note = "read everything"
            if let base, let journal {
                // At launch, what happened while the app was closed comes first.
                let asked = Date()
                if let place = base.journal, journal.waitForHistory(timeout: 6), let taken = journal.take(from: place) {
                    if scan.refresh(from: base, changes: taken.changes, place: taken.next) {
                        note = String(format: "refreshed: %.2f s for the journal, %d folders changed, %d of the map's read again",
                                      Date().timeIntervalSince(asked), taken.changes.folders.count, scan.foldersToRead)
                    } else {
                        scan.place = taken.next
                    }
                } else {
                    let fresh = ChangeJournal.Watcher.starting(roots: scan.watchRoots)
                    scan.place = fresh?.base
                    DispatchQueue.main.async {
                        guard let self, self.scanGeneration == generation else { fresh?.stop(); return }
                        self.journal?.stop()
                        self.journal = fresh
                    }
                }
            }
            // A picture is a copy of the whole tree, so there's never a second one waiting behind one nobody has looked at yet.
            let pictureWaiting = LockedFlag()
            let windowHidden = self?.windowHidden
            scan.run(mode: mode, tick: {
                let files = Int(scan.scanner.filesSoFar)
                let picture = showPictures && !pictureWaiting.value && windowHidden?.value != true ? scan.picture() : nil
                if picture != nil { pictureWaiting.value = true }
                DispatchQueue.main.async {
                    if picture != nil { pictureWaiting.value = false }
                    guard let self, self.scanGeneration == generation else { return }
                    self.scanFiles = files
                    if let picture { self.show(picture) }
                }
            })
            if scan.surprised {
                DispatchQueue.main.async {
                    guard let self, self.scanGeneration == generation else { return }
                    // Read again in full, and still at full power if you were waiting for it.
                    let hurried = self.scanIsHurrying
                    self.stopScan()
                    self.scan(hurry: hurried, readAll: true)
                }
                return
            }
            let tree = scan.tree
            // A scan that was stopped, or a disk that was unplugged halfway, has only part of the picture. Keeping it
            // would show the wrong map on the next launch and spoil the next comparison.
            let complete = !scan.scanner.wasCancelled && VolumeFacts.read(path: facts.mountPath) != nil
            let snapshot = complete ? History.record(tree: tree, facts: facts) : []
            if complete {
                TreeCache.save(tree, for: facts, rules: scan.rules)
                DiskIndex.save(tree)
            }
            DispatchQueue.main.async {
                guard let self, self.scanGeneration == generation else { return }
                guard complete else {
                    self.stopScan()
                    self.volumesChanged()
                    return
                }
                self.isScanning = false
                self.scanIsHurrying = false
                self.heldPicture = nil
                self.lastScanNote = note
                self.scanFiles = Int(tree.totalFiles[0])
                self.activeScan = nil
                self.history = snapshot
                self.present(tree, transition: .settle)
            }
        }
    }

    /// Without Full Disk Access, Headroom reads nothing at all, so macOS never has a folder to ask you about. The ring shows
    /// what the disk itself reports: free space, macOS's own volumes, and the rest in one piece, waiting for access.
    private func showWithoutAccess(_ facts: VolumeFacts) {
        journal?.stop()
        journal = nil
        let waiting = DiskScan(facts: facts, rules: rules, fullAccess: false).picture()
        waiting.displayNames[waiting.hidden] = "Waiting for access"
        scanFiles = 0
        // A map read before access went is put away too, so nothing on it gets looked at.
        if tree?.isPartial == false { tree = nil }
        show(waiting)
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
            if isSearching { runSearch() }
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
        let restarted = current.scanID != picture.scanID
        if restarted {
            // The scan started over, so its folders have new numbers, and nothing that holds the old ones can stay.
            focus = 0
            trail = []
            selected = nil
            resetVisits()
            nameCache = [:]
            suggestions = Suggestions()
            boxes = []
            winsScanID = nil
            flatRows = []
            rowOfNode = [:]
            shownRows = []
            otherCopies = [:]
            changes = nil
            changesScanID = nil
            reclaim = nil
            changeRows = []
            changeShrank = []
        }
        tree = picture
        treeVersion += 1
        if !plan.isEmpty { resolvePlanSynchronously(in: picture) }
        refreshLive()
        if restarted, isSearching { runSearch() }
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
        if labelsVisible { Motion.animate(.spring(response: 0.81, dampingFraction: 1)) { labels = makeLabels() } }
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
            let change = Self.changeMap(tree: picture, window: window, rules: rules, facts: facts)
            let rows = change.rows(tree: picture, rules: rules)
            await MainActor.run {
                self.insightsRunning = false
                self.insightsAt = Date()
                guard self.tree?.isPartial == true, self.tree?.scanID == picture.scanID else { return }
                self.adopt(map, wins, change, rows, for: window)
                if self.isSearching { self.runSearch() }
                if self.lens != .map { self.refreshLive() }
            }
        }
    }

    /// With the window out of sight, nothing is drawn, and a running scan makes no pictures for it.
    func windowCameOrWent(isVisible: Bool) {
        windowHidden.value = !isVisible
        if isVisible { activeScan?.tickSoon() }
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

    /// Stops a running scan and starts again. One you were waiting for stays one you're waiting for.
    func restartScan(hurry: Bool = false) {
        let hurried = scanIsHurrying
        stopScan()
        scan(hurry: hurry || hurried)
    }

    /// Ends the scan that's running, if there is one. Nothing it still sends is shown, not even its last picture, and it's
    /// no longer one you're waiting for.
    func stopScan() {
        activeScan?.scanner.cancel()
        activeScan = nil
        isScanning = false
        scanIsHurrying = false
        heldPicture = nil
        scanGeneration &+= 1
    }

    /// A scan for when the things leaving the disk have gone. Asked for more than once, it does the most that was asked.
    func scanOnceCleaned(hurry: Bool = false, readAll: Bool = false) {
        let wanted = scanAfterClean ?? ScanRequest()
        scanAfterClean = ScanRequest(hurry: wanted.hurry || hurry, readAll: wanted.readAll || readAll)
    }

    /// They've gone, so the scan that was waiting runs now.
    func runScanAfterClean() {
        guard let wanted = scanAfterClean else { return }
        scanAfterClean = nil
        scan(hurry: wanted.hurry, readAll: wanted.readAll)
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
        mapsOnTheirWay += 1
        Task.detached(priority: .userInitiated) {
            let (wins, map) = Self.suggest(tree: newTree, rules: rules, running: running, facts: facts, kept: kept)
            let change = Self.changeMap(tree: newTree, window: window, rules: rules, facts: facts)
            let rows = change.rows(tree: newTree, rules: rules)
            await MainActor.run {
                self.mapsOnTheirWay -= 1
                // You may have picked another disk while this was being worked out.
                guard newTree.rootPath == self.volume?.mountPath else { return }
                // The end of a scan you've been watching: its folders are the same ones, so you simply stay where you are.
                let sameScan = self.tree?.scanID == newTree.scanID
                var newFocus: UInt32?
                if !sameScan {
                    self.pointedThing = nil
                    self.closeLook()
                    self.carryVisits(to: newTree)
                    // Keep your place, if the folder you were looking at still exists.
                    var keepPath: String?
                    if self.focus != 0, let tree = self.tree { keepPath = tree.path(self.focus) }
                    newFocus = keepPath.flatMap { newTree.find(path: $0) } ?? 0
                    self.trail = []
                    self.selected = nil
                }
                self.tree = newTree
                self.nameCache = [:]
                self.treeVersion += 1
                // Only now, so what moving there sets off reads the new tree with the new tree's numbers.
                if let newFocus { self.focus = newFocus }
                self.resolvePlanSynchronously(in: newTree)
                self.adopt(map, wins, change, rows, for: window)
                // What was read for a saved map is read again once the scan after it has finished.
                var isFresh = true
                if case .appear = transition { isFresh = false }
                self.gatherFacts(for: newTree, afresh: isFresh)
                if sameScan {
                    self.refreshLive()
                    self.refreshStory()
                } else {
                    self.relayout(transition)
                }
                // What a search found is numbered in the tree it was made from, and a scan you watched ends with folders
                // it hadn't read when you typed.
                if self.isSearching { self.runSearch() }
            }
        }
    }

    private func adopt(_ map: ReclaimMap, _ new: Suggestions, _ change: ChangeMap, _ rows: [ChangeRow], for window: ChangeWindow) {
        reclaim = map
        suggestions = new
        winsScanID = tree?.scanID
        // Another window may have been picked while this was worked out, and then that one is worked out again.
        if window == changeWindow {
            show(change, rows)
        } else if let tree {
            let current = Self.changeMap(tree: tree, window: changeWindow, rules: rules, facts: facts)
            show(current, current.rows(tree: tree, rules: rules))
        }
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
        stopScan()
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
        resetVisits()
        suggestions = Suggestions()
        boxes = []
        shownRows = []
        changeRows = []
        changeShrank = []
        changes = nil
        changesScanID = nil
        reclaim = nil
        searchResults = []
        labels = []
        engine.apply(RingLayout(), .settle)
        history = History.points(for: facts)
        let cached = hasFullAccess ? TreeCache.load(for: facts, rules: rules) : nil
        if let cached { present(cached, transition: .appear) }
        scan(refreshing: cached)
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
        let access = Self.mayReadEverything()
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
        if lens == .freeUp, !plan.isEmpty { runChecks(fresh: true) }
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
            let change = Self.changeMap(tree: tree, window: window, rules: rules, facts: facts)
            let rows = change.rows(tree: tree, rules: rules)
            await MainActor.run {
                guard self.treeVersion == version, self.tree === tree else { return }
                self.adopt(map, wins, change, rows, for: window)
                if self.lens != .map { self.relayout(.recolor) }
            }
        }
    }

    func setChangeWindow(_ window: ChangeWindow) {
        changeWindow = window
        guard let tree else { return }
        let change = Self.changeMap(tree: tree, window: window, rules: rules, facts: facts)
        show(change, change.rows(tree: tree, rules: rules))
        if lens == .changes { relayout(.recolor) }
    }

    /// The map for a Changes window. Looking back at what's gone untouched also needs to know what to leave out, and what
    /// you're known to have used lately.
    nonisolated static func changeMap(tree: DiskTree, window: ChangeWindow, rules: RuleBook, facts: Facts) -> ChangeMap {
        guard case .untouched(let days) = window else { return ChangeMap(tree: tree, window: window) }
        return ChangeMap(tree: tree, window: window, rules: rules, used: ChangeMap.usedRecently(facts, in: tree, days: days))
    }

    private func show(_ change: ChangeMap, _ rows: [ChangeRow]) {
        changes = change
        changesScanID = tree?.scanID
        // A comparison counts down from free space, and what's untouched is the whole of it. Otherwise it's what the whole
        // disk's list adds up to.
        changeTotal = change.usesHistory || change.isUntouched ? change.total : rows.reduce(0) { $0 + $1.delta }
        changeCaption = change.caption
        changeUsesHistory = change.usesHistory
        refreshChangeRows(wholeDisk: rows)
    }

    /// What grew, shrank or went untouched in the folder you're in, as on the ring. The whole disk's list comes with its map.
    /// A folder's is worked out here, and quickly, because only what changed by 100 MB or more is looked into.
    func refreshChangeRows(wholeDisk: [ChangeRow]? = nil) {
        // A map made for an earlier scan numbers things differently, so its rows wait for the map of this one.
        guard let tree, let changes, changesScanID == tree.scanID else { return }
        let root = focus == 0 ? 0 : RingLayout.chainTail(tree: tree, focus)
        changeRows = root == 0 ? (wholeDisk ?? changes.rows(tree: tree, rules: rules)) : changes.rows(tree: tree, rules: rules, under: root)
        changeShrank = changes.usesHistory ? changes.rows(tree: tree, rules: rules, shrinking: true, under: root) : []
    }

    // MARK: Drawing

    func relayout(_ transition: RingTransition, labelDelay: Double = 0.18) {
        guard let tree else { return }
        let layout = drawing(tree)
        engine.apply(layout, transition)
        mapView?.voiceOverLayoutChanged()
        lastHoverIndex = nil
        hover = nil
        placeLabels(after: labelDelay)
        refreshStory()
        refreshHover(after: 0.42)
    }

    /// The picture for the folder in view.
    func drawing(_ tree: DiskTree, after: AfterPlan? = nil) -> RingLayout {
        let planned = plannedTest()
        var layout = RingLayout.build(tree: tree, focus: focus, colorer: colorer(tree), planned: after == nil ? planned : nil, after: after,
                                      sizes: ringSizes)
        // The picture on screen, rather than the one while ⌥ is held, sets what the Rings menu offers.
        if after == nil {
            if ringsDrawn != layout.rings { ringsDrawn = layout.rings }
            if ringReach != layout.reach { ringReach = layout.reach }
        }
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
        Motion.animate(.easeOut(duration: 0.1)) { labelsVisible = false }
        labelTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.labels = self.makeLabels()
            Motion.animate(.easeOut(duration: 0.28)) { self.labelsVisible = true }
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
        ringLitIt = true
        lastPointer = polar
        guard let polar else { setHover(nil); return }
        setHover(engine.layout.hit(angle: polar.angle, radius: polar.radius))
    }

    /// The pointer is on something drawn over the ring. To the ring that's nothing, but what's there may light something itself.
    func pointerOffRing() {
        lastPointer = nil
        if ringLitIt { setHover(nil) }
    }

    func enterLabel(piece index: Int) {
        ringLitIt = false
        lastPointer = nil
        setHover(index)
    }

    /// Going straight from one name to the next, the next may have said so first, and then this one isn't lit any more.
    func leaveLabel(piece index: Int) {
        guard lastHoverIndex == index else { return }
        setHover(nil)
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
        // With the card open, what it's about stays lit whenever the pointer isn't on something else.
        let index = index ?? lookPieceIndex
        guard index != lastHoverIndex else { return }
        lastHoverIndex = index
        linksTask?.cancel()
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
        // Whether its files also have another path, and when it was last used, are worked out off the main thread from
        // the moment the pointer arrives, and the line shows them when they're ready. Pointing at something else stops it.
        let wantsLinks = !info.inTrash && !p.isSmaller && p.style != 1 && p.style != 2 && !tree.links.isEmpty && tree.nodes[Int(p.node)].flags & NodeFlag.synthetic == 0
        if hasFullAccess, wantsLinks || info.tellsUse {
            let node = p.node, bytes = p.bytes, tellsUse = info.tellsUse
            linksTask = Task { [weak self] in
                let work = Task.detached(priority: .userInitiated) {
                    LastUse.find(node, bytes: bytes, links: wantsLinks, use: tellsUse, in: tree)
                }
                let found = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                guard let self, found.links != nil || found.use != nil, !Task.isCancelled, self.lastHoverIndex == index else { return }
                info.links = found.links
                if let use = found.use { info.note = use }
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
        var tellsUse = false
        let ownShape = p.node == tree.free || p.node == tree.hidden
        if lens == .changes, let changes, changes.isUntouched {
            // All of it, or how much of it. A piece that's been touched says when, as it would on the map.
            let untouched = changes.value(of: p.node)
            if untouched > 0 {
                // The window is in the panel, so a part only needs saying how much: the whole line has to fit in the middle.
                note = Double(untouched) >= Double(p.bytes) * 0.999 ? "Untouched \(changeWindow.span)" : "\(formatBytes(UInt64(untouched))) untouched"
            } else if !ownShape, !p.isSmaller, !p.isMark, p.style != 2, !(tree.isPartial && tree.isStillGrowing(p.node)) {
                share = ""
                tellsUse = !(n.has(NodeFlag.synthetic) || (n.rule != 0 && rules.rule(n.rule).tier == .handsOff))
            }
        } else if lens == .changes, let changes {
            let delta = changes.value(of: p.node)
            if delta > 0 { note = "+\(formatBytes(UInt64(delta))) \(changes.shortCaption)" }
            else if delta < 0 { note = "−\(formatBytes(UInt64(-delta))) \(changes.shortCaption)" }
        } else if !ownShape, !p.isSmaller, !p.isMark, p.style != 2, !(tree.isPartial && tree.isStillGrowing(p.node)) {
            // The ring already shows its share. Once the pointer rests, the line says when it was last used, except on
            // macOS's own parts, which have nothing to add.
            share = ""
            if let path = tree.path(p.node), LastUse.isInTrash(Facts.visible(path), home: NSHomeDirectory()) {
                return HoverInfo(pieceIndex: index, node: p.node, title: displayName(piece: p), bytes: p.bytes,
                                 share: "", note: LastUse.trashLine, links: nil, inTrash: true)
            }
            let leftAlone = n.has(NodeFlag.synthetic) || (n.rule != 0 && rules.rule(n.rule).tier == .handsOff)
            tellsUse = !leftAlone
        }
        return HoverInfo(pieceIndex: index, node: p.node, title: displayName(piece: p), bytes: p.bytes,
                         share: share, note: note, links: nil, tellsUse: tellsUse)
    }

    /// Lights up one thing from the panel or a label, as if the pointer were on it.
    func highlight(node: UInt32?) {
        ringLitIt = false
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
        ringLitIt = false
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
            if look != nil {
                showInLook(focus, steppingIn: false)
            } else {
                goUp()
            }
            return
        }
        guard let index = engine.layout.hit(angle: polar.angle, radius: polar.radius) else {
            if look != nil {
                closeLook()
            } else {
                selected = nil
            }
            return
        }
        click(piece: index, count: count)
    }

    /// Works out what this click means for a double-click. The first click on a folder has already gone in, so what's under the
    /// pointer at the second isn't what you meant: `ignore`. The second click on the same file opens it, as in the Finder.
    private func noteClick(on p: Piece, in tree: DiskTree, count: Int) -> (ignore: Bool, opensFile: Bool) {
        if count >= 2, Date().timeIntervalSince(zoomedAt) < NSEvent.doubleClickInterval { return (true, false) }
        let n = tree.nodes[Int(p.node)]
        let isFile = !p.isSmaller && !n.has(NodeFlag.free) && (!n.has(NodeFlag.directory) || n.firstChild == 0) && tree.path(p.node) != nil
        let opens = count == 2 && isFile && clickedFile == p.node
        clickedFile = isFile ? p.node : nil
        return (false, opens)
    }

    func click(piece index: Int, count: Int = 1) {
        guard let tree, index < engine.layout.pieces.count else { return }
        let p = engine.layout.pieces[index]
        let n = tree.nodes[Int(p.node)]
        let meaning = noteClick(on: p, in: tree, count: count)
        guard !meaning.ignore else { return }
        // With the card open, a click shows that piece in the card, and a double-click goes there.
        if look != nil {
            guard !p.isSmaller, tree.path(p.node) != nil else {
                closeLook()
                return
            }
            if count < 2 {
                showInLook(p.node, steppingIn: false)
                return
            }
            closeLook()
            if n.has(NodeFlag.directory), n.firstChild != 0 {
                zoom(into: p.tail, from: p)
            } else {
                selected = p.node
                showPanel(true)
                if meaning.opensFile { open(NamedThing(p.node)) }
            }
            return
        }
        // In Free Up a click means "this too", and a double-click opens it, as in the Finder.
        if lens == .freeUp, !n.has(NodeFlag.free), !p.isSmaller {
            if count == 1 || count == 2 { togglePiece(p.node) }
            if count < 2 { return }
        }
        open(piece: index)
        if meaning.opensFile { open(NamedThing(p.node)) }
    }

    /// A name around the ring opens what it names, in every view. Selecting is for the ring itself, so that reading a name
    /// can't select anything for the Trash.
    func openLabel(piece index: Int, count: Int = 1) {
        guard let tree, index < engine.layout.pieces.count else { return }
        let p = engine.layout.pieces[index]
        let meaning = noteClick(on: p, in: tree, count: count)
        guard !meaning.ignore else { return }
        closeLook()
        setHover(nil)
        open(piece: index)
        if meaning.opensFile { open(NamedThing(p.node)) }
    }

    private func open(piece index: Int) {
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
            showPanel(true)
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

    /// The folder this one is in, as the Finder's Enclosing Folder goes, however you got here. Esc instead goes back out the
    /// way you came in. Like Esc, it lets go of what's selected first.
    func goToEnclosingFolder() {
        if selected != nil {
            selected = nil
            return
        }
        guard let tree, focus != 0 else { return }
        var up = tree.nodes[Int(focus)].parent
        // Skip folders that would draw exactly the same picture.
        while up != 0, RingLayout.chainTail(tree: tree, up) == RingLayout.chainTail(tree: tree, focus) {
            up = tree.nodes[Int(up)].parent
        }
        if trail.last == up { trail.removeLast() }
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
        mapView?.voiceOverLayoutChanged()
        lastHoverIndex = nil
        hover = nil
        placeLabels(after: 0.34)
        refreshStory()
        refreshHover(after: 0.42)
        readFocusFirst()
    }

    func setLens(_ new: Lens) {
        guard new != lens else { return }
        closeLook()
        lens = new
        rememberWindow()
        selected = nil
        showPanel(true)
        pointing = nil
        pointedThing = nil
        hotBox = nil
        hotRow = nil
        engine.setCalm(new == .map ? 1 : (new == .freeUp ? 0.55 : 0))
        engine.setGlow(new == .changes ? 0.35 : 1)
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
        // Already in the Trash: taking it out again would count it twice, and putting it back twice would loop.
        guard !tree.nodes[Int(node)].has(NodeFlag.gone) else { return 0 }
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

    static let accessGuideDeclinedKey = "accessGuideDeclined"

    /// Without Full Disk Access, the guide to it opens at launch, unless you said not now to it in this version.
    static var guideAtLaunch: Bool {
        showsGuide(declined: UserDefaults.standard.string(forKey: accessGuideDeclinedKey), version: Updater.currentNumber,
                   scripted: ScriptRunner.path != nil, locked: actsLocked)
    }

    /// A scripted check only shows it when it acts as if access were off.
    nonisolated static func showsGuide(declined: String?, version: String, scripted: Bool, locked: Bool) -> Bool {
        (!scripted || locked) && declined != version
    }

    /// A scripted check with --locked acts as if Full Disk Access were off, to see what that looks like.
    static let actsLocked = ScriptRunner.path != nil && CommandLine.arguments.contains("--locked")

    /// Whether every folder may be read. Without Full Disk Access, the ones macOS guards are left alone, so no prompt ever
    /// comes up: Full Disk Access is the one thing Headroom asks for.
    static func mayReadEverything() -> Bool { !actsLocked && DiskScan.hasFullDiskAccess() }

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
