import AppKit
import SwiftUI

struct RootView: View {
    @State private var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GeometryReader { geometry in
            // The inspector has a column of its own, so all of this is the map's.
            let ring = RingGeometry.make(size: geometry.size)
            ZStack(alignment: .topLeading) {
                MapView(model: model)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                RingPlace(center: ring.center, radius: ring.radius, size: geometry.size, engine: model.engine, view: { [weak model] in model?.mapView })

                LabelsLayer(model: model, ring: ring)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)

                CenterIsland(model: model)
                    .frame(width: CenterIsland.diameter(in: ring), height: CenterIsland.diameter(in: ring))
                    .position(ring.center)
                    .allowsHitTesting(false)

                BottomArea(model: model, ring: ring)
                    .frame(width: ring.mapWidth, height: geometry.size.height, alignment: .bottom)

                AgentQuestion()

                // The folder's own icon beside the title, as a Finder window has: drag it to another app, or ⌘-click the
                // title for where it is. Not with names hidden, since that would show them.
                if let url = proxyURL {
                    Color.clear
                        .frame(width: 0, height: 0)
                        .navigationDocument(url)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .onChange(of: ring, initial: true) { _, new in model.setRing(new) }
        }
        // The map goes on under the toolbar, which has no background of its own over it.
        .ignoresSafeArea(.container, edges: .top)
        .background(Palette.window)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbarTitleMenu { TitleMenu(model: model) }
        .toolbar { MainToolbar(model: model) }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .searchable(text: $model.searchText, isPresented: $model.searchActive, placement: .toolbar, prompt: "Search")
        .onChange(of: model.searchText) { _, text in
            model.runSearch()
            // What's found is listed in the inspector.
            if !text.isEmpty { model.showPanel(true) }
        }
        // Done searching: the keyboard goes back to the map, so Esc and Space work on it again.
        .onChange(of: model.searchActive) { _, active in
            if !active { model.mapView?.window?.makeFirstResponder(model.mapView) }
        }
        .inspector(isPresented: Binding(get: { model.panelOpen }, set: { model.showPanel($0) })) {
            SidePanel(model: model)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { _, width in model.noteInspectorWidth(width) }
                // Last, or SwiftUI doesn't see it and the inspector is its own default 270 points wide, neither more nor less.
                .inspectorColumnWidth(min: 340, ideal: AppModel.savedInspectorWidth, max: 520)
                .toolbar {
                    // Just before the search field, whether the inspector is open or not, as in Apple's apps.
                    ToolbarItem(placement: .primaryAction) {
                        Button { model.showPanel(!model.panelOpen) } label: {
                            Label(model.panelOpen ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
                        }
                        .help(model.panelOpen ? "Hide Inspector" : "Show Inspector")
                    }
                }
        }
        // With Reduce Motion, nothing springs past where it's going, and everything is quick.
        .transaction { transaction in
            if transaction.animation != nil, Motion.isReduced { transaction.animation = .easeInOut(duration: 0.2) }
        }
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
        .alert("\(model.busyToSend?.title ?? "This") is in use", isPresented: Binding(get: { model.busyToSend != nil }, set: { if !$0 { model.busyToSend = nil } }), presenting: model.busyToSend) { busy in
            Button("Move to Trash Anyway", role: .destructive) { model.sendAnyway(busy) }
            Button("Cancel", role: .cancel) {}
        } message: { busy in
            Text(busy.why + " Undo works until the Trash is emptied.")
        }
        .onAppear { model.start() }
        // A new version found at launch brings its window forward, and so does a launch without Full Disk Access.
        .onChange(of: Updater.shared.windowRequests) { openWindow(id: "update") }
        .onChange(of: model.accessGuideRequests) { openWindow(id: "access") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.didBecomeActive()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            model.volumesChanged()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            model.volumesChanged()
        }
    }

    /// Where you are, as a Finder window says it: the folder you're in, or the disk itself.
    private var title: String {
        if model.focus == 0, let pair = model.pair, pair.tree === model.tree { return pair.realFolder == 0 ? (model.volume?.shownName ?? "Disk") : pair.folderName }
        guard model.focus != 0, model.tree != nil else { return model.volume?.shownName ?? "Headroom" }
        return model.displayName(model.focus)
    }

    /// Under the title: how far the scan has got, or how much is free, the same as in the middle of the ring and on the disk's
    /// capsule. Inside a folder, which disk it's on as well. With the drive's half beside it, which drive: the title already
    /// says which folder or disk, so this only finishes the sentence, short enough never to be cut.
    private var subtitle: String {
        if model.isScanning { return model.scanFiles > 0 ? "Scanning… \(formatCount(model.scanFiles)) files" : "Scanning…" }
        if !model.hasFullAccess, model.volume?.isBoot == true { return "Needs Full Disk Access" }
        if let pair = model.pair, pair.tree === model.tree { return "and \(pair.driveName)" }
        guard let free = model.shownFree else { return "" }
        if model.focus != 0 { return "\(model.volume?.shownName ?? "Disk")  ·  \(formatBytes(free)) free" }
        return "\(formatBytes(free)) free of \(formatBytes(model.shownCapacity))"
    }

    /// The real place on the disk the title stands for. Groups Headroom makes up, such as macOS's own parts, have none.
    private var proxyURL: URL? {
        guard !HiddenNames.isOn, let tree = model.tree, let volume = model.volume else { return nil }
        if model.focus == 0 { return URL(fileURLWithPath: model.pair.flatMap { $0.tree === tree ? $0.macPath : nil } ?? volume.mountPath) }
        return tree.path(model.focus).map { URL(fileURLWithPath: $0) }
    }
}

// MARK: Top

/// Back and forward at the start of the toolbar, the three views in the middle, and Scan Again at the end, before the search
/// field and the inspector's button. It can't be rearranged: on macOS 27 a toolbar that can be moves back and forward to the
/// other end and squeezes the inspector, and a small app built the same way stops at launch.
private struct MainToolbar: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!model.canGoBack)
                .help("Back")
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!model.canGoForward)
                .help("Forward")
        }
        // Two pickers with room between: the view, and the mode. One fixed spacer is the system's gap between groups, about 10
        // points, and the two capsules nearly touch; two make it about 18, and they read as two.
        ToolbarItem(placement: .principal) {
            LensPicker(model: model, lenses: Lens.views, name: "View")
        }
        ToolbarSpacer(.fixed, placement: .principal)
        ToolbarSpacer(.fixed, placement: .principal)
        ToolbarItem(placement: .principal) {
            LensPicker(model: model, lenses: Lens.actions, name: "Mode")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.scan(hurry: true) } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                .disabled(model.scanIsHurrying)
                .help("Rescan everything at full speed")
        }
    }
}

