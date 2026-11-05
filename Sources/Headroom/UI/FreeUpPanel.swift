import AppKit
import SwiftUI

private let bright = Color(red: 0.5, green: 0.98, blue: 0.7)
private let amber = Color(red: 1, green: 0.74, blue: 0.42)

// MARK: The boxes

/// A short stack of boxes, what you'd miss least on top. Each box selects a whole section, and the ring wears the same colours:
/// one set of data, shown two ways.
struct FreeUpPanel: View {
    let model: AppModel

    var body: some View {
        let boxes = model.boxes
        let scale = max(boxes.map(\.bytes).max() ?? 1, 1)
        let others = model.shownRows.filter { !$0.isPlannable }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    NeedsALook(model: model)
                    ForEach(boxes) { box in
                        BoxView(model: model, box: box, scale: scale)
                            .id(box.id)
                    }
                    if boxes.isEmpty { emptyState }
                    if !others.isEmpty { TuckedAway(model: model, title: "Done another way", promise: "These aren't files you can select.", rows: others).padding(.top, 8) }
                    keptLink
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 9)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .scrollIndicators(.never)
            .onChange(of: model.hotBox) { _, id in
                if let id { withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id) } }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.focus == 0 ? "Nothing here needs doing." : "Nothing in here stands out.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Text("If you know better, click any piece on the ring to pick it yourself.")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var keptLink: some View {
        if !model.plan.kept.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.plan.kept) { kept in
                        HStack {
                            Text(kept.title)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1)
                            Spacer()
                            Button("Suggest again") { model.stopKeeping(kept.id) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("\(model.plan.kept.count) you're keeping")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
    }
}

/// What the last look found, right where you'd see it before pressing Clean, with what you can do about it.
private struct NeedsALook: View {
    let model: AppModel

    var body: some View {
        let items = model.plan.items.filter { !model.problemsToShow(for: $0).isEmpty }
            .sorted { (model.checks[$0.id]?.canGo ?? true ? 1 : 0) < (model.checks[$1.id]?.canGo ?? true ? 1 : 0) }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Needs a look")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(amber)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                ForEach(items) { item in
                    LookRow(model: model, item: item)
                }
            }
            .padding(.bottom, 4)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(amber.opacity(0.08)))
            .padding(.bottom, 6)
        }
    }
}

/// A section that stays folded until you want it.
private struct TuckedAway: View {
    let model: AppModel
    let title: String
    let promise: String
    let rows: [WinRow]
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.22)) { isOpen.toggle() }
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
                    Text(rows.count == 1 ? "1 thing" : "\(rows.count) things")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    Text(formatBytes(rows.reduce(UInt64(0)) { $0 &+ $1.gain }))
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            if isOpen {
                Text(promise)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.leading, 26)
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        ThingRow(model: model, row: row, color: Palette.Box.other)
                    }
                }
            }
        }
    }
}

// MARK: A box

private struct BoxView: View {
    let model: AppModel
    let box: Box
    let scale: UInt64
    var nested = false
    @State private var isHovered = false
    @State private var hoveredRow: WinRow?
    @State private var showAll = false

