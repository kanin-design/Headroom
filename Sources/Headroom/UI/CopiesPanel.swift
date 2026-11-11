import SwiftUI

/// Copies in the inspector, made like Free Up: a short stack of rows, one for each set of copies, each in the colour its copies
/// wear on the ring, so the list is the legend. A tick sends the extra copies to the Trash with the next clean, and the copy that
/// stays is named. What takes no extra room, other names and clones, and the aliases, is folded away under it. Like every list
/// in the inspector, it follows the folder you're in.
struct CopiesPanel: View {
    let model: AppModel

    /// The most rows of copies shown before saying how many more there are.
    private static let most = 60

    var body: some View {
        let groups = model.copyGroupsHere
        let sets = groups.filter { $0.kind == .duplicate }
        let once = groups.filter { $0.kind == .sameFile || $0.kind == .sharedCopy }
        let aliases = groups.filter { $0.kind == .alias || $0.kind == .broken }
        let scale = max(sets.map(\.back).max() ?? 1, 1)
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                summary(sets)
                    .padding(.horizontal, 11)
                    .padding(.top, 3)
                    .padding(.bottom, 9)
                ForEach(sets.prefix(Self.most)) { set in
                    CopySetRow(model: model, group: set, scale: scale)
                }
                if sets.count > Self.most {
                    Text("\((sets.count - Self.most).formatted()) more, smaller")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                }
                if !once.isEmpty {
                    Folded(model: model, title: "Hardlinks and clones", groups: once, total: once.reduce(UInt64(0)) { $0 &+ $1.size })
                        .padding(.top, 8)
                }
                if !aliases.isEmpty {
                    Folded(model: model, title: "Symlinks", groups: aliases, total: nil)
                        .padding(.top, once.isEmpty ? 8 : 2)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private func summary(_ sets: [CopyGroup]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(sentence(sets))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                @Bindable var model = model
                Button { model.copiesHelpShown.toggle() } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(model.copiesHelpShown ? 0.85 : 0.45))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete, hardlink, symlink")
                .popover(isPresented: $model.copiesHelpShown, arrowEdge: .bottom) { CopiesHelp() }
            }
            if model.copiesReading {
                ProgressView(value: Double(model.copiesGroupsDone), total: Double(max(model.copiesGroupsTotal, 1)))
                    .progressViewStyle(.linear)
                    .tint(.white.opacity(0.7))
                    .controlSize(.small)
                Text("Comparing… \(formatBytes(model.copiesBytesRead)) read")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private func sentence(_ sets: [CopyGroup]) -> String {
        if !model.hasFullAccess { return "Needs Full Disk Access" }
        if model.tree?.isPartial != false { return "Waiting for the scan" }
        guard model.copies != nil else { return "Looking for duplicates…" }
        let back = sets.reduce(UInt64(0)) { $0 &+ $1.back }
        if back == 0 { return model.copiesReading ? "Looking for duplicates…" : "No duplicates" }
        return "\(formatBytes(back)) in duplicates"
    }
}

/// What the three actions do, and what a clone is, a line each: behind the ? at the top of Copies.
private struct CopiesHelp: View {
    private let rows: [(term: String, means: String)] = [
        ("Delete", "Moves the other copies to the Trash."),
        ("Hardlink", "One file, several paths. Editing it anywhere changes it everywhere."),
        ("Symlink", "The other paths point to the copy you keep. They break if it moves."),
        ("Clone", "Separate files that share space until one of them changes."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(rows, id: \.term) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.term)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 62, alignment: .leading)
                        Text(row.means)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("The space comes back when the Trash is emptied. Undo puts the copies back.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 330)
    }
}

/// One set of copies, as a Free Up box is drawn: its tick in the set's colour, the space it takes again, where the copies are,
/// and a bar of the duplicates. Opened, it lists every copy, with the one to keep marked and any other a click away, and
/// three ways to take the others out: delete, hardlink, symlink.
private struct CopySetRow: View {
    let model: AppModel
    let group: CopyGroup
    let scale: UInt64
    @State private var isHovered = false

    private var isOpen: Bool { model.copiesOpen.contains(group.id) }

    var body: some View {
        let state = model.duplicateTick(group)
        let colour = group.colour.swiftUI
        let isLit = isHovered || model.hotCopyGroup == group.id
        VStack(alignment: .leading, spacing: 0) {
            head(state, colour, isLit)
            if isOpen { inside(colour) }
        }
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(background(colour, state, isLit || isOpen)))
        .animation(.easeOut(duration: 0.14), value: isLit)
    }

    private func head(_ state: TickState, _ colour: Color, _ isLit: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            TickMark(state: state, color: colour, size: 20, isLit: isLit)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(group.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    Text(formatBytes(group.back))
                        .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.92))
                }
                HStack(spacing: 6) {
                    // Where the one that stays is comes first and is kept whole; a row of many files keeps its count at the end.
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(group.files > 1 ? .middle : .tail)
                    Spacer(minLength: 0)
                    chevron
                }
                .frame(minHeight: 15)
                bar(colour, state: state, isLit: isLit)
                    .padding(.top, 3)
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { inside in
            isHovered = inside
            model.pointAtCopyGroup(inside ? group : nil)
        }
        .onTapGesture {
            Motion.animate(.snappy(duration: 0.18)) { model.toggleDuplicate(group) }
        }
        .help("Delete the duplicates on the next Clean")
    }

    private var chevron: some View {
        Button {
            Motion.animate(.snappy(duration: 0.22)) {
                if isOpen { model.copiesOpen.remove(group.id) } else { model.copiesOpen.insert(group.id) }
            }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .foregroundStyle(.white.opacity(isHovered || isOpen ? 0.75 : 0.4))
                .frame(width: 20, height: 15)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Hide copies" : "Show copies")
    }

    /// Every copy, each original first with its extra copies under it. A row of many files lists its folders instead.
    private var lines: [(node: UInt32, stays: Bool, opensSet: Bool)] {
        if group.files > 6 { return (group.homes.isEmpty ? [group.home] : group.homes).map { ($0, true, false) } + group.others.map { ($0, false, false) } }
        var out: [(UInt32, Bool, Bool)] = []
        for (i, set) in group.sets.enumerated() {
            out.append((set.keeper, true, i > 0))
            for extra in set.extras { out.append((extra, false, false)) }
        }
        return out
    }

    private func inside(_ colour: Color) -> some View {
        let shown = lines
        // Where each one is, said as the names around the ring say it, so a line and its name match, and so that no two
        // lines read the same.
        let places = model.tree.map { tree in
            CopiesMap.places(shown.map { tree.nodes[Int($0.node)].has(NodeFlag.directory) ? $0.node : tree.nodes[Int($0.node)].parent }, in: tree, short: true)
        } ?? []
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(shown.enumerated()), id: \.element.node) { at, line in
                CopyLine(model: model, group: group, node: line.node, stays: line.stays, colour: colour, place: at < places.count ? places[at] : "")
                    .padding(.top, line.opensSet ? 6 : 0)
            }
            // What happens to every copy not marked Keep.
            HStack(spacing: 6) {
                ForEach(AppModel.CopyAction.allCases, id: \.self) { action in
                    Button { model.takeCopies(group, action) } label: {
                        Text(action.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(model.isCleaning ? 0.4 : 0.95))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(colour.opacity(model.isCleaning ? 0.12 : 0.3)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isCleaning)
                    .help(Self.help[action] ?? "")
                }
            }
            .padding(.top, 7)
        }
        .padding(.leading, 33)
        .padding(.trailing, 10)
        .padding(.bottom, 10)
    }

    private var detail: String {
        guard let tree = model.tree else { return "" }
        return CopiesMap.summary(of: group, in: tree)
    }

    private static let help: [AppModel.CopyAction: String] = [
        .delete: "Move the other copies to the Trash",
        .hardlink: "Replace the other copies with hard links to the one you keep",
        .symlink: "Replace the other copies with symlinks to the one you keep",
    ]

    /// The extra copies, each to scale against the biggest row, as Free Up's bars show each thing in a box.
    private func bar(_ colour: Color, state: TickState, isLit: Bool) -> some View {
        let nodes = model.tree?.nodes
        let sizes = group.extras.prefix(40).map { node in nodes.map { Double($0[Int(node)].bytes) } ?? 0 }
        return GeometryReader { g in
            HStack(spacing: 1.5) {
                ForEach(Array(sizes.enumerated()), id: \.offset) { _, bytes in
                    Capsule()
                        .fill(colour.opacity(state == .none ? (isLit ? 0.85 : 0.6) : 1))
                        .frame(width: max(g.size.width * bytes / Double(scale) - 1.5, 2))
                }
            }
        }
        .frame(height: 5)
    }

    private func background(_ colour: Color, _ state: TickState, _ isLit: Bool) -> Color {
        switch state {
        case .all: colour.opacity(isLit ? 0.2 : 0.14)
        case .some: colour.opacity(isLit ? 0.13 : 0.07)
        case .none: .white.opacity(isLit ? 0.07 : 0)
        }
    }
}