/// One of the toolbar's two pickers: the view (Map, Changes, Copies) or the mode (Free Up, Backup). Each always has one
/// chosen, and choosing in one leaves the other as it is.
struct LensPicker: View {
    let model: AppModel
    let lenses: [Lens]
    let name: String

    var body: some View {
        let isMode = lenses.first?.isAction == true
        Picker(name, selection: Binding<Lens>(get: { isMode ? model.mode : model.view }, set: { lens in
            Motion.animate(.spring(response: 0.34, dampingFraction: 0.82)) { isMode ? model.setMode(lens) : model.setView(lens) }
        })) {
            ForEach(lenses) { lens in
                // In Backup, Copies is Backed Up: what's on the drive and what isn't.
                let backedUp = lens == .copies && model.mode == .backup
                Text(backedUp ? "Backed Up" : lens.title)
                    .help(backedUp ? "Backed up or not" : lens.help)
                    .tag(lens)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// The title's menu: the folders the one you're in is inside, to go straight back to one. Disks are chosen at the bottom
/// left, in the drive row.
private struct TitleMenu: View {
    let model: AppModel

    var body: some View {
        if let tree = model.tree, model.focus != 0 {
            ForEach(tree.ancestors(of: model.focus).dropLast().reversed(), id: \.self) { node in
                Button {
                    model.go(to: node)
                } label: {
                    if node == 0 {
                        Label(model.volume?.shownName ?? "Disk", systemImage: model.volume?.isBoot == false ? "externaldrive" : "internaldrive")
                    } else {
                        Label(model.displayName(node), systemImage: "folder")
                    }
                }
            }
        }
    }
}

// MARK: Bottom

struct BottomArea: View {
    let model: AppModel
    let ring: RingGeometry

    var body: some View {
        VStack(spacing: 10) {
            AgentsConnected()
            if let message = model.message {
                MessageCard(model: model, message: message)
                    .transition(Motion.arrival(from: .bottom))
            }
            if let tip = model.tip {
                HStack(spacing: 12) {
                    Text(tip)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if model.tipOffersUndo {
                        Button("Undo") { model.undoCommand() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Kit.green)
                            .pointerStyle(.link)
                    }
                }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: Capsule())
                    .transition(.opacity)
            }
            if !model.hasFullAccess && !model.accessCardDismissed, model.volume?.isBoot == true {
                AccessCard(model: model)
                    .transition(Motion.arrival(from: .bottom))
            }
            DriveRow(model: model)
        }
        .padding(.bottom, 12)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.message)
        .animation(.easeOut(duration: 0.18), value: model.tip)
        .animation(.easeOut(duration: 0.18), value: Agents.shared.connected)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.focus)
    }
}

struct Breadcrumbs: View {
    let model: AppModel

