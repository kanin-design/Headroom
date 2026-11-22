import AppKit
import SwiftUI

/// Which pieces of the ring are named, and what they're called, in each view. SunburstKit finds where the names fit.
@MainActor
struct HeadroomNames: SunburstNamer {
    /// Something to name at the side, by what it names: its piece is found in each picture as it's drawn.
    struct Named {
        var nodes: [UInt32]
        var title: String
        var value: String
    }

    let model: AppModel
    /// Just these at the sides: what you're pointing at in the panel.
    var only: [Named]?

    /// Which view's names: the one on screen, or Free Up's for what's pointed at in its list.
    private var lens: Lens { only == nil ? model.labelLens : .freeUp }

    /// Inside the pieces, biggest first. Only in the Map view: elsewhere most of the ring is dimmed on purpose. In Free Up,
    /// only free space.
    func inside(_ p: Piece) -> (title: String, value: String)? {
        let lens = lens
        guard lens == .map || lens == .freeUp || lens == .backup, let tree = model.tree else { return nil }
        if lens == .freeUp && p.role != .room { return nil }
        // The top of a chain is what you'd call it. The whole chain shows when you point at it.
        return (p.role == .room ? "Free" : model.displayName(p.node), tree.sizeText(p.node))
    }

    /// Out at the sides: what's big but can't hold its own name, or what this view's lists point at.
    func sides(_ layout: RingLayout, order ranked: [Int], named: inout LabelPlacer.Placed) -> [LabelPlacer.Pick] {
        guard let tree = model.tree else { return [] }
        typealias Candidate = LabelPlacer.Pick
        if let only {
            var picks: [Candidate] = []
            for one in only {
                guard let at = layout.bestPiece(for: one.nodes, in: tree), !picks.contains(where: { $0.index == at }) else { continue }
                picks.append(Candidate(index: at, title: one.title, value: one.value, score: Double(layout.pieces[at].size)))
            }
            return picks
        }
        var candidates: [Candidate] = []
        switch lens {
        case .map, .backup:
            candidates = LabelPlacer.bigPieces(layout: layout, order: ranked, named: &named) { p in
                (model.displayName(p.node), tree.sizeText(p.node))
            }
        case .changes:
            for row in model.changeRows.prefix(18) {
                if let i = layout.nearestPiece(to: row.node, tree: tree), !candidates.contains(where: { $0.index == i }) {
                    // What grew has a plus. What's gone untouched is just how much.
                    let sign = model.changeWindow.isUntouched ? "" : "+"
                    candidates.append(Candidate(index: i, title: row.title, value: sign + formatBytes(UInt64(max(row.delta, 0))), score: Double(row.delta)))
                }
            }
        case .copies:
            if let id = model.pointedCopyGroup, let group = model.copyGroupsHere.first(where: { $0.id == id }) {
                // Pointing at a set: where each of its copies is, and which one stays, as pointing at a box names its things. A row
                // of many files in the same folders names the folders.
                let byFolder = group.files > 1 || (group.kind != .duplicate && group.keepers.count > 1)
                let nodes = byFolder ? (group.homes.isEmpty ? [group.home] : group.homes) + group.others : (group.kind == .duplicate ? group.keepers + group.extras : group.nodes)
                let parents = nodes.map { tree.nodes[Int($0)].parent }
                let shown = Array(nodes.prefix(10))
                // Where each one is, said so that no two read the same.
                let places = CopiesMap.places(shown.map { tree.nodes[Int($0)].has(NodeFlag.directory) ? $0 : tree.nodes[Int($0)].parent }, in: tree, short: true)
                for (at, node) in shown.enumerated() where node != 0 {
                    // Copies too small to show apart, or side by side, can share a piece of the ring: each still gets its own name.
                    guard let i = layout.nearestPiece(to: node, tree: tree) else { continue }
                    let n = tree.nodes[Int(node)]
                    let isFolder = n.has(NodeFlag.directory)
                    // Copies side by side in one folder are named by their own names, which is what tells them apart; the others
                    // by where they are, which a folder's name alone wouldn't say.
                    let beside = !isFolder && parents.filter { $0 == n.parent }.count > 1
                    let title = beside ? model.displayName(node) : places[at]
                    let stays = node == group.home || group.homes.contains(node) || group.keepers.contains(node)
                    let bytes = byFolder ? group.extras.filter { tree.nodes[Int($0)].parent == node }.reduce(UInt64(0)) { $0 &+ tree.nodes[Int($1)].bytes } : n.bytes
                    let value = switch group.kind {
                    case .duplicate: stays ? "keep" : formatBytes(bytes)
                    case .sameFile: "hardlink"
                    case .sharedCopy: "clone"
                    case .alias, .broken: stays ? "target" : "symlink"
                    }
                    candidates.append(Candidate(index: i, title: title, value: value, score: Double(bytes) + (stays ? 1e15 : 0),
                                                salt: UInt64(node) &* 0x9E37_79B9_7F4A_7C15))
                }
            } else {
                // The biggest sets, named at the copy to keep. Hardlinks, clones and symlinks take no extra space, so they're
                // named when you point at them.
                for group in model.copyGroupsHere.prefix(24) where group.kind == .duplicate {
                    if let i = layout.nearestPiece(to: group.home, tree: tree), !candidates.contains(where: { $0.index == i }) {
                        candidates.append(Candidate(index: i, title: group.title, value: formatBytes(group.back), score: Double(group.back)))
                    }
                }
            }
        case .freeUp:
            // Things spread over many places are lit up from the panel. A line to just one of them would mislead.
            let bar = Double(max(tree.capacityBytes, 1)) * 0.002
            // What's in use lately is folded away in the list, so it doesn't take up a name here unless it's planned.
            for row in model.shownRows.sorted(by: { $0.gain > $1.gain }).prefix(40) where row.action != .restart && row.action != .softwareUpdate && row.nodes.count <= 3 && Double(row.gain) >= bar
                && !(row.inUse != nil && row.tier <= .rebuilds && model.rowStates[row.id] == TickState.none) {
                let biggest = row.nodes.max { tree.totals[Int($0)] < tree.totals[Int($1)] }
                if let biggest, let i = layout.nearestPiece(to: biggest, tree: tree), !candidates.contains(where: { $0.index == i }) {
                    candidates.append(Candidate(index: i, title: row.title, value: formatBytes(row.gain), score: Double(row.gain)))
                }
            }
            // What's been moved is on its way out through here.
            if let after = model.afterClean, after.state == .waiting, let trash = model.trashNode(in: tree), let i = layout.nearestPiece(to: trash, tree: tree) {
                candidates.removeAll { $0.index == i }
                candidates.insert(Candidate(index: i, title: "In the Trash", value: tree.sizeText(trash), score: .greatestFiniteMagnitude), at: 0)
            }
        }
        return candidates
    }