/// One copy in an open set: where it is, its name there, when it changed and its size. Pointing at it makes it stand out on
/// the ring among its other copies. The one to keep is marked; a click on any other keeps that one instead, as radio buttons.
private struct CopyLine: View {
    let model: AppModel
    let group: CopyGroup
    let node: UInt32
    let stays: Bool
    let colour: Color
    /// The folder it's in, or for a row of many files, the folder itself, said apart from the other lines' places.
    let place: String
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .strokeBorder(colour, lineWidth: 1.5)
                .background(Circle().fill(stays ? colour : colour.opacity(isHovered ? 0.4 : 0)))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(place)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // A long name gives way; its date and size are what tell the copies apart, so they stay whole.
                HStack(spacing: 0) {
                    Text(info.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(info.facts)
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 4)
            if stays || isHovered {
                Text("Keep")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(stays ? colour : .white.opacity(0.75))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(stays ? colour.opacity(0.16) : .white.opacity(0.1)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(isHovered ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { inside in
            isHovered = inside
            if inside { model.pointAtCopy(node, of: group) } else { model.pointAtCopyGroup(group) }
        }
        // The whole line is the choice, not just the words that appear on it.
        .onTapGesture { keep() }
        .help(wholePlace)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(stays ? [.isSelected] : [.isButton])
        .accessibilityAction(named: "Keep") { keep() }
    }

    private func keep() {
        guard !stays else { return }
        Motion.animate(.snappy(duration: 0.2)) { model.keepCopy(node, of: group) }
    }

    /// The whole path the short place stands for, shown when the pointer rests on the line.
    private var wholePlace: String {
        guard let tree = model.tree else { return place }
        let n = tree.nodes[Int(node)]
        return tree.friendlyPath(n.has(NodeFlag.directory) ? node : n.parent)
    }

    private var info: (name: String, facts: String) {
        guard let tree = model.tree else { return ("", "") }
        let n = tree.nodes[Int(node)]
        if n.has(NodeFlag.directory) {
            let files = (group.keepers + group.extras).filter { tree.nodes[Int($0)].parent == node }
            let bytes = files.reduce(UInt64(0)) { $0 &+ tree.nodes[Int($1)].bytes }
            return ("\(files.count) files", " · \(formatBytes(bytes))")
        }
        let when = Date(timeIntervalSince1970: TimeInterval(n.modTime)).formatted(.dateTime.day().month(.abbreviated).year())
        return (tree.name(node), " · \(when) · \(formatBytes(n.bytes))")
    }
}

/// What's folded away under the duplicates, as "Done another way" is in Free Up: hardlinks, clones and symlinks, which take no
/// extra space.
private struct Folded: View {
    let model: AppModel
    let title: String
    let groups: [CopyGroup]
    let total: UInt64?
    private var isOpen: Bool { model.copiesOpen.contains(title) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Motion.animate(.snappy(duration: 0.22)) {
                    if isOpen { model.copiesOpen.remove(title) } else { model.copiesOpen.insert(title) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 10)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(groups.count.formatted())
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    if let total {
                        Text(formatBytes(total))
                            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            if isOpen {
                LazyVStack(spacing: 0) {
                    ForEach(groups.prefix(80)) { group in
                        NodeRow(title: group.title, subtitle: subtitle(group), value: value(group), share: 0, color: group.colour.swiftUI,
                                isLit: model.hotCopyGroup == group.id, showsBar: false,
                                onHover: { inside in model.pointAtCopyGroup(inside ? group : nil) },
                                onTap: { open(group) })
                    }
                }
                .padding(.leading, 8)
            }
        }
    }

    private func subtitle(_ g: CopyGroup) -> String {
        guard let tree = model.tree else { return "" }
        // Said apart, so two places that end the same way don't read as one.
        let elsewhere = CopiesMap.places(Array(g.others.prefix(2)), in: tree, short: true).joined(separator: ", ") + (g.others.count > 2 ? " +\(g.others.count - 2)" : "")
        switch g.kind {
        case .sameFile: return "Hardlink · \(elsewhere)"
        case .sharedCopy: return "Clone · \(elsewhere)"
        case .alias, .broken:
            // Where the symlink is, and what it points to: a path, which says when it's missing or on a disk that isn't connected.
            let target = g.kind == .alias && g.home != 0 ? place(g.home, tree) : (g.target ?? "")
            return "\(CopiesMap.place(g.others[0], in: tree, short: true)) → \(target)"
        case .duplicate: return ""
        }
    }

    private func value(_ g: CopyGroup) -> String {
        g.kind == .sameFile || g.kind == .sharedCopy ? formatBytes(g.size) : ""
    }

    private func open(_ g: CopyGroup) {
        guard let tree = model.tree else { return }
        let node = g.home != 0 && g.kind != .broken ? g.home : g.others[0]
        let n = tree.nodes[Int(node)]
        if n.has(NodeFlag.directory) && n.firstChild != 0 {
            model.zoom(into: RingLayout.chainTail(tree: tree, node))
        } else {
            model.zoom(into: n.parent)
            model.selected = node
        }
    }
}

/// Where something is, as short as it can be said: from your home folder, or from the top of the disk you're looking at, and
/// deep places by their first two folders and their last two, `Projects/p1/…/darwin-arm64/bin`, which is what tells copies apart.
private func place(_ node: UInt32, _ tree: DiskTree) -> String {
    CopiesMap.place(node, in: tree)
}