    var body: some View {
        if box.isOneThing, let row = box.rows.first {
            ThingRow(model: model, row: row, color: box.color, box: box, scale: scale)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                head
                if isOpen { inside }
            }
        }
    }

    private var isOpen: Bool { model.openBoxes.contains(box.id) }
    private var color: Color { box.color.swiftUI }
    private var isLit: Bool { isHovered || model.hotBox == box.id || model.cursorRow == box.id }

    private var thing: NamedThing {
        let model = model, box = box
        return NamedThing(nodes: box.rows.flatMap(\.nodes), title: box.title, toggle: { model.toggle(box) })
    }

    private var head: some View {
        let state = model.rowStates[box.id] ?? .none
        return HStack(alignment: .top, spacing: nested ? 8 : 10) {
            TickMark(state: state, color: color, size: nested ? 16 : 20, isLit: isLit)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(box.title)
                        .font(.system(size: nested ? 12.5 : 13.5, weight: nested ? .medium : .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    size(state)
                }
                HStack(spacing: 8) {
                    detail(state)
                    Spacer(minLength: 0)
                    if state != .none, shortfall() != nil {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { model.includeOtherCopies(of: box) }
                        } label: {
                            Text("Include other copies")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.88))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(.white.opacity(isHovered ? 0.18 : 0.1)))
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .help("The other copies go too, so the space really comes back. A torrent you do this to stops sharing.")
                    }
                    if box.rows.count > 1 || !box.kids.isEmpty { chevron }
                }
                .frame(minHeight: 15)
                BoxBar(model: model, box: box, scale: scale, height: nested ? 3 : 5, isLit: isLit, hovered: { row in
                    guard hoveredRow?.id != row?.id else { return }
                    hoveredRow = row
                    if isHovered { model.point(at: box, row: row) }
                })
                .padding(.top, 1)
            }
        }
        .padding(.leading, nested ? 8 : 11)
        .padding(.trailing, 10)
        .padding(.vertical, nested ? 6 : 7)
        .background(RoundedRectangle(cornerRadius: nested ? 12 : 15, style: .continuous).fill(background(state)))
        .contentShape(Rectangle())
        .onHover { inside in
            isHovered = inside
            if inside { model.point(at: box) } else { model.point(at: nil) }
        }
        .onTapGesture {
            withAnimation(.snappy(duration: 0.18)) { model.toggle(box) }
        }
        .named(thing, in: model)
        .animation(.easeOut(duration: 0.14), value: isLit)
        .help(box.rowsATickTakes.count < box.rows.count ? "A tick leaves out what you set up by hand. Open this to tick those too." : "")
    }

    private func background(_ state: TickState) -> Color {
        switch state {
        case .all: color.opacity(isLit ? 0.2 : 0.14)
        case .some: color.opacity(isLit ? 0.13 : 0.07)
        case .none: .white.opacity(isLit ? 0.07 : 0)
        }
    }

    /// Selecting something can give back less than it looks, when another copy of the files stays behind.
    private func shortfall() -> (real: UInt64, wanted: UInt64)? {
        let planned = box.rows.filter { (model.rowStates[$0.id] ?? .none) != .none }
        let wanted = planned.reduce(UInt64(0)) { $0 &+ $1.gain }
        let shared = planned.filter { !$0.otherCopies.isEmpty }
        let promised = shared.reduce(UInt64(0)) { $0 &+ $1.gain }
        let got = shared.reduce(UInt64(0)) { $0 &+ (model.planBytesByItem[$1.id] ?? 0) &+ (model.planBytesByItem[$1.id + ":other-copy"] ?? 0) }
        guard promised > 0, Double(got) < Double(promised) * 0.9 else { return nil }
        return (wanted &- (promised &- got), wanted)
    }

    @ViewBuilder
    private func size(_ state: TickState) -> some View {
        if state != .none, let short = shortfall() {
            Text("\(formatBytes(short.real)) of \(formatBytes(short.wanted))")
                .font(.system(size: nested ? 12 : 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(amber)
        } else if state == .some {
            // What's ticked, and of what's only partly ticked, what really goes.
            let part = box.rows.reduce(UInt64(0)) { sum, row in
                switch model.rowStates[row.id] ?? .none {
                case .all: sum &+ row.gain
                case .some: sum &+ min(model.planBytesByItem[row.id] ?? 0, row.gain)
                case .none: sum
                }
            }
            Text("\(formatBytes(part)) of \(formatBytes(box.bytes))")
                .font(.system(size: nested ? 12 : 13, weight: nested ? .medium : .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(nested ? 0.82 : 0.92))
        } else {
            Text(formatBytes(box.bytes))
                .font(.system(size: nested ? 12 : 13.5, weight: nested ? .medium : .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(nested ? 0.82 : 0.92))
        }
    }

    @ViewBuilder
    private func detail(_ state: TickState) -> some View {
        let font = Font.system(size: nested ? 10.5 : 11)
        if let row = hoveredRow {
            (Text(row.title).foregroundStyle(.white.opacity(0.88)) + Text(" · \(formatBytes(row.gain))").foregroundStyle(.white.opacity(0.54)))
                .font(font)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if state != .none, shortfall() != nil {
            Text("Other copies stay, so less comes back")
                .font(font.weight(.medium))
                .foregroundStyle(amber)
                .lineLimit(1)
        } else if let note = box.note {
            Text(note)
                .font(font.weight(.medium))
                .foregroundStyle(amber)
                .lineLimit(1)
        } else {
            Text(box.detail)
                .font(font)
                .foregroundStyle(.white.opacity(0.54))
                .lineLimit(1)
        }
    }

    private var chevron: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                if isOpen { model.openBoxes.remove(box.id) } else { model.openBoxes.insert(box.id) }
            }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 9.5, weight: .bold))
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .foregroundStyle(.white.opacity(isHovered || isOpen ? 0.6 : 0.16))
                .frame(width: 18, height: 15)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("See what's in this")
    }

    @ViewBuilder
    private var inside: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !box.kids.isEmpty {
                let most = max(box.kids.map(\.bytes).max() ?? 1, 1)
                ForEach(box.kids) { kid in
                    BoxView(model: model, box: kid, scale: most, nested: true)
                }
            } else {
                let limit = showAll ? box.rows.count : 10
                ForEach(box.rows.prefix(limit)) { row in
                    ThingRow(model: model, row: row, color: box.color, box: box)
                }
                if box.rows.count > limit {
                    let rest = box.rows.dropFirst(limit)
                    Button("and \(rest.count) smaller, \(formatBytes(rest.reduce(UInt64(0)) { $0 &+ $1.gain }))") {
                        withAnimation(.snappy(duration: 0.2)) { showAll = true }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.54))
                    .padding(.leading, 34)
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.leading, nested ? 16 : 22)
        .padding(.top, 1)
        .padding(.bottom, 3)
    }
}

