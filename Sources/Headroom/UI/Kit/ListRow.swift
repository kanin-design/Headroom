import AppKit
import SunburstKit
import SwiftUI

/// One line in any list: a mark in a slot of its own (a tick, a step, a dot, an icon), a name, a line under it of where it is
/// or what's wrong, a warning, and at the end a value. Backup's files, a search's finds, a folder's contents in the card,
/// Copies' folded sets and the files inside an opened thing in Free Up are all this row: only the mark and the words differ.
struct ListRow<Mark: View, Trailing: View>: View {
    /// A list's own rows, or the files listed inside an opened row: a size smaller, quieter, and closer together.
    enum Density {
        case regular, compact
    }

    let title: String
    /// Shorter ways to write the title, longest first, after the title itself: the longest that fits is used.
    var titles: [String] = []
    var detail: String? = nil
    /// Shorter ways to write the detail, as for the title.
    var details: [String] = []
    var warning: String? = nil
    /// Not started yet, or not here: the name is quieter.
    var isQuiet = false
    /// Where the keyboard is, in a list you can walk through.
    var isLit = false
    var density = Density.regular
    /// How wide the mark's slot is: the same for every row of a list, so names line up. Nil: as wide as the mark.
    var markWidth: CGFloat? = Kit.markSlot
    /// A hairline under the row: its share of the biggest in the list, in a colour.
    var share: (fraction: Double, colour: Color)? = nil
    var onHover: ((Bool) -> Void)? = nil
    var onTap: (() -> Void)? = nil
    @ViewBuilder let mark: () -> Mark
    @ViewBuilder let trailing: () -> Trailing
    @State private var isHovered = false

    private var compact: Bool { density == .compact }
    private var spacing: CGFloat { compact ? 7 : Kit.Space.regular }

    var body: some View {
        VStack(alignment: .leading, spacing: Kit.Space.small) {
            HStack(alignment: compact ? .center : .top, spacing: spacing) {
                mark()
                    .frame(width: markWidth, height: compact ? nil : 16)
                VStack(alignment: .leading, spacing: Kit.Space.hairline) {
                    FittedText(forms: titles.count > 1 ? titles : [title], font: compact ? FittedText.detail : FittedText.title)
                        .foregroundStyle(isQuiet ? Kit.Text.tertiary : (compact ? Kit.Text.secondary : Kit.Text.primary))
                    if let detail {
                        FittedText(forms: details.count > 1 ? details : [detail], font: FittedText.detail)
                            .foregroundStyle(Kit.Text.tertiary)
                    }
                    if let warning {
                        Text(warning)
                            .font(Kit.Font.detail)
                            .foregroundStyle(Kit.amber)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                // All the room up to the value, which the name and the line under it are written to fit.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, compact ? Kit.Space.small : Kit.Space.large)
                trailing()
                    .padding(.top, compact ? 0 : Kit.Space.hairline)
            }
            if let share {
                ShareLine(fraction: share.fraction, colour: share.colour)
                    .padding(.leading, (markWidth ?? Kit.markSlot) + spacing)
            }
        }
        .padding(.horizontal, compact ? 3 : Kit.rowInset)
        // A row with a hairline under it has a little more air, so the hairline reads as the row's.
        .padding(.vertical, compact ? 1.5 : (share == nil ? Kit.Space.small : Kit.Space.medium))
        .background(
            RoundedRectangle(cornerRadius: compact ? Kit.Radius.small : Kit.Radius.row, style: .continuous)
                .fill((isHovered && onTap != nil) || isLit ? Kit.Fill.hover : .clear)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            isHovered = inside
            onHover?(inside)
        }
        .onTapGesture { onTap?() }
        .accessibilityAddTraits(onTap == nil ? [] : .isButton)
    }
}

extension ListRow where Trailing == ListRowValue {
    /// A row whose end is a value in words: a size, or how a file is getting on.
    init(
        title: String, titles: [String] = [], detail: String? = nil, details: [String] = [], warning: String? = nil, trailing: String,
        trailingColour: Color = Kit.Text.secondary, isQuiet: Bool = false, isLit: Bool = false, density: Density = .regular,
        markWidth: CGFloat? = Kit.markSlot, share: (fraction: Double, colour: Color)? = nil, onHover: ((Bool) -> Void)? = nil,
        onTap: (() -> Void)? = nil, @ViewBuilder mark: @escaping () -> Mark
    ) {
        self.init(
            title: title, titles: titles, detail: detail, details: details, warning: warning, isQuiet: isQuiet, isLit: isLit,
            density: density, markWidth: markWidth, share: share, onHover: onHover, onTap: onTap, mark: mark
        ) {
            ListRowValue(text: trailing, colour: trailingColour, compact: density == .compact)
        }
    }
}

/// The value at a row's end: a size, with digits of equal width so a column of them lines up.
struct ListRowValue: View {
    let text: String
    let colour: Color
    let compact: Bool

    var body: some View {
        Text(text)
            .font(compact ? Kit.Font.detail.monospacedDigit() : Kit.Font.number)
            .foregroundStyle(colour)
            .lineLimit(1)
    }
}

/// A row's share of the biggest in its list, as a hairline in its colour. One shape that draws its part of the row's
/// width: read with a `GeometryReader`, the width cost every row a layout of its own each time the list was made.
private struct ShareLine: View {
    let fraction: Double
    let colour: Color
    @Environment(\.displayScale) private var scale

    var body: some View {
        Hairline(fraction: fraction, scale: scale)
            .fill(colour.opacity(0.75))
            .frame(height: 2)
    }

    private struct Hairline: Shape {
        let fraction: Double
        let scale: CGFloat

        func path(in rect: CGRect) -> Path {
            // To a whole pixel, as a view of that width is laid out.
            let width = (max(rect.width * min(fraction, 1), 2) * scale).rounded() / scale
            return Capsule().path(in: CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height))
        }
    }
}

/// The dot a row of the map's things wears, in the colour its piece has on the ring.
struct ListDot: View {
    let colour: Color

    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: ListDot.size, height: ListDot.size)
    }

    /// Its slot: a list of dots lines its names up a dot's width in, not a tick's.
    static let size: CGFloat = 7
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

    /// A name in a list, and the line under it: `Kit.Font.name` and `Kit.Font.detail`, as AppKit measures them.
    static let title = NSFont.systemFont(ofSize: Kit.Font.Size.body, weight: .medium)
    /// The title of a box at the top of a list: `Kit.Font.headline`.
    static let headline = NSFont.systemFont(ofSize: Kit.Font.Size.headline, weight: .semibold)
    static let detail = NSFont.systemFont(ofSize: Kit.Font.Size.detail)

    var body: some View {
        let line = Text(chosen)
            .font(Font(font as CTFont))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
        if forms.count > 1 {
            line.onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                room = $0
            }
        } else {
            line
        }
    }

    private var chosen: String {
        guard forms.count > 1, let room else { return forms.first ?? "" }
        return forms.first { Self.width($0, font) <= room } ?? forms[forms.count - 1]
    }

    /// A text's width in a font. The fonts are the few above, so each is told apart by which one it is, not by its name
    /// written out: making that text for every look cost more than the look.
    private struct Measured: Hashable {
        let font: ObjectIdentifier
        let text: String
    }

    private static var widths: [Measured: CGFloat] = [:]

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        let key = Measured(font: ObjectIdentifier(font), text: text)
        if let known = widths[key] { return known }
        if widths.count > 4000 { widths.removeAll(keepingCapacity: true) }
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

    /// The folder a file is in, as a path you'd say, then shorter ways to write it: the line under a file's name.
    static func folderForms(ofFile path: String) -> [String] {
        folderForms(DiskTree.friendly((path as NSString).deletingLastPathComponent))
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

    /// For names from many folders, such as a search's finds, in order: each cut as the ring cuts it, among the others in
    /// the same folder and leaving out what that folder and the one around it say. Grouped this way, a season's episodes
    /// listed beside their show's folder and other files of the same name still read `Show…S01E02…mkv`.
    static func forms(_ names: [String], inFolders folders: [String]) -> [[String]] {
        var groups: [String: [Int]] = [:]
        for (i, folder) in folders.enumerated() { groups[folder, default: []].append(i) }
        var result = names.map { [$0] }
        for (folder, members) in groups {
            let around = folder.split(separator: "/").suffix(2).map(String.init)
            for (i, list) in zip(members, forms(members.map { names[$0] }, around: around)) { result[i] = list }
        }
        return result
    }

    /// Each item's name cut where the others in its folder say the same, by the item.
    static func forms<Item: Identifiable>(in groups: [FolderGroup<Item>], name: (Item) -> String) -> [Item.ID: [String]] {
        var forms: [Item.ID: [String]] = [:]
        for group in groups {
            let lists = Self.forms(group.items.map(name), around: [(group.folder as NSString).lastPathComponent])
            for (item, list) in zip(group.items, lists) { forms[item.id] = list }
        }
        return forms
    }
}

