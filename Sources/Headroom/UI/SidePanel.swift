import AppKit
import Charts
import SwiftUI

/// The inspector beside the map: what the view you're in has to say, or what a search found.
struct SidePanel: View {
    let model: AppModel

    /// How wide it opens. Wide enough for Free Up's evidence, ticks and plan, and you can drag it wider.
    static let idealWidth: CGFloat = 384

    var body: some View {
        Group {
            if model.isSearching {
                SearchPanel(model: model)
            } else {
                VStack(spacing: 0) {
                    Group {
                        switch model.lens {
                        case .map: MapPanel(model: model)
                        case .changes: ChangesPanel(model: model)
                        case .freeUp: FreeUpPanel(model: model)
                        case .copies: CopiesPanel(model: model)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    NextStepBar(model: model)
                }
            }
        }
        // Never taller than the window. Measured as if it had no width at all, a line that wraps rather than being cut
        // short counts as hundreds of points tall, and without this the inspector grew to fit it: the list's top went under
        // the toolbar and the bar below it off the bottom of the window.
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: Shared pieces

struct PanelTitle: View {
    let title: String
    var subtitle: String? = nil
    var copyTitle: (() -> Void)? = nil
    var copySubtitle: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white.opacity(0.96))
                .lineLimit(2)
                .truncationMode(.middle)
                .clickToCopy(copyTitle, help: "Click to copy the name")
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .clickToCopy(copySubtitle, help: "Click to copy the path")
            }
        }
    }
}

struct SectionHeading: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}

/// A row in any list: name, where it is, how big, and a hairline showing its share.
struct NodeRow: View {
    let title: String
    let subtitle: String?
    let value: String
    let share: Double
    let color: Color
    var valueColor: Color = .white.opacity(0.82)
    /// Where the keyboard is, in a list you can walk through.
    var isLit = false
    /// A list with no sizes to compare, such as aliases, has no bar.
    var showsBar = true
    let onHover: (Bool) -> Void
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 6)
                    Text(value)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(valueColor)
                }
                if showsBar {
                    GeometryReader { g in
                        Capsule()
                            .fill(color.opacity(0.75))
                            .frame(width: max(g.size.width * min(share, 1), 2), height: 2)
                    }
                    .frame(height: 2)
                    .padding(.leading, 16)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(isHovered || isLit ? 0.075 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            isHovered = inside
            onHover(inside)
        }
    }
}

// MARK: Map

struct MapPanel: View {
    let model: AppModel