/// How big a box is, to scale with the others, and what it's made of. Each piece is one thing in it: point at one to see where it
/// is on the ring, and click it to take just that.
private struct BoxBar: View {
    let model: AppModel
    let box: Box
    let scale: UInt64
    let height: CGFloat
    let isLit: Bool
    let hovered: (WinRow?) -> Void

    private struct Piece {
        var row: WinRow?
        var rows: [WinRow]
        var start: CGFloat
        var end: CGFloat
    }

    private var pieces: [Piece] {
        let total = max(box.bytes, 1)
        let least = UInt64(Double(scale) * 0.006)
        var out: [Piece] = []
        var at: UInt64 = 0
        var small: [WinRow] = []
        for row in box.rows {
            if row.gain >= least {
                let end = at &+ row.gain
                out.append(Piece(row: row, rows: [row], start: CGFloat(Double(at) / Double(total)), end: CGFloat(Double(end) / Double(total))))
                at = end
            } else {
                small.append(row)
            }
        }
        if !small.isEmpty { out.append(Piece(row: nil, rows: small, start: CGFloat(Double(at) / Double(total)), end: 1)) }
        return out
    }

    var body: some View {
        GeometryReader { g in
            let width = max(g.size.width * CGFloat(Double(box.bytes) / Double(max(scale, 1))), 3)
            let list = pieces
            let color = box.color.swiftUI
            let states = model.rowStates
            let hotRow = model.pointing?.id ?? model.hotRow
            Canvas { context, size in
                let top = (size.height - height) / 2
                let whole = Path(roundedRect: CGRect(x: 0, y: top, width: width, height: height), cornerRadius: height / 2)
                context.clip(to: whole)
                var stripes = Path()
                var selected = Path()
                for piece in list {
                    let x0 = piece.start * width, x1 = max(piece.end * width - (piece.end < 1 ? 1 : 0), x0 + 1)
                    let rect = CGRect(x: x0, y: top, width: x1 - x0, height: height)
                    let on = piece.rows.allSatisfy { states[$0.id] == .all }
                    if on {
                        selected.addRect(rect)
                    } else {
                        let hot = piece.row != nil && piece.row?.id == hotRow
                        context.fill(Path(rect), with: .color(color.opacity(hot ? 1 : (isLit ? 0.92 : 0.62))))
                    }
                }
                if !selected.isEmpty {
                    context.fill(selected, with: .color(color.opacity(0.2)))
                    var x = -height - 7
                    while x < width + height {
                        stripes.move(to: CGPoint(x: x, y: top + height))
                        stripes.addLine(to: CGPoint(x: x + height, y: top))
                        x += 7
                    }
                    context.drawLayer { layer in
                        layer.clip(to: selected)
                        layer.stroke(stripes, with: .color(color), lineWidth: 3.2)
                    }
                }
            }
            .shadow(color: color.opacity(isLit ? 0.55 : 0), radius: isLit ? 5 : 0)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let at):
                    hovered(piece(at: at.x, in: width, of: list)?.row)
                case .ended:
                    hovered(nil)
                }
            }
            .onTapGesture { location in
                // Only a piece of the bar takes one thing. The rest of the line is the box.
                if let row = piece(at: location.x, in: width, of: list)?.row {
                    withAnimation(.snappy(duration: 0.18)) { model.toggle(row) }
                } else {
                    withAnimation(.snappy(duration: 0.18)) { model.toggle(box) }
                }
            }
        }
        .frame(height: height + 9)
    }

    private func piece(at x: CGFloat, in width: CGFloat, of list: [Piece]) -> Piece? {
        guard x >= 0, x <= width, width > 0 else { return nil }
        let share = x / width
        return list.first { share >= $0.start && share <= $0.end }
    }
}

