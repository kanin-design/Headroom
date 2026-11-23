import AppKit
import SunburstKit
import SwiftUI

/// One file in a list: a mark in a slot of its own (a tick, a step, an icon), its name, a line under it of where it is or what's
/// wrong, and at the end its size or how it's getting on, in a colour. Selected files and files being moved are the same row
/// with a different mark and a different word at the end.
struct FileRow<Mark: View>: View {
    let title: String
    /// Shorter ways to write the title, longest first, after the title itself: the longest that fits is used.
    var titles: [String] = []
    var detail: String? = nil
    /// Shorter ways to write the detail, as for the title.
    var details: [String] = []
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
                FittedText(forms: titles.count > 1 ? titles : [title], font: FittedText.title)
                    .foregroundStyle(.white.opacity(isQuiet ? 0.5 : 0.92))
                if let detail {
                    FittedText(forms: details.count > 1 ? details : [detail], font: FittedText.detail)
                        .foregroundStyle(.white.opacity(0.5))
                }
                if let warning {
                    Text(warning)
                        .font(.system(size: 11))
                        .foregroundStyle(Kit.amber)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            // All the room up to the size, which the name and the line under it are written to fit.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 12)
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

/// One line written the longest way that fits the room it's given, which is all of it: each of `forms`, longest first,
/// then the last cut once more in the middle. It's one text whichever form it is: the forms are measured with the font,
/// not each laid out, which in a list of eighty rows held up switching to Backup for a quarter of a second at a time.
struct FittedText: View {
    let forms: [String]
    /// The font it's drawn in, and measured with.
    let font: NSFont
    /// How wide the line is, once it's been laid out.
    @State private var room: CGFloat?

    static let title = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let detail = NSFont.systemFont(ofSize: 11)

    var body: some View {
        let line = Text(chosen)
            .font(Font(font as CTFont))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
        if forms.count > 1 {
            line.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { room = $0 }
        } else {
            line
        }
    }

    private var chosen: String {
        guard forms.count > 1, let room else { return forms.first ?? "" }
        return forms.first { Self.width($0, font) <= room } ?? forms[forms.count - 1]
    }

    private static var widths: [String: CGFloat] = [:]

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        let key = "\(font.pointSize) \(font.fontName) \(text)"
        if let known = widths[key] { return known }
        if widths.count > 4000 { widths.removeAll() }
        let w = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        widths[key] = w
        return w
    }
}

/// The names in a list written as the ring writes them: each cut with "…" where its neighbours in the list say the same, so
/// what tells them apart is what's left (DESIGN.md, *Names*). Worked out once for each list.
@MainActor
enum ListNames {
    private static var known: [[String]: [[String]]] = [:]

    /// A folder's path, then shorter ways to write it, cut only between folders: the folders nearest the top go first, so
    /// what's left says where it is. "~/Media/TV/Show (2021)/Season 01" can be "~/…/Show (2021)/Season 01", then
    /// "~/…/Season 01".
    static func folderForms(_ path: String) -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 2 else { return [path] }
        var forms = [path]
        for keep in stride(from: parts.count - 2, through: 1, by: -1) {
            forms.append(([parts[0], "…"] + parts.suffix(keep)).joined(separator: "/"))
        }
        return forms
    }

    /// For each name, in order, its forms from the whole name down. `around` is the names of the folders they're in.
    static func forms(_ names: [String], around: [String] = []) -> [[String]] {
        let key = around + ["/"] + names
        if let hit = known[key] { return hit }
        if known.count > 64 { known.removeAll() }
        let made = ShortNames.forms(of: names, around: around)
        known[key] = made
        return made
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
                FittedText(forms: ListNames.folderForms(folderName(group.folder)), font: FittedText.title)
                    .padding(.trailing, 14)
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
