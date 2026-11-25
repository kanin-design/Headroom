import SwiftUI

/// How many files an opened row lists. The rest are counted in one line under them.
private let mostFilesListed = 40

/// The files and folders inside something, each with its own tick.
struct InnerList: View {
    let model: AppModel
    let nodes: [UInt32]
    let tint: Color

    var body: some View {
        if let tree = model.tree {
            let shown = Array(nodes.prefix(mostFilesListed))
            // Names cut as the ring cuts them, among the files listed (DESIGN.md, Names).
            let forms = ListNames.forms(shown.map { tree.name($0) })
            VStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element) { index, node in
                    InnerRow(
                        model: model, node: node, name: tree.name(node), titles: forms[index], path: tree.path(node).map(PathMath.visible),
                        bytes: tree.totals[Int(node)], tint: tint)
                }
                if nodes.count > mostFilesListed { MoreLine(text: "\(nodes.count - mostFilesListed) more, smaller") }
            }
        }
    }
}

/// One file or folder inside something, with its own tick. A folder opens to what's in it, and so on down.
private struct InnerRow: View {
    let model: AppModel
    let node: UInt32
    let name: String
    /// Shorter ways to write the name, worked out among the list's.
    let titles: [String]
    let path: String?
    let bytes: UInt64
    let tint: Color
    /// The row, or the folder, this one is listed in.
    @Environment(\.enclosingThing) private var enclosing
    @State private var isHovered = false
    @State private var isOpen = false

    private var children: [UInt32] {
        guard let tree = model.tree else { return [] }
        return tree.children(node).filter { tree.totals[Int($0)] > 0 }.sorted { tree.totals[Int($0)] > tree.totals[Int($1)] }
    }

    var body: some View {
        // Asked of the list itself, so the tick follows it whichever way it changed.
        let on = path.map(model.plan.covers) ?? false
        let isFolder = model.tree.map { $0.nodes[Int(node)].has(NodeFlag.directory) && $0.nodes[Int(node)].firstChild != 0 } ?? false
        VStack(spacing: 0) {
            ListRow(
                title: name, titles: titles, density: .compact, markWidth: nil,
                onHover: { inside in
                    isHovered = inside
                    // Off this file and still on the row it's in: the row's files light again, as before the pointer came here.
                    model.highlight(nodes: inside ? [node] : PointedAt.litAfterLeaving(inside: enclosing))
                },
                onTap: {
                    Motion.animate(.snappy(duration: 0.18)) { model.togglePiece(node) }
                }
            ) {
                InnerMark(isOn: on, tint: tint, isFolder: isFolder)
            } trailing: {
                HStack(spacing: 7) {
                    ListRowValue(text: formatBytes(bytes), colour: Kit.Text.tertiary, compact: true)
                    if isFolder {
                        DisclosureButton(isOpen: isOpen, isLit: isHovered, help: ("Hide contents", "Show contents"), width: 14) { isOpen.toggle() }
                    }
                }
            }
            .named(NamedThing(node), in: model)
            if isOpen {
                InnerList(model: model, nodes: children, tint: tint)
                    .padding(.leading, 16)
            }
        }
    }
}

/// The files in a row that are too small to be on the map, such as screenshots, each with its own tick.
struct LooseList: View {
    let model: AppModel
    let row: WinRow
    let tint: Color

    var body: some View {
        let shown = Array(row.extraPaths.prefix(mostFilesListed))
        let forms = ListNames.forms(shown.map { ($0 as NSString).lastPathComponent })
        VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, path in
                LooseRow(model: model, row: row, path: path, titles: forms[index], tint: tint)
            }
            if row.extraPaths.count > mostFilesListed { MoreLine(text: "\(row.extraPaths.count - mostFilesListed) more") }
        }
    }
}

private struct LooseRow: View {
    let model: AppModel
    let row: WinRow
    let path: String
    /// Shorter ways to write its name, worked out among the list's.
    let titles: [String]
    let tint: Color
    @State private var bytes: UInt64?

    var body: some View {
        // Its size is read from the disk, so it's there once that's done.
        ListRow(
            title: (path as NSString).lastPathComponent, titles: titles, trailing: bytes.map(formatBytes) ?? "",
            trailingColour: Kit.Text.tertiary,
            density: .compact, markWidth: nil,
            onTap: {
                Motion.animate(.snappy(duration: 0.18)) { model.togglePath(path, of: row) }
            }
        ) {
            InnerMark(isOn: model.plan.covers(PathMath.visible(path)), tint: tint)
        }
        .task(id: path) {
            let path = path
            bytes = await Task.detached(priority: .utility) {
                (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize).map(UInt64.init)
            }.value
        }
    }
}

/// What a file inside an opened row is marked with: its tick, and a folder's icon after it.
private struct InnerMark: View {
    let isOn: Bool
    let tint: Color
    var isFolder = false

    var body: some View {
        HStack(spacing: 7) {
            TickMark(isOn, color: tint)
            if isFolder {
                Image(systemName: "folder.fill")
                    .font(Kit.Font.caption)
                    .foregroundStyle(Kit.Text.tertiary)
            }
        }
    }
}