/// A group in `FolderGroups`: the folder, what's in it, and what its line says at the end. A flagged group has something
/// that needs a look, and is open from the start.
struct FolderGroup<Item: Identifiable> {
    let folder: String
    let items: [Item]
    let trailing: String
    var trailingColour: Color = Kit.Text.secondary
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
    private static var indent: CGFloat { Kit.markSlot + Kit.Space.regular }

    var body: some View {
        VStack(alignment: .leading, spacing: Kit.Space.hairline) {
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

    /// Not a `ListRow`: a folder's line has two marks, its arrow and its icon, so its files' marks line up under the icon.
    private func header(_ group: FolderGroup<Item>, open: Bool) -> some View {
        Button {
            Motion.animate(.snappy(duration: 0.18)) {
                if toggled.contains(group.folder) { toggled.remove(group.folder) } else { toggled.insert(group.folder) }
            }
        } label: {
            HStack(spacing: Kit.Space.regular) {
                DisclosureChevron(isOpen: open)
                    .foregroundStyle(Kit.Text.tertiary)
                    .frame(width: Kit.markSlot)
                Image(systemName: "folder.fill")
                    .font(Kit.Font.detail)
                    .foregroundStyle(Kit.blue.opacity(0.8))
                    .frame(width: Kit.markSlot)
                FittedText(forms: ListNames.folderForms(folderName(group.folder)), font: FittedText.title)
                    .padding(.trailing, Kit.Space.section)
                if group.isFlagged {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Kit.Font.caption)
                        .foregroundStyle(Kit.amber)
                }
                Text(group.trailing)
                    .font(Kit.Font.detail.monospacedDigit())
                    .foregroundStyle(group.trailingColour)
            }
            .padding(.horizontal, Kit.rowInset)
            .padding(.vertical, Kit.Space.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(open ? "Hide files" : "Show files")
    }
}
