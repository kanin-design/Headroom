import AppKit
import SwiftUI

/// One step of the path: a folder's name, and where a click on it goes.
struct PathStep: Hashable {
    enum Go: Hashable {
        /// A folder on the ring.
        case node(UInt32)
        /// Both disks again, at this folder in the map.
        case bothDisks(UInt32)
        /// Nowhere: it only says where you are.
        case nowhere
    }

    var name: String
    var go: Go
    /// A symbol before the name: the drive's, on the drive's half.
    var symbol: String?
    /// Never folded into "…": the drive's step, which says the rest is on the drive.
    var stays = false
}

extension PathStep {
    /// Where you are, as the path bar writes it right after the disk selector: the folders down to the one you're in, the
    /// last step, without the disk the selector names. In Backup, the drive's half starts with the drive, and both disks at
    /// a folder are that folder's path, the same on both. DESIGN.md, *The path bar*. `bare` is the map both disks are drawn
    /// from.
    static func steps(tree: DiskTree, focus: UInt32, pair: PairPicture?, bare: DiskTree?, name: (UInt32) -> String) -> [PathStep] {
        let chain = tree.ancestors(of: focus)
        guard let pair, pair.tree === tree else {
            return chain.dropFirst().map { PathStep(name: name($0), go: .node($0)) }
        }
        // The folder both halves are of, from the disk down: the same path on both.
        var real: [PathStep] = []
        if pair.realFolder != 0, let bare, Int(pair.realFolder) < bare.count {
            real = bare.ancestors(of: pair.realFolder).dropFirst().map { PathStep(name: bare.name($0), go: .bothDisks($0)) }
        }
        // In one half, its folder stands for that folder on its own disk.
        func half(_ side: UInt32) -> [PathStep] {
            var steps = real
            if !steps.isEmpty { steps[steps.count - 1].go = .node(side) }
            guard let at = chain.firstIndex(of: side) else { return steps }
            return steps + chain[(at + 1)...].map { PathStep(name: name($0), go: .node($0)) }
        }
        if focus == 0 { return real }
        if pair.isOnDrive(focus) {
            let drive = PathStep(name: pair.driveName, go: real.isEmpty ? .node(pair.driveSide) : .nowhere, symbol: "externaldrive", stays: true)
            return [drive] + half(pair.driveSide)
        }
        if chain.contains(pair.macSide) { return half(pair.macSide) }
        return chain.dropFirst().map { PathStep(name: name($0), go: .node($0)) }
    }
}

extension AppModel {
    /// Where you are, as the path bar writes it: see `PathStep.steps`.
    var pathSteps: [PathStep] {
        guard let tree else { return [] }
        return PathStep.steps(tree: tree, focus: focus, pair: pair, bare: bareTree, name: displayName)
    }
}