// MARK: A thing

/// The tick for a box or a thing, in its colour, so the list is the ring's legend.
struct TickMark: View {
    let state: TickState
    var color: Color = bright
    var size: CGFloat = 18
    var isLit = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .fill(state == .all ? color : (state == .some ? color.opacity(0.42) : .clear))
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .strokeBorder(color.opacity(state == .none ? (isLit ? 1 : 0.78) : 1), lineWidth: size > 17 ? 1.6 : 1.3)
            if state == .all {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.52, weight: .heavy))
                    .foregroundStyle(.black.opacity(0.82))
            } else if state == .some {
                Image(systemName: "minus")
                    .font(.system(size: size * 0.52, weight: .heavy))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(isLit ? 0.5 : 0), radius: isLit ? 5 : 0)
    }
}

struct AppIcon: View {
    let path: String

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .frame(width: 17, height: 17)
            .padding(.vertical, -3)
    }
}

/// One thing: a series, an app, a folder. Inside an open box it's a small row. Given a `scale`, it's a box of its own.
struct ThingRow: View {
    let model: AppModel
    let row: WinRow
    let color: Lab
    var box: Box? = nil
    var scale: UInt64? = nil
    @State private var isHovered = false

    private var isLarge: Bool { scale != nil }
    private var isOpen: Bool { model.expandedRow == row.id }
    private var isLit: Bool { isHovered || model.hotRow == row.id || (box.map { model.cursorRow == $0.id } ?? false) }

