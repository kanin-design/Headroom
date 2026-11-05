import AppKit
import Charts
import SwiftUI

struct SidePanel: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PanelArrows(model: model)
            Group {
                if model.searchActive && !model.searchText.isEmpty {
                    SearchPanel(model: model)
                } else {
                    VStack(spacing: 0) {
                        Group {
                            switch model.lens {
                            case .map: MapPanel(model: model)
                            case .changes: ChangesPanel(model: model)
                            case .freeUp: FreeUpPanel(model: model)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        NextStepBar(model: model)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// Back and forward through where you've been, in the same place on every tab.
private struct PanelArrows: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            arrow("chevron.left", help: "Back", isOn: model.canGoBack) { model.goBack() }
            arrow("chevron.right", help: "Forward", isOn: model.canGoForward) { model.goForward() }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    private func arrow(_ symbol: String, help: String, isOn: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(isOn ? 0.88 : 0.24))
                .frame(width: 30, height: 24)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(isOn ? 0.09 : 0.03)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isOn)
        .help(help)
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
                GeometryReader { g in
                    Capsule()
                        .fill(color.opacity(0.75))
                        .frame(width: max(g.size.width * min(share, 1), 2), height: 2)
                }
                .frame(height: 2)
                .padding(.leading, 16)
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
                    header(tree, subject)
                    if subject == 0 { summary(tree) }
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

    private func header(_ tree: DiskTree, _ subject: UInt32) -> some View {
        let name = subject == 0 ? (model.volume?.name ?? "Disk") : model.displayName(subject)
        let path = subject == 0 || HiddenNames.isOn ? nil : tree.path(subject).map(DiskTree.friendly)
        let thing = NamedThing(subject)
        return VStack(alignment: .leading, spacing: 5) {
            PanelTitle(title: name, subtitle: path, copyTitle: { model.copyName(of: thing) }, copySubtitle: { model.copyPath(of: thing) })
                .named(thing, in: model)
            if subject != 0, let facts = model.facts(of: subject) {
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
        let canGo = model.suggestions.everything.filter { $0.isQuick }.reduce(UInt64(0)) { $0 &+ $1.bytes }
        return VStack(alignment: .leading, spacing: 10) {
            if let biggest {
                Text("Your disk is \(Int(fullness * 100))% full. \(model.displayName(biggest)) is the biggest thing \(tree.isPartial ? "found so far" : "on it"), at \(formatBytes(tree.totals[Int(biggest)])).")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if canGo > 0 {
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { model.setLens(.freeUp) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text(tree.isPartial ? "\(formatBytes(canGo)) so far you wouldn't miss" : "About \(formatBytes(canGo)) you wouldn't miss")
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
            Text("Space that hasn't been read yet. This piece shrinks as the scan goes on, and whatever is left at the end is space Headroom can't look inside.")
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
                            Text("Removing this frees")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.65))
                            Text(formatBytes(story.reclaim))
                                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(Color(red: 1, green: 0.74, blue: 0.42))
                        }
                        Text("\(formatBytes(story.sharedOut)) of this is the same files as \(story.sharedPlace ?? "another folder"). That space only comes back when both are gone.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.68))
                            .fixedSize(horizontal: false, vertical: true)
                        goTo(story.sharedPlace, story.sharedPlaceNode)
                    }
                }
                if story.linkedIn >= enough {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("This also holds \(formatBytes(story.linkedIn)) of links to files counted under \(story.linkedPlace ?? "another folder"). They take no extra space here.")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.68))
                            .fixedSize(horizontal: false, vertical: true)
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
                            subtitle: linksWorthNaming(tree, node) ? "plus \(formatBytes(tree.aliasTotals[Int(node)])) of links" : subtitle(tree, node),
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
                    Label("Reveal in Finder", systemImage: "folder")
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PanelTitle(title: "What changed")
                picker
                if model.history.count >= 2 { chart }
                caption
                rows
            }
            .padding(16)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .scrollIndicators(.never)
    }

    private var picker: some View {
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

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeading(text: "Free space over time")
            Chart(model.history) { point in
                AreaMark(x: .value("When", point.date), y: .value("Free", Double(point.free) / 1e9))
                    .foregroundStyle(LinearGradient(colors: [Color(red: 0.4, green: 0.95, blue: 0.7).opacity(0.28), .clear], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("When", point.date), y: .value("Free", Double(point.free) / 1e9))
                    .foregroundStyle(Color(red: 0.45, green: 0.98, blue: 0.72))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
            }
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

    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            if model.changeTotal != 0 {
                let grew = model.changeTotal > 0
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(formatBytes(UInt64(abs(model.changeTotal))))
                        .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(grew ? Palette.heat(0.62).swiftUI : Palette.reclaim(.rebuilds).swiftUI)
                        .contentTransition(.numericText(value: Double(model.changeTotal)))
                    Text(model.changeCaption.hasPrefix("Compared") ? (grew ? "less free" : "more free") : "new or changed")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            Text(model.changeCaption)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var rows: some View {
        if model.tree != nil {
            let biggest = Double(max(model.changeRows.first?.delta ?? 1, 1))
            LazyVStack(spacing: 0) {
                ForEach(model.changeRows) { row in
                    NodeRow(title: row.title, subtitle: row.subtitle, value: "+" + formatBytes(UInt64(max(row.delta, 0))), share: Double(row.delta) / biggest,
                            color: Palette.heat(0.3 + 0.6 * Float(Double(row.delta) / biggest)).swiftUI,
                            valueColor: Palette.heat(0.68).swiftUI,
                            onHover: { inside in model.highlight(node: inside ? row.node : nil) },
                            onTap: { open(row.node) })
                        .named(NamedThing(row.node), in: model)
                }
            }
            .padding(.horizontal, -8)
            if model.changeRows.isEmpty {
                Text("Nothing has grown by much in this window.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
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
                    PanelTitle(title: "\(model.searchResults.count.formatted()) found")
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