    var body: some View {
        if let tree = model.tree {
            let subject = model.selected ?? model.focus
            let _ = model.treeVersion
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // The disk's name is the window's title, so the whole disk starts with what's on it.
                    if subject == 0 { summary(tree) } else { header(tree, subject) }
                    description(tree, subject)
                    if model.selected == nil { WorthDoing(model: model) }
                    kinds(tree, subject)
                    if model.selected == nil { contents(tree) }
                    actions(tree, subject)
                }
                .padding(16)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .scrollIndicators(.never)
        }
    }

    /// A folder's or a file's name, where it is, and what's known about it.
    private func header(_ tree: DiskTree, _ subject: UInt32) -> some View {
        let path = HiddenNames.isOn ? nil : tree.path(subject).map(DiskTree.friendly)
        let thing = NamedThing(subject)
        return VStack(alignment: .leading, spacing: 5) {
            PanelTitle(title: model.displayName(subject), subtitle: path, copyTitle: { model.copyName(of: thing) }, copySubtitle: { model.copyPath(of: thing) })
                .named(thing, in: model)
            if let facts = model.facts(of: subject) {
                Text(tree.sizeText(subject) + " · " + facts)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func summary(_ tree: DiskTree) -> some View {
        let free = tree.totals[Int(tree.free)]
        let fullness = 1 - Double(free) / Double(max(tree.capacityBytes, 1))
        let biggest = model.flatTop(tree).first
        let canGo = model.suggestions.everything.filter(\.isRecommended).reduce(UInt64(0)) { $0 &+ $1.bytes }
        return VStack(alignment: .leading, spacing: 10) {
            if !model.hasFullAccess {
                Text("\(Int((fullness * 100).rounded()))% full · Needs Full Disk Access")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let biggest {
                Text("\(Int((fullness * 100).rounded()))% full · Largest\(tree.isPartial ? " so far" : ""): \(model.displayName(biggest)), \(formatBytes(tree.totals[Int(biggest)]))")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if canGo > 0 {
                Button {
                    Motion.animate(.spring(response: 0.34, dampingFraction: 0.82)) { model.setLens(.freeUp) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text(tree.isPartial ? "\(formatBytes(canGo)) safe to clear so far" : "About \(formatBytes(canGo)) safe to clear")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.5, green: 0.98, blue: 0.7))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func description(_ tree: DiskTree, _ subject: UInt32) -> some View {
        let node = tree.nodes[Int(subject)]
        if tree.isPartial && subject == tree.hidden {
            Text("Not scanned yet. What's left when the scan ends is space Headroom can't read.")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        } else if node.rule != 0 {
            let rule = model.rules.rule(node.rule)
            VStack(alignment: .leading, spacing: 4) {
                if rule.tier != .none {
                    Text(rule.tier.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.reclaim(rule.tier).swiftUI)
                }
                Text(rule.detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let story = model.story {
            linkNote(tree, subject, story)
        }
    }

    /// What no other disk map tells you: a folder can add up to a lot and still free almost nothing.
    @ViewBuilder
    private func linkNote(_ tree: DiskTree, _ subject: UInt32, _ story: LinkStory) -> some View {
        let enough: UInt64 = 50_000_000
        if story.sharedOut >= enough || story.linkedIn >= enough {
            VStack(alignment: .leading, spacing: 8) {
                if story.sharedOut >= enough {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("Frees")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.65))
                            Text(formatBytes(story.reclaim))
                                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(Color(red: 1, green: 0.74, blue: 0.42))
                        }
                        Text("\(formatBytes(story.sharedOut)) hardlinked or cloned with \(story.sharedPlace ?? "another folder")")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.68))
                            .fixedSize(horizontal: false, vertical: true)
                            .help("Freed only when both are deleted")
                        goTo(story.sharedPlace, story.sharedPlaceNode)
                    }
                }
                if story.linkedIn >= enough {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Plus \(formatBytes(story.linkedIn)) hardlinked or cloned, counted under \(story.linkedPlace ?? "another folder")")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.68))
                            .fixedSize(horizontal: false, vertical: true)
                            .help("Takes no extra space here")
                        goTo(story.linkedPlace, story.linkedPlaceNode)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(red: 1, green: 0.74, blue: 0.42).opacity(0.08)))
        }
    }

    /// The other side of a hard link or a clone.
    @ViewBuilder
    private func goTo(_ place: String?, _ node: UInt32?) -> some View {
        if let place, let node {
            Button {
                model.goToPlace(node)
            } label: {
                Label("Go to \(place)", systemImage: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.74, blue: 0.42))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
        }
    }

    @ViewBuilder
    private func kinds(_ tree: DiskTree, _ subject: UInt32) -> some View {
        let values = tree.kindBytes(subject)
        let total = max(values.reduce(0, +), 1)
        let sorted = Kind.allCases.map { ($0, values[Int($0.rawValue)]) }.filter { Double($0.1) / Double(total) > 0.004 }.sorted { $0.1 > $1.1 }
        if !sorted.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                // The ring's colours say which folder is which, so these stay plain steps of grey. Point at one to see it lit.
                GeometryReader { g in
                    HStack(spacing: 1.5) {
                        ForEach(Array(sorted.enumerated()), id: \.element.0) { index, entry in
                            Self.tone(index)
                                .frame(width: max((g.size.width - CGFloat(sorted.count - 1) * 1.5) * CGFloat(Double(entry.1) / Double(total)), 1.5))
                        }
                    }
                }
                .frame(height: 8)
                .clipShape(Capsule())
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 5) {
                    ForEach(Array(sorted.prefix(8).enumerated()), id: \.element.0) { index, entry in
                        let kind = entry.0, bytes = entry.1
                        HStack(spacing: 5) {
                            Circle().fill(Self.tone(index)).frame(width: 6, height: 6)
                            Text(kind.title)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.72))
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text(formatBytes(bytes))
                                .font(.system(size: 10.5).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .contentShape(Rectangle())
                        .onHover { inside in model.highlight(kind: inside ? kind : nil) }
                    }
                }
            }
        }
    }

    private static func tone(_ index: Int) -> Color {
        .white.opacity(max(0.78 - Double(index) * 0.1, 0.18))
    }

    @ViewBuilder
    private func contents(_ tree: DiskTree) -> some View {
        let focus = RingLayout.chainTail(tree: tree, model.focus)
        let rows = model.panelNodes(tree)
        let top = rows.prefix(80)
        let biggest = Double(max(top.first.map { tree.totals[Int($0)] } ?? 1, 1))
        VStack(alignment: .leading, spacing: 4) {
            SectionHeading(text: model.focus == 0 ? "Biggest" : "Inside", trailing: rows.count > 80 ? "Top 80 of \(rows.count)" : nil)
                .padding(.horizontal, 8)
            LazyVStack(spacing: 0) {
                ForEach(top, id: \.self) { node in
                    NodeRow(title: model.displayName(node),
                            subtitle: linksWorthNaming(tree, node) ? "plus \(formatBytes(tree.aliasTotals[Int(node)])) hardlinked or cloned" : subtitle(tree, node),
                            value: tree.sizeText(node),
                            share: Double(tree.totals[Int(node)]) / biggest,
                            color: model.listColor(node, in: tree),
                            onHover: { inside in model.highlight(node: inside ? node : nil) },
                            onTap: { open(node) })
                        .named(NamedThing(node), in: model)
                }
                let own = tree.nodes[Int(focus)]
                if model.focus != 0, own.bytes > 0 {
                    NodeRow(title: "Smaller items here", subtitle: nil, value: formatBytes(own.bytes),
                            share: Double(own.bytes) / biggest, color: .white.opacity(0.3), onHover: { _ in }, onTap: {})
                }
            }
        }
    }

    private func linksWorthNaming(_ tree: DiskTree, _ node: UInt32) -> Bool {
        let links = tree.aliasTotals[Int(node)]
        return links >= 1_000_000_000 && Double(links) >= Double(tree.totals[Int(node)]) * 0.25
    }

    private func subtitle(_ tree: DiskTree, _ node: UInt32) -> String? {
        let n = tree.nodes[Int(node)]
        if n.has(NodeFlag.locked) { return "Locked by macOS" }
        if n.has(NodeFlag.denied) { return "Can't be read" }
        if n.has(NodeFlag.ruleRoot) { return model.rules.rule(n.rule).tier.title }
        return nil
    }

    // Asked for when it's clicked. A row that held on to the tree it was drawn from would keep all of that tree in memory.
    private func open(_ node: UInt32) {
        guard let tree = model.tree else { return }
        let n = tree.nodes[Int(node)]
        if n.has(NodeFlag.directory) && n.firstChild != 0 {
            model.zoom(into: RingLayout.chainTail(tree: tree, node))
        } else {
            model.selected = node
        }
    }

    @ViewBuilder
    private func actions(_ tree: DiskTree, _ subject: UInt32) -> some View {
        if subject != 0, let path = tree.path(subject) {
            HStack(spacing: 8) {
                Button {
                    model.reveal(subject)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(.glass)
                if Safety.canTrash(path) {
                    DeleteMenu(model: model, node: subject)
                }
            }
            .controlSize(.regular)
        }
    }
}

struct DeleteMenu: View {
    let model: AppModel
    let node: UInt32

    var body: some View {
        // Depends on the list, so it follows any change to it.
        let _ = model.plan.items.count
        let planned = model.isPlanned(node)
        Menu {
            ThingMenuItems(actions: model.deleteActions(for: NamedThing(node)))
        } label: {
            Label(planned ? "Selected" : "Delete", systemImage: planned ? "checkmark.circle.fill" : "trash")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
    }
}

// MARK: Changes

struct ChangesPanel: View {
    let model: AppModel

    private var windows: [ChangeWindow] { [.lastScan, .days(1), .days(7), .days(30)] }

    private var untouched: Bool { model.changeWindow.isUntouched }

    /// The lists follow the folder you're in, and say which it is.
    private var place: String {
        guard model.focus != 0, let tree = model.tree else { return "" }
        return " in " + model.displayName(RingLayout.chainTail(tree: tree, model.focus))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    picker(windows)
                    // The other way round: what nothing has changed in for that long.
                    HStack(spacing: 8) {
                        Text("Untouched")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                            .fixedSize()
                            .padding(.leading, 10)
                        picker(ChangeWindow.untouchedWindows)
                    }
                }
                if recent.count >= 2, !untouched { chart }
                rows
            }
            .padding(16)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .scrollIndicators(.never)
    }

    private func picker(_ windows: [ChangeWindow]) -> some View {
        HStack(spacing: 2) {
            ForEach(windows) { window in
                Button {
                    model.setChangeWindow(window)
                } label: {
                    Text(window.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(model.changeWindow == window ? Color.white : Color.white.opacity(0.58))
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background(Capsule().fill(.white.opacity(model.changeWindow == window ? 0.15 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.05)))
    }

    /// The ring's colours as a scale, taken from the ring itself: how much of each piece is new or changed, or untouched. None
    /// of it stays quiet, as on the ring, and the first sliver fades in from there; the bar gives that its own short stretch
    /// at the start, because on the ring it all happens in the first percent.
    private var scale: some View {
        let colour: (Double) -> Color = untouched
            ? { Lenses.untouchedLab(untouched: UInt64($0 * 1e9), bytes: 1_000_000_000).swiftUI }
            : { Lenses.changeLab(delta: Int64($0 * 1e9), bytes: 1_000_000_000).swiftUI }
        let fade = 0.08
        let stops = (0...24).map { i -> Gradient.Stop in
            let at = Double(i) / 24
            let share = at < fade ? at / fade * 0.01 : 0.01 + (at - fade) / (1 - fade) * 0.99
            return Gradient.Stop(color: colour(share), location: at)
        }
        return HStack(spacing: 6) {
            Text("0%")
            LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
                .frame(width: 112, height: 6)
                .clipShape(Capsule())
                // The ring's colours give off light, and so does their scale.
                .shadow(color: colour(0.8).opacity(0.4), radius: 3)
            Text("100%")
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.5))
    }

    /// The free-space record for the last month.
    private var recent: [HistoryPoint] {
        let start = Date().addingTimeInterval(-30 * 86_400)
        return model.history.filter { $0.date >= start }
    }

    /// When it happened: free space over the last month, with the window you're looking at shaded.
    private var chart: some View {
        let points = recent
        let now = Date()
        let first = points.first?.date ?? now
        let start = model.changeWindow == .lastScan ? (points.dropLast().last?.date ?? first) : max(first, now.addingTimeInterval(-model.changeWindow.seconds))
        return VStack(alignment: .leading, spacing: 6) {
            SectionHeading(text: "Free space")
            Chart {
                RectangleMark(xStart: .value("From", start), xEnd: .value("To", now))
                    .foregroundStyle(Palette.grew.swiftUI.opacity(0.14))
                ForEach(points) { point in
                    LineMark(x: .value("When", point.date), y: .value("Free", Double(point.free) / 1e9))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
            }
            // Its own range rather than from zero, so a drop of a few GB shows.
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.white.opacity(0.07))
                    AxisValueLabel {
                        if let gb = value.as(Double.self) {
                            Text("\(Int(gb)) GB").font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.white.opacity(0.42))
                        }
                    }
                }
            }
            .frame(height: 64)
        }
    }


    @ViewBuilder
    private var rows: some View {
        if model.tree != nil {
            HStack(alignment: .center) {
                SectionHeading(text: (untouched ? "Untouched" : model.changeUsesHistory ? "Grew" : "Modified") + place)
                if !model.changeRows.isEmpty { scale }
            }
            if model.changeRows.isEmpty {
                Text(!model.hasFullAccess ? "Needs Full Disk Access"
                     : untouched ? "Nothing large untouched that long" : model.changeUsesHistory ? "Nothing grew much" : "Nothing large modified")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                list(model.changeRows)
            }
            if !model.changeShrank.isEmpty {
                SectionHeading(text: "Shrank")
                list(model.changeShrank)
            }
        }
    }

    /// Each row is the colour its folder has on the ring: how much of it is new or changed. What shrank is blue.
    private func list(_ rows: [ChangeRow]) -> some View {
        let biggest = Double(max(rows.map { abs($0.delta) }.max() ?? 1, 1))
        return LazyVStack(spacing: 0) {
            ForEach(rows) { row in
                let share = Double(abs(row.delta)) / biggest
                let size = model.tree.map { $0.totals[Int(row.node)] } ?? 0
                let colour = untouched ? Lenses.untouchedLab(untouched: UInt64(max(row.delta, 0)), bytes: size).swiftUI
                    : row.delta < 0 ? Palette.cool.swiftUI : Lenses.changeLab(delta: row.delta, bytes: size).swiftUI
                let value = untouched ? formatBytes(UInt64(max(row.delta, 0))) : (row.delta < 0 ? "−" : "+") + formatBytes(UInt64(abs(row.delta)))
                NodeRow(title: row.title, subtitle: row.subtitle, value: value,
                        share: share, color: colour, valueColor: untouched ? Palette.untouched.swiftUI : row.delta < 0 ? Palette.cool.swiftUI : Palette.grew.swiftUI,
                        onHover: { inside in model.highlight(node: inside ? row.node : nil) },
                        onTap: { open(row.node) })
                    .named(NamedThing(row.node), in: model)
            }
        }
        .padding(.horizontal, -8)
    }

    private func open(_ node: UInt32) {
        guard let tree = model.tree else { return }
        let n = tree.nodes[Int(node)]
        if n.has(NodeFlag.directory) && n.firstChild != 0 {
            model.zoom(into: RingLayout.chainTail(tree: tree, node))
        } else {
            model.zoom(into: n.parent)
            model.selected = node
        }
    }
}

// MARK: Search

struct SearchPanel: View {
    let model: AppModel

    private func open(_ node: UInt32) {
        guard let tree = model.tree else { return }
        let n = tree.nodes[Int(node)]
        if n.has(NodeFlag.directory) && n.firstChild != 0 { model.zoom(into: RingLayout.chainTail(tree: tree, node)) }
        else { model.zoom(into: n.parent); model.selected = node }
    }

    var body: some View {
        if let tree = model.tree {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Like the list on the Map, it says when there's more than it shows.
                    PanelTitle(title: "\(model.searchResults.count.formatted()) found",
                               subtitle: model.searchResults.count > 120 ? "Top 120 shown" : nil)
                    let top = model.searchResults.prefix(120)
                    let biggest = Double(max(top.first.map { tree.totals[Int($0)] } ?? 1, 1))
                    LazyVStack(spacing: 0) {
                        ForEach(top, id: \.self) { node in
                            let n = tree.nodes[Int(node)]
                            NodeRow(title: tree.name(node), subtitle: tree.path(n.parent).map(DiskTree.friendly), value: formatBytes(tree.totals[Int(node)]),
                                    share: Double(tree.totals[Int(node)]) / biggest,
                                    color: Palette.color(tree.dominantKind(node)).swiftUI,
                                    onHover: { inside in if inside { model.highlight(node: node) } else { model.highlight(nodes: Array(model.searchResults.prefix(400))) } },
                                    onTap: { open(node) })
                                .named(NamedThing(node), in: model)
                        }
                    }
                    .padding(.horizontal, -8)
                }
                .padding(16)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .scrollIndicators(.never)
        }
    }
}