    /// A name just outside a piece that's already named would say nearly the same thing. Not a copy's: each is a place of
    /// its own, however near the others it is.
    var leavesOutRepeats: Bool { !(lens == .copies && model.pointedCopyGroup != nil) }

}

/// The names around the ring, from the chart, each at the side with the menu of what it names.
struct LabelsLayer: View {
    let model: AppModel
    /// Where the ring is, as the ring itself is told: the names follow it while it moves.
    let ring: RingGeometry

    var body: some View {
        SunburstChartLabels(model.chart, width: ring.mapWidth, ring: RingPlacement(center: ring.center, radius: ring.radius)) {
            NamedLabel(model: model, node: $0.node)
        }
    }
}

/// A name at the side is the thing it names: its menu, and what agents and ⌘C see.
private struct NamedLabel: ViewModifier {
    let model: AppModel
    let node: UInt32

    func body(content: Content) -> some View { content.named(NamedThing(node), in: model) }
}

/// The middle of the ring, in a view tree of its own. What it says changes with the pointer, many times a second, and a
/// change anywhere in the window's own tree has SwiftUI go over the whole window (about 3.5 ms on this window, measured);
/// here it goes over these few lines. The window places it; the pointer goes straight through it.
struct CenterIsland: NSViewRepresentable {
    let model: AppModel

    /// The room the middle has in a ring of this radius.
    static func diameter(in ring: RingGeometry) -> CGFloat { ring.radius * CGFloat(RingLayout.hole) * 2 * 0.86 }

    func makeNSView(context: Context) -> NSView {
        Island(CenterReadout(model: model))
    }

    func updateNSView(_ view: NSView, context: Context) {}