    var body: some View {
        let state = model.rowStates[row.id] ?? .none
        let tint = color.swiftUI
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: isLarge ? 10 : 8) {
                leading(state, tint)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        HStack(spacing: 6) {
                            if let app = row.appPath { AppIcon(path: app) }
                            Text(row.title)
                                .font(.system(size: isLarge ? 13.5 : 12.5, weight: isLarge ? .semibold : .medium))
                                .foregroundStyle(.white.opacity(0.94))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 2)
                        number(state)
                    }
                    HStack(spacing: 6) {
                        line
                        Spacer(minLength: 0)
                        if isHovered || isOpen { actions(state) }
                    }
                    .frame(minHeight: 15)
                    if let scale, let box {
                        BoxBar(model: model, box: box, scale: scale, height: 5, isLit: isLit, hovered: { _ in })
                            .padding(.top, 1)
                    }
                }
            }
            if state != .none, let title = row.otherCopiesTitle { otherCopyRow(title, tint) }
            if state != .none, let title = row.alsoTitle { alsoRow(title, tint) }
            extra
            if isOpen { details(tint) }
        }
        .padding(.leading, isLarge ? 11 : 8)
        .padding(.trailing, isLarge ? 10 : 8)
        .padding(.vertical, isLarge ? 7 : 6)
        .background(RoundedRectangle(cornerRadius: isLarge ? 15 : 12, style: .continuous).fill(background(state, tint)))
        .contentShape(Rectangle())
        .help(row.detail)
        .onHover { inside in
            isHovered = inside
            if let box {
                if inside { model.point(at: box, row: row) } else { model.point(at: nil) }
            } else if inside {
                model.highlight(nodes: row.nodes)
            } else {
                model.highlight(nodes: [])
            }
        }
        .onTapGesture {
            if row.isPlannable { withAnimation(.snappy(duration: 0.18)) { model.toggle(row) } }
        }
        .named(thing, in: model)
        .animation(.easeOut(duration: 0.14), value: isLit)
    }

    private var thing: NamedThing {
        let model = model, row = row
        return NamedThing(nodes: row.nodes, title: row.title, toggle: row.isPlannable ? { model.toggle(row) } : nil)
    }

    private func background(_ state: TickState, _ tint: Color) -> Color {
        switch state {
        case .all: tint.opacity(isLit ? 0.2 : (isLarge ? 0.14 : 0.1))
        case .some: tint.opacity(isLit ? 0.13 : 0.07)
        case .none: .white.opacity(isLit ? 0.07 : 0)
        }
    }

    @ViewBuilder
    private var line: some View {
        let font = Font.system(size: isLarge ? 11 : 10.5)
        if case .move(let folder)? = model.plan.item(row.id)?.step {
            Text("Moves to \(DiskTree.friendly(folder))")
                .font(font.weight(.medium))
                .foregroundStyle(bright.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
        } else if let note = row.inUse ?? row.otherCopiesCaution.map({ _ in "May still be sharing" }) {
            Text(note)
                .font(font.weight(.medium))
                .foregroundStyle(amber.opacity(0.95))
                .lineLimit(1)
        } else if !row.subtitle.isEmpty {
            Text(row.subtitle)
                .font(font)
                .foregroundStyle(.white.opacity(0.54))
                .lineLimit(isOpen ? nil : 1)
                .fixedSize(horizontal: false, vertical: isOpen)
        }
    }

    /// See it for yourself, send it somewhere else instead of the Trash, or keep it.
    @ViewBuilder
    private func actions(_ state: TickState) -> some View {
        HStack(spacing: 4) {
            // A move is one thing going to one place.
            let disks = row.action == .trash && row.nodes.count == 1 ? (model.tree?.path(row.nodes[0]).map(model.otherDisks) ?? []) : []
            if model.plan.item(row.id)?.isMove == true {
                small("Trash instead") { model.setStep(.trash, for: row.id) }
            } else if disks.count == 1, let disk = disks.first {
                small("Move to \(disk.name)") { model.planMove(row, to: disk) }
                    .help(disk.isPluggedIn ? "Copy this to \(disk.name) and check the copy. Only then does this one go to the Trash." : "\(disk.name) isn't plugged in. Plug it in before you clean.")
            } else if disks.count > 1 {
                Menu {
                    ForEach(disks, id: \.self) { disk in
                        Button(disk.isPluggedIn ? "Move to \(disk.name)" : "Move to \(disk.name) (not plugged in)") { model.planMove(row, to: disk) }
                    }
                } label: {
                    label("Move")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if row.isPlannable { small("Keep") { model.keep(row) }.help("Take this out, and don't suggest this again") }
            if !row.nodes.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.22)) { model.toggleExpanded(row) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 16, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("See what's in this")
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(.white.opacity(0.1)))
    }

    private func small(_ text: String, _ action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { action() }
        } label: {
            label(text)
        }
        .buttonStyle(.plain)
    }

    private func number(_ state: TickState) -> some View {
        let font = Font.system(size: isLarge ? 13.5 : 12, weight: isLarge ? .semibold : .medium).monospacedDigit()
        return VStack(alignment: .trailing, spacing: 0) {
            // A selected series whose files are also held somewhere else gives nothing back. Better to say so right here.
            if state != .none, !row.otherCopies.isEmpty, model.plan.covers(row.otherCopiesPath ?? "") == false {
                Text("\(row.bytes < 1_000_000 ? "0 B" : formatBytes(row.bytes)) of \(formatBytes(row.paperBytes))")
                    .font(font)
                    .foregroundStyle(amber)
            } else {
                Text(formatBytes(row.gain))
                    .font(font)
                    .foregroundStyle(.white.opacity(isLarge ? 0.92 : 0.82))
                if row.otherCopies.isEmpty, row.paperBytes > row.bytes, Double(row.bytes) < Double(row.paperBytes) * 0.9 {
                    Text("looks like \(formatBytes(row.paperBytes))")
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(amber.opacity(0.85))
                }
            }
        }
    }

    @ViewBuilder
    private func leading(_ state: TickState, _ tint: Color) -> some View {
        switch row.action {
        case .trash, .uninstall, .emptyTrash: TickMark(state: state, color: tint, size: isLarge ? 20 : 16, isLit: isLit)
        case .restart: symbol("arrow.clockwise.circle")
        case .softwareUpdate: symbol("arrow.down.circle")
        case .openApp: symbol("arrow.up.forward.app")
        case .command: symbol("terminal")
        case .info: symbol("info.circle")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.65))
            .frame(width: 16, height: 16)
    }

    /// The other copy has its own tick, because taking it has its own cost: it stops sharing.
    private func otherCopyRow(_ title: String, _ tint: Color) -> some View {
        let on = model.plan.covers(row.otherCopiesPath ?? "")
        return choice(title, note: row.otherCopiesNote, isOn: on, tint: tint) { model.toggleOtherCopies(of: row) }
    }

    private func alsoRow(_ title: String, _ tint: Color) -> some View {
        choice(title, note: row.alsoNote, isOn: model.plan.item(row.id + ":also") != nil, tint: tint) { model.toggleAlso(of: row) }
    }

    private func choice(_ title: String, note: String?, isOn: Bool, tint: Color, _ action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { action() }
        } label: {
            HStack(alignment: .top, spacing: 7) {
                TickMark(state: isOn ? .all : .none, color: tint, size: 14)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                    if let note {
                        Text(note)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, isLarge ? 30 : 24)
    }

    @ViewBuilder
    private var extra: some View {
        switch row.action {
        case .softwareUpdate:
            Button("Open Software Update") { model.openSoftwareUpdate() }
                .buttonStyle(.glass)
                .controlSize(.small)
                .padding(.leading, 24)
        case .openApp:
            if let id = row.bundleID {
                Button("Open \(row.openAppName ?? row.title)") { model.openApp(bundleID: id) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .padding(.leading, 24)
            }
        case .command:
            if let command = row.command { CommandChip(command: command).padding(.leading, 24) }
        default:
            EmptyView()
        }
    }

    private func details(_ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.detail)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
            if let command = row.command, row.action != .command {
                HStack(spacing: 5) {
                    Text("Or run:")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.5))
                    CommandChip(command: command)
                }
            }
            if row.nodes.count == 1 || row.previewPath != nil, let node = row.nodes.first {
                Button {
                    model.reveal(node)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            InnerList(model: model, nodes: model.innerNodes(of: row), tint: tint)
        }
        .padding(.leading, isLarge ? 30 : 24)
        .padding(.top, 2)
    }
}