    /// One way of writing the path: where you are, then the way to what's pointed at, with "…" where steps are left out.
    private struct Shape: Hashable {
        var chain: [UInt32]
        var chainFolded: Bool
        var ahead: [UInt32]
        var aheadFolded: Bool
    }

    var body: some View {
        if let tree = model.tree {
            let chain = tree.ancestors(of: model.focus)
            let ahead = ahead(tree)
            GeometryReader { geometry in
                // Where you are, in glass, folded to fit: it changes only when you go somewhere, so the glass never
                // changes size as the pointer moves.
                let here = fitChain(chain, room: geometry.size.width - 24)
                let hereWidth = width(of: Shape(chain: here.chain, chainFolded: here.folded, ahead: [], aheadFolded: false)) + 24
                // The way on to what's pointed at, faded, just after it: as much of it as fits, nearest what's pointed at.
                // It may run on past the bar's right edge, which is kept clear for Backup's drive.
                let spare: CGFloat = model.mode == .backup ? 0 : 150
                let trail = fitTrail(ahead, room: (geometry.size.width - hereWidth) / 2 - 8 + spare)
                CrumbChain(model: model, chain: here.chain, folded: here.folded).equatable()
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .glassEffect(.regular, in: Capsule())
                    .overlay(alignment: .trailing) {
                        trailView(trail.nodes, folded: trail.folded, last: trail.last)
                            .fixedSize()
                            .alignmentGuide(.trailing) { d in d[.leading] - 4 }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    private func trailView(_ nodes: [UInt32], folded: Bool, last: String) -> some View {
        HStack(spacing: 4) {
            if folded {
                Self.chevron(0.2)
                Self.ellipsis
            }
            // Each step marked in its colour on the ring.
            ForEach(nodes, id: \.self) { node in
                Self.chevron(0.2)
                HStack(spacing: 5) {
                    if let colour = colour(of: node) {
                        Circle().fill(colour).frame(width: 7, height: 7)
                    }
                    Text(node == nodes.last ? last : model.displayName(node))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 4)
                .frame(maxWidth: 220)
                .frame(height: DriveRow.height)
            }
        }
    }

    private func fitChain(_ chain: [UInt32], room: CGFloat) -> (chain: [UInt32], folded: Bool) {
        var ways: [(chain: [UInt32], folded: Bool)] = [(chain, false)]
        if chain.count > 3 { ways.append(([chain[0]] + chain.suffix(2), true)) }
        if chain.count > 2 { ways.append(([chain[0], chain[chain.count - 1]], true)) }
        return ways.first { width(of: Shape(chain: $0.chain, chainFolded: $0.folded, ahead: [], aheadFolded: false)) <= room } ?? ways[ways.count - 1]
    }

    /// As many of the steps as fit, nearest what's pointed at, with it written as briefly as it needs to be: a folder that
    /// says where it is is worth more than the end of its name.
    private func fitTrail(_ ahead: [UInt32], room: CGFloat) -> (nodes: [UInt32], folded: Bool, last: String) {
        guard let item = ahead.last else { return ([], false, "") }
        var names = [aheadName(item)]
        if let hover = model.hoverShown, hover.node == item, hover.titles.count > 2 { names += hover.titles.dropFirst(2) }
        // A step is at most 220 points wide; a name that would be cut at that is no way of writing it here.
        func width(_ name: String) -> CGFloat? {
            let w = Self.textWidth(name, bold: false) + 12
            return w <= 212 ? 11 + w + 8 : nil
        }
        for keep in stride(from: ahead.count, through: 1, by: -1) {
            let nodes = Array(ahead.suffix(keep))
            let folded = keep < ahead.count
            let above = nodes.dropLast().reduce(CGFloat(folded ? 23 : 0)) { $0 + (width(model.displayName($1)) ?? 239) }
            if let name = names.first(where: { width($0).map { above + $0 <= room } ?? false }) { return (nodes, folded, name) }
        }
        return ([item], ahead.count > 1, names.first { width($0) != nil } ?? names[names.count - 1])
    }

    /// How wide a way of writing the path is drawn, near enough to choose by.
    private func width(of shape: Shape) -> CGFloat {
        let gap: CGFloat = 4, chevron: CGFloat = 7, dots: CGFloat = 12
        var items: [CGFloat] = shape.chain.map { node in
            Self.textWidth(node == 0 ? (model.volume?.shownName ?? "Disk") : model.displayName(node), bold: node == model.focus) + 8
        }
        items += Array(repeating: chevron, count: max(shape.chain.count - 1, 0))
        if shape.chainFolded { items += [dots, chevron] }
        if shape.aheadFolded { items += [chevron, dots] }
        for node in shape.ahead {
            items += [chevron, min(Self.textWidth(aheadName(node), bold: false) + 12, 220) + 8]
        }
        return items.reduce(0, +) + gap * CGFloat(max(items.count - 1, 0)) + 8
    }

    private static var widths: [String: CGFloat] = [:]

    private static func textWidth(_ text: String, bold: Bool) -> CGFloat {
        let key = (bold ? "b" : "m") + text
        if let known = widths[key] { return known }
        if widths.count > 2000 { widths.removeAll() }
        let font = NSFont.systemFont(ofSize: 12, weight: bold ? .semibold : .medium)
        let w = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        widths[key] = w
        return w
    }

    fileprivate static func chevron(_ opacity: Double) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(opacity))
    }

    fileprivate static var ellipsis: some View {
        Text("…").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.45))
    }

