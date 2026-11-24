import SwiftUI

/// The inspector beside the map: the mode's panel, or what a search found. In Changes, the time to compare with sits on
/// top; in Copies with Free Up, the duplicates take the place of the suggestions.
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
                    if model.view == .changes { ChangesWindow(model: model) }
                    Group {
                        if model.mode == .backup {
                            BackupPanel(model: model)
                        } else if model.view == .copies {
                            CopiesPanel(model: model)
                        } else {
                            FreeUpPanel(model: model)
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
                .font(Kit.Font.title)
                .foregroundStyle(Kit.Text.primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .clickToCopy(copyTitle, help: "Click to copy the name")
            if let subtitle {
                Text(subtitle)
                    .font(Kit.Font.detail)
                    .foregroundStyle(Kit.Text.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .clickToCopy(copySubtitle, help: "Click to copy the path")
            }
        }
    }
}

// MARK: Map

struct DeleteMenu: View {
    let model: AppModel
    let node: UInt32

    var body: some View {
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

private struct ChangesWindow: View {
    let model: AppModel

    private var windows: [ChangeWindow] { [.lastScan, .days(1), .days(7), .days(30)] }

    private var untouched: Bool { model.changeWindow.isUntouched }

    var body: some View {
        VStack(alignment: .leading, spacing: Kit.Space.medium) {
            picker(windows, name: "Changed in")
            HStack(spacing: Kit.Space.regular) {
                PickerLabel(text: "Untouched")
                    .padding(.leading, Kit.rowInset)
                picker(ChangeWindow.untouchedWindows, name: "Untouched for")
            }
            scale
                .padding(.leading, Kit.rowInset)
                .padding(.top, Kit.Space.tight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Kit.panelInset)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// Both rows choose the one window: each lights only when it's one of its own.
    private func picker(_ windows: [ChangeWindow], name: String) -> some View {
        Segmented(name: name, options: windows, selection: model.changeWindow, title: \.title) { model.setChangeWindow($0) }
    }

    /// The ring's colours as a scale, taken from the ring itself: how much of each piece is new or changed, or untouched. None
    /// of it stays quiet, as on the ring, and the first sliver fades in from there; the bar gives that its own short stretch
    /// at the start, because on the ring it all happens in the first percent.
    private var scale: some View {
        let colour: (Double) -> Color =
            untouched
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
        .font(Kit.Font.caption.weight(.medium).monospacedDigit())
        .foregroundStyle(Kit.Text.tertiary)
    }
}

// MARK: Search

private struct SearchPanel: View {
    let model: AppModel

    private func open(_ node: UInt32) { model.openFromList(node) }

    /// How many, and where: in the folder in view, or on the map when small files are listed under it too.
    private static func title(_ model: AppModel) -> String {
        let count = model.searchResults.count.formatted()
        if let folder = model.searchFolderName { return "\(count) in \(folder)" }
        return "\(count) \(model.searchesSmallFiles ? "on the map" : "found")"
    }

    var body: some View {
        if let tree = model.tree {
            ScrollView {
                VStack(alignment: .leading, spacing: Kit.rowInset) {
                    // Like the list on the Map, it says when there's more than it shows.
                    PanelTitle(
                        title: Self.title(model),
                        subtitle: model.searchResults.count > 120 ? "Top 120 shown" : nil
                    )
                    .padding(.horizontal, Kit.rowInset)
                    let top = model.searchResults.prefix(120)
                    let biggest = Double(max(top.first.map { tree.totals[Int($0)] } ?? 1, 1))
                    LazyVStack(spacing: 0) {
                        ForEach(top, id: \.self) { node in
                            let n = tree.nodes[Int(node)]
                            let colour = Palette.color(tree.dominantKind(node)).swiftUI
                            ListRow(
                                title: tree.name(node), detail: tree.path(n.parent).map(DiskTree.friendly).flatMap { $0.isEmpty ? nil : $0 },
                                trailing: formatBytes(tree.totals[Int(node)]),
                                markWidth: ListDot.size, share: (Double(tree.totals[Int(node)]) / biggest, colour),
                                onHover: { inside in
                                    if inside { model.highlight(node: node) } else { model.highlight(nodes: Array(model.searchResults.prefix(400))) }
                                },
                                onTap: { open(node) }
                            ) {
                                ListDot(colour: colour)
                            }
                            .named(NamedThing(node), in: model)
                        }
                    }
                    if model.searchesSmallFiles {
                        SmallFilesFound(model: model, tree: tree)
                            .padding(.top, Kit.Space.large)
                    }
                }
                .padding(Kit.panelInset)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .scrollIndicators(.never)
        }
    }
}

/// What the search found among the small files, apart from what's on the map. They aren't on it, so each row lights and
/// opens its folder.
private struct SmallFilesFound: View {
    let model: AppModel
    let tree: DiskTree

    var body: some View {
        let found = model.smallFound
        // None found says so under the heading, so it has no count.
        let trailing = model.smallFilesGap == nil ? found.flatMap { $0.count == 0 ? nil : Self.counted($0) } : nil
        PanelSection(title: "Small Files", trailing: trailing, help: "Files under 1 MiB, too small to be on the map") {
            switch model.smallFilesGap {
            case .onDrive:
                EmptyNote(title: "Only on the Mac", detail: "Small files on the drive aren't searched")
            case .notRead:
                EmptyNote(title: model.isScanning ? "Waiting for the scan" : "Not read yet", detail: model.isScanning ? nil : "Scan Again reads them")
            case nil:
                if let found { rows(found) }
            }
        }
    }

    @ViewBuilder
    private func rows(_ found: SmallFileResults) -> some View {
        if found.count == 0 { EmptyNote(title: "None found") }
        let biggest = Double(max(found.top.first?.bytes ?? 1, 1))
        LazyVStack(spacing: 0) {
            ForEach(found.top, id: \.self) { file in
                let colour = Palette.color(file.kind).swiftUI
                ListRow(
                    title: file.name, detail: DiskTree.friendly(file.folderPath), trailing: formatBytes(file.bytes),
                    markWidth: ListDot.size, share: (Double(file.bytes) / biggest, colour),
                    onHover: { inside in
                        if inside {
                            model.highlight(node: file.onScreen)
                        } else {
                            model.highlight(nodes: Array(model.searchResults.prefix(400)))
                        }
                    },
                    onTap: { model.openFromList(file.onScreen) }
                ) {
                    ListDot(colour: colour)
                }
                .contextMenu {
                    Button("Open") { model.open(file) }
                    Button("Show in Finder") { model.reveal(file) }
                    Button("Copy Path") { model.copyPath(of: file) }
                }
            }
        }
    }

    private static func counted(_ found: SmallFileResults) -> String {
        found.count > SmallFiles.shown ? "\(found.count.formatted()) found · top \(SmallFiles.shown)" : "\(found.count.formatted()) found"
    }
}
