import AppKit
import Charts
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

struct ChangesWindow: View {
    let model: AppModel

    private var windows: [ChangeWindow] { [.lastScan, .days(1), .days(7), .days(30)] }

    private var untouched: Bool { model.changeWindow.isUntouched }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            picker(windows)
            HStack(spacing: 8) {
                Text("Untouched")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize()
                    .padding(.leading, 10)
                picker(ChangeWindow.untouchedWindows)
            }
            scale
                .padding(.leading, 10)
                .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
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
}

// MARK: Search

struct SearchPanel: View {
    let model: AppModel

    private func open(_ node: UInt32) { model.openFromList(node) }

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