private struct CommandChip: View {
    let command: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        } label: {
            HStack(spacing: 5) {
                Text(command)
                    .font(.system(size: 10.5, design: .monospaced))
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9.5))
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help("Copy this command")
    }
}

/// The files and folders inside something, each with its own tick.
private struct InnerList: View {
    let model: AppModel
    let nodes: [UInt32]
    let tint: Color

    var body: some View {
        if let tree = model.tree {
            VStack(spacing: 0) {
                ForEach(nodes.prefix(40), id: \.self) { node in
                    InnerRow(model: model, node: node, name: tree.name(node), path: tree.path(node), bytes: tree.totals[Int(node)], tint: tint)
                }
                if nodes.count > 40 {
                    Text("and \(nodes.count - 40) smaller")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 3)
                }
            }
        }
    }
}

private struct InnerRow: View {
    let model: AppModel
    let node: UInt32
    let name: String
    let path: String?
    let bytes: UInt64
    let tint: Color
    @State private var isHovered = false

    var body: some View {
        // Asked of the list itself, so the tick follows it whichever way it changed.
        let on = path.map(model.plan.covers) ?? false
        HStack(spacing: 7) {
            TickMark(state: on ? .all : .none, color: tint, size: 14)
            Text(name)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(formatBytes(bytes))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.vertical, 1.5)
        .padding(.horizontal, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(isHovered ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { inside in
            isHovered = inside
            model.highlight(nodes: inside ? [node] : [])
        }
        .onTapGesture {
            withAnimation(.snappy(duration: 0.18)) { model.togglePiece(node) }
        }
        .named(NamedThing(node), in: model)
    }
}

// MARK: What needs a look

private struct LookRow: View {
    let model: AppModel
    let item: PlanItem
    @State private var isHovered = false
    @State private var isOpen = false

    private var problems: [CheckProblem] { model.problemsToShow(for: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in fix(problem) }
                action("Keep") { model.keep(item: item) }
                    .help("Take this out, and don't suggest this again")
            }
            ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                Text(problem.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(problem.holdsBack ? amber : .white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isOpen { paths }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(isHovered ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { inside in
            isHovered = inside
            model.highlight(nodes: inside ? (model.planNodes[item.id] ?? []) : [])
        }
        .onTapGesture {
            withAnimation(.snappy(duration: 0.2)) { isOpen.toggle() }
        }
        .named(NamedThing(nodes: model.planNodes[item.id] ?? [], title: item.title), in: model)
    }

    private func action(_ text: String, _ run: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { run() }
        } label: {
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(Capsule().fill(.white.opacity(isHovered ? 0.16 : 0.09)))
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    @ViewBuilder
    private func fix(_ problem: CheckProblem) -> some View {
        switch problem {
        case .appOpen(let name, let id):
            action("Quit \(name)") { model.quit(bundleID: id) }
        case .inUse:
            action("Check again") { model.runChecks() }
        case .changed:
            action("Clean anyway") { model.acceptChange(for: item.id) }
        case .noGain:
            if model.otherCopies[item.id] != nil {
                action("Select that copy too") { model.alsoPlanOtherCopy(for: item) }
            }
        case .couldntGo(_, let askSettings):
            action("Try again") { model.tryAgain(item) }
            if askSettings { action("Open Settings") { model.openAutomationSettings() } }
        default:
            EmptyView()
        }
    }

    private var paths: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(item.paths.prefix(30), id: \.self) { path in
                Text(DiskTree.friendly(path))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if item.paths.count > 30 {
                Text("and \(item.paths.count - 30) more")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
            }
            if !item.excluded.isEmpty {
                Text("Staying: \(item.excluded.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: The next step

/// The button that does what the ticks say. It's green in any window, focused or not, so it never looks switched off when it isn't.
private struct GoButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.42))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(isEnabled ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.15, green: 0.70, blue: 0.47), Color(red: 0.10, green: 0.54, blue: 0.35)], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(.white.opacity(0.08)))
            }
            .overlay {
                if isEnabled {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                }
            }
            .shadow(color: Color(red: 0.12, green: 0.62, blue: 0.40).opacity(isEnabled ? 0.28 : 0), radius: 11, y: 6)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .contentShape(Rectangle())
    }
}

/// The quieter choice beside it.
private struct SoftButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(.white.opacity(configuration.isPressed ? 0.16 : 0.1)))
            .contentShape(Rectangle())
    }
}