    /// The window says how big the middle is; what it shows never does.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// A view tree of its own inside the window's: a plain view holding a hosting view that fills it. The plain view is what
/// the window's tree sees, so nothing that changes inside (not even the hosting view saying its size might have) reaches
/// the window's layout. The pointer goes straight through to what's under it.
final class Island: NSView {
    private let passesThrough: Bool

    /// `passesThrough` false for one with controls of its own, such as the path bar.
    init(_ content: some View, passesThrough: Bool = true) {
        self.passesThrough = passesThrough
        super.init(frame: .zero)
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { passesThrough ? nil : super.hitTest(point) }
}

/// The middle of the ring: the one number that matters, until you point at something else. It fills the room it's given.
struct CenterReadout: View {
    let model: AppModel

    var body: some View {
        GeometryReader { geometry in
            content(size: min(geometry.size.width, geometry.size.height))
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func content(size: CGFloat) -> some View {
        Group {
            if let hover = model.hoverShown {
                hoverContent(hover, size: size)
            } else if model.focus == 0, let pair = model.pair, pair.tree === model.tree {
                pairContent(pair, size: size)
            } else if model.focus != 0, let tree = model.tree {
                folderContent(tree, size: size)
            } else if model.view == .changes, model.changeUsesHistory || model.changeTotal > 0 {
                changesContent(size: size)
            } else if model.view == .copies, model.mode == .freeUp, model.copies != nil {
                copiesContent(size: size)
            } else {
                diskContent(size: size)
            }
        }
        .frame(width: size, height: size)
        .multilineTextAlignment(.center)
    }

    /// Every state puts its parts in the same places (`CentreGrid`), so nothing moves with the pointer or with what's
    /// written: the icon, the name's room, the number and the lines under it are each placed on their own.
    private func slots<Above: View, Below: View>(_ size: CGFloat, icon: CentreIcon? = nil, number: some View,
                                                 @ViewBuilder above: () -> Above, @ViewBuilder below: () -> Below) -> some View {
        let g = CentreGrid(u: size), mid = size / 2
        return ZStack {
            if let icon {
                CentreIconView(icon: icon, size: g.icon)
                    .position(x: mid, y: mid + g.iconY)
            }
            // The name sits on the number, as the lines under it hang from it: one line just above it, a second above that.
            above()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: g.width, height: g.titleHeight, alignment: .bottom)
                .position(x: mid, y: mid + g.titleY)
            number
                .frame(height: g.numberHeight)
                .position(x: mid, y: mid)
            below()
                .frame(width: g.width, height: g.belowHeight, alignment: .top)
                .position(x: mid, y: mid + g.belowTop + g.belowHeight / 2)
        }
        .frame(width: size, height: size)
    }

    /// `about` is the thing the number is about: its digits roll when that thing changes size, and just change when the
    /// number is about something else.
    private func bigNumber(_ bytes: UInt64, size: CGFloat, color: Color = .white, sign: String = "", about: AnyHashable) -> some View {
        // Changes has a sign in front, so its number keeps room for one whatever it shows.
        SunburstNumber(sign + formatBytes(bytes), size: bytes, diameter: size, color: color,
                       widest: model.view == .changes ? "−8.88 MB" : "8.88 MB", about: about)
    }

    /// Free space is on screen from the first frame, because the disk itself reports it.
    @ViewBuilder
    private func diskContent(size: CGFloat) -> some View {
        // Nothing until the disk is known, so the first frame doesn't roll up from zero.
        if let free = model.shownFree {
            let capacity = model.shownCapacity
            let planning = model.planNumbers.total >= 1_000_000 && model.mode == .freeUp
            let preview = free &+ model.planNumbers.total
            let usedShare = 1 - Double(free) / Double(max(capacity, 1))
            slots(size, icon: model.centreIcon(0), number: bigNumber(planning ? preview : free, size: size, color: planning ? Kit.green : .white, about: "free")) {
                // The disk's name, as a folder's is once you're in it: every state is an icon, a name, a number and a line.
                Text(model.volume?.shownName ?? "")
                    .font(.system(size: CentreGrid(u: size).title, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            } below: {
                VStack(spacing: CentreGrid(u: size).lineGap) {
                    Text(planning ? "free after cleaning" : "free of \(formatBytes(capacity))")
                        .font(.system(size: CentreGrid(u: size).detail, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    if let pointing = model.pointing, model.mode == .freeUp {
                        pointingLine(pointing, size: size)
                    } else if planning {
                        Text("+\(formatBytes(model.planNumbers.total))")
                            .font(.system(size: CentreGrid(u: size).caption, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Kit.green.opacity(0.8))
                    } else if let delta = sinceLast(free) {
                        deltaCapsule(delta, size: size)
                    } else {
                        Text(String(format: "%.0f%% full", usedShare * 100))
                            .font(.system(size: CentreGrid(u: size).caption, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.36))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
    }

    /// With the drive beside it, the middle says what the folder holds on the Mac, and on the drive under it.
    private func pairContent(_ pair: PairPicture, size: CGFloat) -> some View {
        // With something selected, the middle says how much, as Free Up says what cleaning frees.
        let picked = model.backup.items.count + model.driveSelection.count
        let pickedBytes = model.backupBytes &+ model.driveSelection.reduce(UInt64(0)) { $0 &+ $1.bytes }
        let blue = Kit.blue
        return slots(size, number: bigNumber(picked > 0 ? pickedBytes : pair.macBytes, size: size, color: picked > 0 ? blue : .white,
                                             about: picked > 0 ? "picked" : "on this Mac")) {
            Text(pair.realFolder == 0 ? (model.volume?.shownName ?? "") : pair.folderName)
                .font(.system(size: CentreGrid(u: size).title, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        } below: {
            VStack(spacing: CentreGrid(u: size).lineGap) {
                Text(picked > 0 ? "\(picked) selected" : "on this Mac")
                    .font(.system(size: CentreGrid(u: size).detail, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text(picked > 0 ? "\(formatBytes(pair.macBytes)) on this Mac" : "\(formatBytes(pair.driveBytes)) on \(pair.driveName)")
                    .font(.system(size: CentreGrid(u: size).caption, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.36))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    /// In Changes the middle says how much free space changed, from the scan it compares with, or else how much was
    /// touched, going by file dates.
    private func changeColour(shrank: Bool) -> Color {
        if model.changeWindow.isUntouched { return Palette.untouched.swiftUI }
        return shrank ? Palette.cool.swiftUI : Palette.grew.swiftUI
    }

    /// In Copies the middle says how much the duplicates take, in white as free space is. Pointing at a set in the inspector says
    /// that set's, in its colour, as Free Up does for a box.
    private func copiesContent(size: CGFloat) -> some View {
        let groups = model.copyGroupsHere
        let hot = model.pointedCopyGroup.flatMap { id in groups.first { $0.id == id } }
        let back = hot.map { $0.kind == .duplicate ? $0.back : $0.size } ?? groups.reduce(UInt64(0)) { $0 &+ $1.back }
        let colour = hot?.colour.swiftUI ?? .white
        return slots(size, number: bigNumber(back, size: size, color: colour, about: hot?.id ?? "duplicates")) {
            EmptyView()
        } below: {
            VStack(spacing: CentreGrid(u: size).lineGap) {
                Text(hot.map(\.title) ?? (model.copiesReading ? "in duplicates so far" : "in duplicates"))
                    .font(.system(size: CentreGrid(u: size).detail, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                if let hot {
                    let outside = model.copiesOutside(hot)
                    Text(outside > 0 ? "+\(outside) outside this folder" : hot.kind == .duplicate ? "reclaimable" : "no extra space")
                        .font(.system(size: CentreGrid(u: size).caption, weight: .medium))
                        .foregroundStyle(colour.opacity(0.8))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    private func changesContent(size: CGFloat) -> some View {
        let window = model.changeWindow
        let when = window == .lastScan ? "since the last scan" : "in the last \(window.title)"
        let history = model.changeUsesHistory
        // `changeTotal` counts down from free space when comparing with history, and up from what was touched otherwise.
        let change = history ? -model.changeTotal : model.changeTotal
        let colour = history ? (change < 0 ? Palette.grew.swiftUI : (change > 0 ? Palette.cool.swiftUI : .white)) : .white
        let sign = history ? (change < 0 ? "−" : (change > 0 ? "+" : "")) : ""
        return slots(size, number: bigNumber(UInt64(abs(change)), size: size, color: colour, sign: sign, about: "changed")) {
            EmptyView()
        } below: {
            VStack(spacing: CentreGrid(u: size).lineGap) {
                Text(window.isUntouched ? "untouched \(window.span)" : history ? "free space \(when)" : "modified \(when)")
                    .font(.system(size: CentreGrid(u: size).detail, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                if !history {
                    Text("by date modified")
                        .font(.system(size: CentreGrid(u: size).caption, weight: .medium))
                        .foregroundStyle(.white.opacity(0.36))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    /// What you're pointing at in the panel, in its own colour.
    private func pointingLine(_ pointing: Pointing, size: CGFloat) -> some View {
        Text("\(pointing.title): \(formatBytes(pointing.bytes))")
            .font(.system(size: CentreGrid(u: size).caption, weight: .semibold).monospacedDigit())
            .foregroundStyle(pointing.color.swiftUI)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// How much free space has changed since a day or so ago, once there's a history to compare with.
    private func sinceLast(_ free: UInt64) -> (delta: Int64, label: String)? {
        guard model.history.count >= 2 else { return nil }
        let now = Date()
        let day: TimeInterval = 86_400
        let older = model.history.dropLast().last { now.timeIntervalSince($0.date) >= day * 0.6 }
        guard let older else { return nil }
        let delta = Int64(bitPattern: free) - Int64(bitPattern: older.free)
        guard abs(delta) >= 500_000_000 else { return nil }
        let hours = now.timeIntervalSince(older.date) / 3600
        let label = hours < 36 ? "since yesterday" : (hours < 24 * 9 ? "in \(Int(hours / 24)) days" : "in \(Int(hours / 24 / 7)) weeks")
        return (delta, label)
    }

    private func deltaCapsule(_ info: (delta: Int64, label: String), size: CGFloat) -> some View {
        let down = info.delta < 0
        return HStack(spacing: 3) {
            Image(systemName: down ? "arrow.down" : "arrow.up")
                .font(.system(size: CentreGrid(u: size).caption * 0.84, weight: .bold))
            Text("\(formatBytes(UInt64(abs(info.delta)))) \(info.label)")
                .font(.system(size: CentreGrid(u: size).caption, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(down ? Color(red: 1, green: 0.58, blue: 0.48) : Kit.green)
    }

    private func folderContent(_ tree: DiskTree, size: CGFloat) -> some View {
        let moved = tree.movedBytes(inside: model.focus)
        return slots(size, icon: model.centreIcon(model.focus), number: bigNumber(tree.bytesHere(model.focus), size: size, about: model.focus)) {
            HStack(spacing: 2) {
                Image(systemName: "chevron.left")
                    .font(.system(size: CentreGrid(u: size).caption, weight: .bold))
                    .foregroundStyle(.white.opacity(0.42))
                Text(model.displayName(model.focus))
                    .font(.system(size: CentreGrid(u: size).title, weight: .semibold))
                    .truncationMode(.middle)
            }
            .foregroundStyle(.white.opacity(0.92))
        } below: {
            VStack(spacing: CentreGrid(u: size).lineGap) {
                Text(tree.isStillGrowing(model.focus) ? "so far" : side(tree) ?? shareOfDisk(tree))
                    .font(.system(size: CentreGrid(u: size).detail, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                if moved > 0 {
                    Text("+ \(formatBytes(moved)) moved")
                        .font(.system(size: CentreGrid(u: size).caption, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.36))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    /// On one side of both disks, which side: the picture is of two disks, so it has no share of one.
    private func side(_ tree: DiskTree) -> String? {
        guard let pair = model.pair, pair.tree === tree else { return nil }
        return pair.isOnDrive(model.focus) ? "on \(pair.driveName)" : "on this Mac"
    }

    private func shareOfDisk(_ tree: DiskTree) -> String {
        let percent = Double(tree.bytesHere(model.focus)) / Double(max(tree.capacityBytes, 1)) * 100
        return (percent >= 10 ? String(format: "%.0f%%", percent) : String(format: "%.1f%%", percent)) + " of the disk"
    }

    private func hoverContent(_ hover: HoverInfo, size: CGFloat) -> some View {
        slots(size, icon: hover.icon, number: bigNumber(hover.bytes, size: size, about: [AnyHashable(hover.node), AnyHashable(hover.title)])) {
            Group {
                // The real name: on one line if it fits, else on two smaller ones; only then cut where it's like its
                // neighbours, each way of writing it on one line, then on two, so as much of the name stays as fits.
                let titles = hover.titles.isEmpty ? [hover.title] : hover.titles
                ViewThatFits(in: .horizontal) {
                    ForEach(titles, id: \.self) { title in
                        Text(title).fixedSize()
                        // Two lines hold about 48 characters here; a longer one is cut further instead.
                        if title.count <= 48 {
                            Text(title)
                                .font(.system(size: CentreGrid(u: size).twoLineTitle, weight: .semibold))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: CentreGrid(u: size).twoLineWidth)
                        }
                    }
                    Text(titles.last ?? hover.title).truncationMode(.middle)
                }
                .font(.system(size: CentreGrid(u: size).title, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
            }
        } below: {
            hoverLine(hover, size: size)
        }
    }

    /// The line under the size: its other paths, what changed, when it was last used, or its share.
    @ViewBuilder
    private func hoverLine(_ hover: HoverInfo, size: CGFloat) -> some View {
        Group {
            if let links = hover.links {
                Text(links)
                    .font(.system(size: CentreGrid(u: size).status, weight: .semibold))
                    .foregroundStyle(Kit.amber)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.middle)
            } else if !hover.note.isEmpty {
                // In Changes the line says what changed, in the view's own colours. When it says when something was last
                // used, it looks as it does on the map.
                let saysChange = model.view == .changes && !hover.tellsUse
                Text(hover.note)
                    .font(.system(size: CentreGrid(u: size).status, weight: saysChange ? .semibold : .medium))
                    .foregroundStyle(saysChange ? changeColour(shrank: hover.shrank) : .white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else if !hover.share.isEmpty {
                Text(hover.share)
                    .font(.system(size: CentreGrid(u: size).status, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.middle)
            }
        }
    }
}

/// Where everything in the middle of the ring goes, worked out from its size `u`: the side of the square it's drawn in,
/// 0.86 of the hole across, about 176 points in a 1400-point window. Every state uses the same places, so nothing moves
/// with the pointer or with what's written.
///
/// Text comes in three sizes a step of ×1.2 apart: the name, what's said about the number, and a quieter third line. The
/// number is more than three times the name, so there are two clear levels: the number, and what's said about it.
///
/// Down the middle, as offsets from the ring's middle: an icon, always in the same place; the name's room, two lines
/// high, with the name at its foot, so a name of one line sits as close above the number as the line under it hangs
/// below (0.035 u, about 7 points, between the digits and each); the number, its digits centred on the ring's middle;
/// and room for two lines under it. A second line of a name grows up toward the icon, which stays where it is.
/// Everything is inside the hole with room to spare: where the icon is, the hole is still 0.95 u across.
struct CentreGrid {
    let u: CGFloat

    // Sizes.
    var title: CGFloat { u * 0.072 }
    /// The line under the number while something is pointed at (when it was last used, its other paths, what changed): as
    /// large as the name, as decided on 2026-11-06.
    var status: CGFloat { title }
    var detail: CGFloat { u * 0.060 }
    var caption: CGFloat { u * 0.050 }
    /// A name on two lines, a step smaller so both fit the room.
    var twoLineTitle: CGFloat { u * 0.062 }
    var icon: CGFloat { detail }

    // Widths.
    var width: CGFloat { u * 0.86 }
    var twoLineWidth: CGFloat { u * 0.78 }

    // Places, as offsets of each part's middle from the ring's middle, down positive.
    // The digits' capitals reach 0.082 u either side of the middle; 0.035 u clear of them sit the name's foot above and the
    // first line's capitals below.
    var iconY: CGFloat { -u * 0.31 }
    /// The name's room runs from 0.249 u above the middle down to 0.100 u above it, where a line's foot sits 0.035 u clear of
    /// the digits.
    var titleY: CGFloat { -u * 0.1745 }
    var titleHeight: CGFloat { u * 0.149 }
    var numberHeight: CGFloat { u * 0.28 }
    /// Where the lines under the number start, so the first one's capitals are 0.035 u under the digits, and how much room
    /// they have.
    var belowTop: CGFloat { u * 0.103 }
    var belowHeight: CGFloat { u * 0.2 }
    var lineGap: CGFloat { detail * 0.25 }
}
