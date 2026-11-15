import SwiftUI

/// One file in a list: a mark in a slot of its own (a tick, a step, an icon), its name, a line under it of where it is or what's
/// wrong, and at the end its size or how it's getting on, in a colour. Selected files and files being moved are the same row
/// with a different mark and a different word at the end.
struct FileRow<Mark: View>: View {
    let title: String
    var detail: String? = nil
    var warning: String? = nil
    let trailing: String
    var trailingColour: Color = .white.opacity(0.7)
    /// Not started yet, or not here: the name is quieter.
    var isQuiet = false
    var onTap: (() -> Void)? = nil
    @ViewBuilder let mark: () -> Mark
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            mark()
                .frame(width: Kit.markSlot, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(isQuiet ? 0.5 : 0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let warning {
                    Text(warning)
                        .font(.system(size: 11))
                        .foregroundStyle(Kit.amber)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            Text(trailing)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(trailingColour)
                .lineLimit(1)
                .padding(.top, 1)
        }
        .padding(.horizontal, Kit.rowInset)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Kit.rowRadius, style: .continuous).fill(isHovered && onTap != nil ? Kit.hoverFill : .clear))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { onTap?() }
    }
}

/// A group in `FolderGroups`: the folder, what's in it, and what its line says at the end. A flagged group has something
/// that needs a look, and is open from the start.
struct FolderGroup<Item: Identifiable> {
    let folder: String
    let items: [Item]
    let trailing: String
    var trailingColour: Color = .white.opacity(0.6)
    var isFlagged = false
}

/// Files a group for each folder: where they are said once, with how many and how much, then the files under it. Open when
/// there's little in all of it, or where something needs a look; a click on a folder opens or closes it.
struct FolderGroups<Item: Identifiable, Row: View>: View {
    let groups: [FolderGroup<Item>]
    let openAtFirst: Bool
    /// How a folder is named: as a path you'd say, unless something better is given.
    var folderName: (String) -> String = { DiskTree.friendly($0) }
    /// What a right-click on a folder offers.
    var menu: ((FolderGroup<Item>) -> AnyView)? = nil
    @ViewBuilder let row: (Item) -> Row
    @State private var toggled: Set<String> = []

    /// How far a row is in from its folder: past the folder's arrow, so its mark is under the folder's icon.
    static var indent: CGFloat { Kit.markSlot + 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(groups, id: \.folder) { group in
                let open = (openAtFirst || group.isFlagged) != toggled.contains(group.folder)
                if let menu {
                    header(group, open: open).contextMenu { menu(group) }
                } else {
                    header(group, open: open)
                }
                if open {
                    ForEach(group.items) { item in
                        row(item)
                            .padding(.leading, Self.indent)
                    }
                }
            }
        }
    }

    private func header(_ group: FolderGroup<Item>, open: Bool) -> some View {
        Button {
            Motion.animate(.snappy(duration: 0.18)) {
                if toggled.contains(group.folder) { toggled.remove(group.folder) } else { toggled.insert(group.folder) }
            }
        } label: {
            HStack(spacing: 8) {
                DisclosureChevron(isOpen: open, size: 9)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: Kit.markSlot)
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Kit.blue.opacity(0.8))
                    .frame(width: Kit.markSlot)
                Text(folderName(group.folder))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if group.isFlagged {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Kit.amber)
                }
                Text(group.trailing)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(group.trailingColour)
            }
            .padding(.horizontal, Kit.rowInset)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(open ? "Hide files" : "Show files")
    }
}