/// One place for the next thing to do: plan, review, clean, empty. It stays in the same spot, so a safe cleanup is the same
/// button pressed a few times, with the ring showing what each press did.
struct NextStepBar: View {
    let model: AppModel

    var body: some View {
        Group {
            if let progress = model.cleanProgress {
                cleaning(progress)
            } else if let after = model.afterClean {
                afterClean(after)
            } else if !model.plan.isEmpty {
                planned
            } else if model.lens == .freeUp {
                nothing
            }
        }
        .animation(.snappy(duration: 0.22), value: model.plan.count)
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.03))
    }

    /// Nothing ticked yet, so nothing to do. What you just unticked can come back from here.
    private var nothing: some View {
        bar {
            Button("Nothing selected") {}
                .disabled(true)
                .buttonStyle(GoButton())
            if !model.clearedItems.isEmpty {
                Button("Bring back what you unticked") { withAnimation(.snappy(duration: 0.2)) { model.restoreCleared() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// The one button: it does what the ticks say. Whatever needs a look stays ticked, and stays put.
    private var planned: some View {
        let count = model.plan.count
        let ready = model.readyItems
        let partial = model.tree?.isPartial == true
        let onlyTrash = model.plan.items.allSatisfy(\.isEmptyTrash)
        let label = partial ? "Finishing the scan first"
            : ready.isEmpty ? "Nothing is ready yet"
            : onlyTrash ? "Empty the Trash: \(formatBytes(cleanBytes(ready)))"
            : ready.count == count ? "Clean \(formatBytes(model.planBytes))"
            : "Clean \(ready.count) of \(count): \(formatBytes(cleanBytes(ready)))"
        return bar {
            if model.lens == .freeUp {
                Button {
                    model.cleanNow()
                } label: {
                    Text(label)
                        .contentTransition(.numericText())
                }
                .disabled(partial || ready.isEmpty)
                .buttonStyle(GoButton())
                .animation(.snappy(duration: 0.25), value: model.planBytes)
                HStack(spacing: 6) {
                    if !onlyTrash {
                        Text("Everything goes to the Trash first, so you can undo this.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    Spacer(minLength: 0)
                    Button("Untick all") { withAnimation(.snappy(duration: 0.2)) { model.clearPlan() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize()
                }
            } else {
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { model.setLens(.freeUp) }
                } label: {
                    Text("\(formatBytes(model.planBytes)) selected in Free Up")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }

    private func cleanBytes(_ items: [PlanItem]) -> UInt64 {
        items.reduce(0) { $0 &+ (model.planBytesByItem[$1.id] ?? $1.lastKnownBytes) }
    }

    private func cleaning(_ progress: CleanProgress) -> some View {
        bar {
            HStack {
                Text(progress.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if progress.total > 0 {
                    Text("\(progress.done) of \(progress.total)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            ProgressView(value: progressShare(progress))
                .tint(Palette.reclaim(.rebuilds).swiftUI)
            Button("Stop") { model.stopCleaning() }
                .buttonStyle(.glass)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        }
    }

    private func progressShare(_ progress: CleanProgress) -> Double {
        guard progress.total > 0 else { return 0 }
        var share = Double(progress.done) / Double(progress.total)
        if progress.bytesTotal > 0 { share += Double(progress.bytesDone) / Double(progress.bytesTotal) / Double(progress.total) }
        return min(share, 1)
    }

    @ViewBuilder
    private func afterClean(_ after: AfterClean) -> some View {
        switch after.state {
        case .waiting:
            bar {
                HStack(alignment: .firstTextBaseline) {
                    Text("In the Trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    Text(formatBytes(after.bytes))
                        .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Palette.reclaim(.rebuilds).swiftUI)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(waitingText(after))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Open Trash") { model.openTrash() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize()
                }
                HStack(spacing: 8) {
                    Button {
                        model.emptyNow()
                    } label: {
                        Text(after.includesOldTrash ? "Empty the Trash" : "Delete \(after.things.count == 1 ? "this" : "these") for good")
                    }
                    .buttonStyle(GoButton())
                    Button(after.things.isEmpty ? "Cancel" : "Undo") { model.undoClean() }
                        .buttonStyle(SoftButton())
                        .fixedSize()
                }
                HStack(spacing: 6) {
                    if !model.plan.isEmpty {
                        Text(model.plan.count == 1 ? "1 thing is still selected." : "\(model.plan.count) things are still selected.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer(minLength: 0)
                    Button("Not now") { withAnimation(.snappy(duration: 0.2)) { model.leaveInTrash() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .help("Leave everything in the Trash for now. You can still put things back from there yourself, or empty the Trash later.")
                }
            }
        case .emptying:
            bar {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Emptying")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        case .done(let got):
            bar {
                HStack(alignment: .firstTextBaseline) {
                    Text("You got back")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    Text(formatBytes(got))
                        .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(bright)
                }
                if after.notDeleted > 0 {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(after.notDeleted == 1 ? "1 thing is still in the Trash, because macOS only lets the Finder delete it. Empty the Trash there to finish." : "\(after.notDeleted) things are still in the Trash, because macOS only lets the Finder delete them. Empty the Trash there to finish.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(amber)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Open Trash") { model.openTrash() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                            .fixedSize()
                    }
                }
                if Double(got) < Double(after.bytes) * 0.93 {
                    Text("\(formatBytes(after.bytes &- min(after.bytes, got))) is still held by a macOS snapshot or another copy. A snapshot goes by itself in time.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func waitingText(_ after: AfterClean) -> String {
        var text = "Free space stays the same until the Trash is emptied. You can still undo this."
        if after.includesOldTrash, after.oldTrashBytes > 0 { text = "Emptying also removes the \(formatBytes(after.oldTrashBytes)) that was already there. Until then, you can still undo this." }
        if after.failed > 0 { text += " \(after.failed) couldn't be moved." }
        if after.heldBack > 0 { text += " \(after.heldBack) stayed, and are still selected." }
        return text
    }
}

// MARK: On the Map

/// What's worth doing in the picture you're looking at. The rest is one click away.
struct WorthDoing: View {
    let model: AppModel

    var body: some View {
        let rows = model.shownRows.filter(\.isPlannable).sorted { $0.gain > $1.gain }.prefix(3)
        let insight = model.insightLine()
        if insight != nil || !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let insight {
                    Text(insight)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !rows.isEmpty, model.focus != 0 {
                    SectionHeading(text: "Worth a look")
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                    VStack(spacing: 0) {
                        ForEach(Array(rows)) { row in
                            ThingRow(model: model, row: row, color: model.rowColours[row.id] ?? Palette.Box.other)
                        }
                    }
                    .padding(.horizontal, -2)
                    Button {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { model.setLens(.freeUp) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                            Text("See everything in Free Up")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(bright)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                }
            }
        }
    }
}
