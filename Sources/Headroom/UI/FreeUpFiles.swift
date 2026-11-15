import AppKit
import SwiftUI

/// How many files an opened row lists. The rest are counted in one line under them.
private let mostFilesListed = 40

/// The line under a list that was cut short.
private struct MoreLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 3)
    }
}

/// One file or folder in an opened row: its tick, its name, its size once that's known, and whatever comes after.
private struct FileLine<Trailing: View>: View {
    let name: String
    let bytes: UInt64?
    let isOn: Bool
    let tint: Color
    var isFolder = false
    let isHovered: Bool
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 7) {
            TickMark(state: isOn ? .all : .none, color: tint, size: 14)
            if isFolder {
                Image(systemName: "folder.fill")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Text(name)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let bytes {
                Text(formatBytes(bytes))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
            trailing
        }
        .padding(.vertical, 1.5)
        .padding(.horizontal, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(isHovered ? 0.07 : 0)))
        .contentShape(Rectangle())
    }
}

/// The files and folders inside something, each with its own tick.
struct InnerList: View {
    let model: AppModel
    let nodes: [UInt32]
    let tint: Color

    var body: some View {
        if let tree = model.tree {
            VStack(spacing: 0) {
                ForEach(nodes.prefix(mostFilesListed), id: \.self) { node in
                    InnerRow(model: model, node: node, name: tree.name(node), path: tree.path(node).map(PathMath.visible), bytes: tree.totals[Int(node)], tint: tint)
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
            FileLine(name: name, bytes: bytes, isOn: on, tint: tint, isFolder: isFolder, isHovered: isHovered) {
                if isFolder {
                    Button {
                        Motion.animate(.snappy(duration: 0.2)) { isOpen.toggle() }
                    } label: {
                        DisclosureChevron(isOpen: isOpen, size: 8.5)
                            .foregroundStyle(.white.opacity(isHovered || isOpen ? 0.7 : 0.28))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isOpen ? "Hide contents" : "Show contents")
                }
            }
            .onHover { inside in
                isHovered = inside
                // Off this file and still on the row it's in: the row's files light again, as before the pointer came here.
                model.highlight(nodes: inside ? [node] : PointedAt.litAfterLeaving(inside: enclosing))
            }
            .onTapGesture {
                Motion.animate(.snappy(duration: 0.18)) { model.togglePiece(node) }
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
        VStack(spacing: 0) {
            ForEach(row.extraPaths.prefix(mostFilesListed), id: \.self) { path in
                LooseRow(model: model, row: row, path: path, tint: tint)
            }
            if row.extraPaths.count > mostFilesListed { MoreLine(text: "\(row.extraPaths.count - mostFilesListed) more") }
        }
    }
}

private struct LooseRow: View {
    let model: AppModel
    let row: WinRow
    let path: String
    let tint: Color
    @State private var isHovered = false
    @State private var bytes: UInt64?

    var body: some View {
        FileLine(name: (path as NSString).lastPathComponent, bytes: bytes, isOn: model.plan.covers(PathMath.visible(path)), tint: tint, isHovered: isHovered) {}
            .onHover { isHovered = $0 }
            .onTapGesture {
                Motion.animate(.snappy(duration: 0.18)) { model.togglePath(path, of: row) }
            }
            .task(id: path) {
                let path = path
                bytes = await Task.detached(priority: .utility) {
                    (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize).map(UInt64.init)
                }.value
            }
    }
}