    /// The folders between where you are and what's pointed at, and it, top down.
    private func ahead(_ tree: DiskTree) -> [UInt32] {
        guard let node = model.hoverShown?.node, node != model.focus, Int(node) < tree.count, !tree.isGhost(node) else { return [] }
        let all = tree.ancestors(of: node)
        guard let here = all.firstIndex(of: model.focus) else { return [] }
        return Array(all[(here + 1)...])
    }

    /// What's pointed at is written as its neighbours tell it apart, as the folders before it say where it is.
    private func aheadName(_ node: UInt32) -> String {
        if let hover = model.hoverShown, hover.node == node, hover.titles.count > 1 { return hover.titles[1] }
        return model.displayName(node)
    }

    /// A piece's colour as it's drawn now, for its dot.
    private func colour(of node: UInt32) -> Color? {
        let layout = model.engine.layout
        guard let i = layout.piece(of: node), i < layout.pieces.count else { return nil }
        let c = layout.pieces[i].color
        func encode(_ v: Float) -> Double {
            let x = min(max(Double(v), 0), 1)
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return Color(.displayP3, red: encode(c.x), green: encode(c.y), blue: encode(c.z))
    }
}

/// Where you are: a button for each folder from the disk down, made again only when that changes, not as the pointer moves.
private struct CrumbChain: View, Equatable {
    let model: AppModel
    let chain: [UInt32]
    let folded: Bool

    static func == (a: Self, b: Self) -> Bool { a.chain == b.chain && a.folded == b.folded }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(chain.enumerated()), id: \.element) { index, node in
                if index > 0 { Breadcrumbs.chevron(0.35) }
                if index == 1 && folded {
                    Breadcrumbs.ellipsis
                    Breadcrumbs.chevron(0.35)
                }
                Button {
                    // You're already here, so a click on this one copies its name.
                    if node == model.focus { model.copyName(of: NamedThing(node)) } else { model.go(to: node) }
                } label: {
                    Text(node == 0 ? (model.volume?.shownName ?? "Disk") : model.displayName(node))
                        .font(.system(size: 12, weight: node == model.focus ? .semibold : .medium))
                        .foregroundStyle(.white.opacity(node == model.focus ? 0.95 : 0.6))
                        .lineLimit(1)
                        .padding(.horizontal, 4)
                        .frame(height: DriveRow.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .named(NamedThing(node), in: model)
                .help(node == model.focus ? "Click to copy the name" : "⌘-click to copy the name")
            }
        }
    }
}

struct MessageCard: View {
    let model: AppModel
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
            Button {
                model.message = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
    }
}

/// Explains the hatched piece: Headroom reads nothing until macOS lets it read everything.
struct AccessCard: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text("Needs Full Disk Access")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
            Button("Allow…") { openWindow(id: "access") }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .help("Show how to allow access")
            Button {
                model.accessCardDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("Not now")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