/// The path bar in a view tree of its own, like the middle of the ring: it follows the pointer, and a change in the
/// window's own tree has SwiftUI go over the whole window.
struct PathIsland: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSView { Island(PathBar(model: model), passesThrough: false) }

    func updateNSView(_ view: NSView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// Plain text after the disk selector, the same at rest and while pointing. On the whole disk there's no path, until
/// something is pointed at: then the way to it fades in, rather than the bar being made again each time the pointer
/// crosses a gap.
private struct PathBar: View {
    let model: AppModel

    var body: some View {
        let steps = model.pathSteps
        let shown = !steps.isEmpty || model.hoverShown != nil
        Breadcrumbs(model: model, steps: steps)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .animation(.easeOut(duration: 0.15), value: shown)
    }
}

struct Breadcrumbs: View {
    let model: AppModel
    let steps: [PathStep]

    /// Room kept for the way to what's pointed at, so where you are never refolds as the pointer moves: enough for one
    /// step with a short name.
    private static let trailRoom: CGFloat = 160

    var body: some View {
        if let tree = model.tree {
            let ahead = ahead(tree)
            GeometryReader { geometry in
                let room = geometry.size.width
                // Where you are, folded to fit: it changes only when you go somewhere.
                let here = fitSteps(room: room - min(Self.trailRoom, room * 0.4))
                // The way on to what's pointed at, in the same line: as much of it as fits, nearest what's pointed at.
                let trail = fitTrail(ahead, room: room - here.width)
                // With no steps of its own, the way on starts where the first step would, so nothing shifts.
                HStack(spacing: 4) {
                    if !here.steps.isEmpty {
                        CrumbChain(model: model, steps: here.steps, foldedAt: here.folded ? here.at : nil).equatable()
                    }
                    trailView(trail.nodes, folded: trail.folded, last: trail.last)
                }
                .fixedSize()
                .frame(width: room, height: geometry.size.height, alignment: .leading)
            }
        }
    }

    private func trailView(_ nodes: [UInt32], folded: Bool, last: String) -> some View {
        HStack(spacing: 4) {
            if folded {
                Self.chevron(0.2)
                Self.ellipsis(0.45)
            }
            // Each step marked in its colour on the ring.
            ForEach(nodes, id: \.self) { node in
                Self.chevron(0.2)
                HStack(spacing: 5) {
                    if let colour = colour(of: node) {
                        Circle().fill(colour).frame(width: 7, height: 7)
                    }
                    Text(node == nodes.last ? last : aheadName(node))
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

    /// As many of the steps as fit, nearest where you are, with "…" for the ones nearer the top. A step that says which
    /// disk the rest is on stays.
    private func fitSteps(room: CGFloat) -> (steps: [PathStep], folded: Bool, at: Int, width: CGFloat) {
        let head = Array(steps.prefix { $0.stays })
        let rest = Array(steps.dropFirst(head.count))
        func width(_ kept: [PathStep], folded: Bool) -> CGFloat {
            kept.reduce(folded ? Self.item(12) : 0) { total, step in
                total + Self.item(min(Self.textWidth(step.name, bold: step == steps.last) + (step.symbol == nil ? 0 : 16), 212) + 8)
            }
        }
        for keep in stride(from: rest.count, through: min(rest.count, 1), by: -1) {
            let kept = head + rest.suffix(keep), folded = keep < rest.count
            let w = width(kept, folded: folded)
            if w <= room { return (kept, folded, head.count, w) }
        }
        let kept = head + rest.suffix(1), folded = rest.count > 1
        return (kept, folded, head.count, width(kept, folded: folded))
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
            return w <= 212 ? Self.item(w + 8) : nil
        }
        for keep in stride(from: ahead.count, through: 1, by: -1) {
            let nodes = Array(ahead.suffix(keep))
            let folded = keep < ahead.count
            let above = nodes.dropLast().reduce(folded ? Self.item(12) : 0) { $0 + (width(aheadName($1)) ?? Self.item(220)) }
            if let name = names.first(where: { width($0).map { above + $0 <= room } ?? false }) { return (nodes, folded, name) }
        }
        return ([item], ahead.count > 1, names.first { width($0) != nil } ?? names[names.count - 1])
    }

    /// How much room a step takes in the line: the chevron before it, the gaps, and its own width.
    private static func item(_ width: CGFloat) -> CGFloat { 4 + 7 + 4 + width }

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

    fileprivate static func ellipsis(_ opacity: Double) -> some View {
        Text("…").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(opacity))
    }

    /// The folders between where you are and what's pointed at, and it, top down.
    private func ahead(_ tree: DiskTree) -> [UInt32] {
        guard let node = model.hoverShown?.node, node != model.focus, Int(node) < tree.count, !tree.isGhost(node) else { return [] }
        let all = tree.ancestors(of: node)
        guard let here = all.firstIndex(of: model.focus) else { return [] }
        var steps = Array(all[(here + 1)...])
        // Into the Mac's half from both disks: the disk selector names its disk, so the way starts after it.
        if let pair = model.pair, pair.tree === tree, steps.first == pair.macSide, steps.count > 1 { steps.removeFirst() }
        return steps
    }

    /// What's pointed at is written as its neighbours tell it apart, as the folders before it say where it is. From both
    /// disks, the Mac's half alone is named by its disk, as the selector names it.
    private func aheadName(_ node: UInt32) -> String {
        if let hover = model.hoverShown, hover.node == node, hover.titles.count > 1 { return hover.titles[1] }
        if let pair = model.pair, pair.tree === model.tree, node == pair.macSide { return model.volume?.shownName ?? "This Mac" }
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

/// Where you are: a step for each folder, made again only when that changes, not as the pointer moves.
private struct CrumbChain: View, Equatable {
    let model: AppModel
    let steps: [PathStep]
    /// Where "…" stands for the steps left out, if any are.
    let foldedAt: Int?
    @State private var pointed: Int?

    static func == (a: Self, b: Self) -> Bool { a.steps == b.steps && a.foldedAt == b.foldedAt }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index == foldedAt {
                    Breadcrumbs.chevron(0.25)
                    Breadcrumbs.ellipsis(0.55)
                }
                Breadcrumbs.chevron(0.25)
                stepView(step, index: index)
            }
        }
    }

    @ViewBuilder
    private func stepView(_ step: PathStep, index: Int) -> some View {
        let here = index == steps.count - 1
        let label = HStack(spacing: 5) {
            if let symbol = step.symbol {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            }
            Text(step.name)
                .font(.system(size: 12, weight: here ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.white.opacity(here ? 0.92 : (pointed == index && step.go != .nowhere ? 0.85 : 0.55)))
        .padding(.horizontal, 4)
        .frame(maxWidth: 220)
        .frame(height: DriveRow.height)
        .contentShape(Rectangle())
        let button = Button {
            // You're already here, so a click on this one copies its name.
            if here { model.copyName(of: thing(step)) } else { go(step.go) }
        } label: { label }
            .buttonStyle(.plain)
            .disabled(!here && step.go == .nowhere)
            .onHover { inside in
                if inside { pointed = index } else if pointed == index { pointed = nil }
            }
        if case .node(let node) = step.go {
            button
                .named(NamedThing(node), in: model)
                .help(here ? "Click to copy the name" : "⌘-click to copy the name")
        } else {
            button.help(here ? "Click to copy the name" : "")
        }
    }

    private func thing(_ step: PathStep) -> NamedThing {
        // The drive's step is named for the drive, not for its folder on it.
        if case .node(let node) = step.go, step.symbol == nil { return NamedThing(node) }
        return NamedThing(nodes: [], title: step.name)
    }

    private func go(_ where: PathStep.Go) {
        switch `where` {
        case .node(let node): model.go(to: node)
        case .bothDisks(let real): model.showBothDisks(of: real)
        case .nowhere: break
        }
    }
}
