import AppKit
import SwiftUI

/// One category: a heading in its own colour that opens to the things in it. The things are what get ticked.
struct BoxView: View {
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
    private var isLit: Bool { isHovered || model.litBox.isLit(box.id) || model.cursorRow == box.id || (model.recommendedHot && !box.recommended.isEmpty) }

    private var thing: NamedThing {
        let model = model, box = box
        return NamedThing(nodes: box.rows.flatMap(\.nodes), title: box.title, toggle: { model.toggle(box) })
    }

    private var head: some View {
        let state = model.rowStates[box.id] ?? .none
        // Worked out once for the heading: its size, its line and its button all ask.
        let short = state == .none ? nil : model.shortfall(of: box)
        return HStack(alignment: .top, spacing: nested ? 8 : 10) {
            // A category is a heading that opens, in its own colour. What's ticked is the things inside it.
            DisclosureChevron(isOpen: isOpen, size: nested ? 9.5 : 11)
                .foregroundStyle(color.opacity(isLit || isOpen ? 1 : 0.8))
                .frame(width: nested ? 16 : 20, height: nested ? 16 : 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(box.title)
                        .font(.system(size: nested ? 12.5 : 13.5, weight: nested ? .medium : .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if state != .none {
                        // Something in here is selected: all of it, or part. The same tick as the things inside, small.
                        TickMark(state: state, color: color, size: nested ? 11 : 12)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    }
                    size(state, short)
                }
                HStack(spacing: 8) {
                    detail(state, short)
                    Spacer(minLength: 0)
                    if short != nil {
                        Button("Include other copies") {
                            Motion.animate(.snappy(duration: 0.2)) { model.includeOtherCopies(of: box) }
                        }
                        .buttonStyle(.pill(nil, size: .small))
                        .help("Also select the hardlinks and clones elsewhere, so the space is freed. Torrents stop seeding.")
                    }
                }
                .frame(minHeight: 15)
                if !box.isShortlist {
                    BoxBar(model: model, box: box, scale: scale, height: nested ? 3 : 5, isLit: isLit, hovered: { row in
                        guard hoveredRow?.id != row?.id else { return }
                        hoveredRow = row
                        if isHovered { model.point(at: box, row: row) }
                    })
                    .padding(.top, 1)
                }
            }
        }
        .padding(.leading, nested ? 8 : Kit.rowInset)
        .padding(.trailing, Kit.rowInset)
        .padding(.vertical, nested ? 6 : 7)
        .background(RoundedRectangle(cornerRadius: Kit.cardRadius, style: .continuous).fill(state.rowFill(color, isLit: isLit)))
        .contentShape(Rectangle())
        .onHover { inside in
            isHovered = inside
            if inside { model.point(at: box) } else { model.point(at: nil) }
        }
        .onTapGesture {
            Motion.animate(.snappy(duration: 0.2)) {
                if isOpen { model.openBoxes.remove(box.id) } else { model.openBoxes.insert(box.id) }
            }
        }
        .named(thing, in: model)
        .animation(.easeOut(duration: 0.14), value: isLit)
    }

    @ViewBuilder
    private func size(_ state: TickState, _ short: (real: UInt64, wanted: UInt64)?) -> some View {
        if let short {
            Text("\(formatBytes(short.real)) of \(formatBytes(short.wanted))")
                .font(.system(size: nested ? 12 : 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Kit.amber)
        } else if state == .some {
            // What's ticked, and of what's only partly ticked, what really goes.
            let part = box.rows.reduce(UInt64(0)) { sum, row in
                switch model.rowStates[row.id] ?? .none {
                case .all: sum &+ row.gain
                case .some: sum &+ min(model.planNumbers.byItem[row.id] ?? 0, row.gain)
                case .none: sum
                }
            }
            Text(box.isShortlist ? formatBytes(part) : "\(formatBytes(part)) of \(formatBytes(box.bytes))")
                .font(.system(size: nested ? 12 : 13, weight: nested ? .medium : .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(nested ? 0.82 : 0.92))
        } else if !box.isShortlist {
            Text(formatBytes(box.bytes))
                .font(.system(size: nested ? 12 : 13.5, weight: nested ? .medium : .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(nested ? 0.82 : 0.92))
        }
    }

    @ViewBuilder
    private func detail(_ state: TickState, _ short: (real: UInt64, wanted: UInt64)?) -> some View {
        let font = Font.system(size: nested ? 10.5 : 11)
        if let row = hoveredRow {
            (Text(row.title).foregroundStyle(.white.opacity(0.88)) + Text(" · \(formatBytes(row.gain))").foregroundStyle(.white.opacity(0.54)))
                .font(font)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if short != nil {
            Text("Other copies remain")
                .font(font.weight(.medium))
                .foregroundStyle(Kit.amber)
                .lineLimit(1)
        } else if let note = box.note {
            Text(note)
                .font(font.weight(.medium))
                .foregroundStyle(Kit.amber)
                .lineLimit(1)
        } else {
            Text(box.detail)
                .font(font)
                .foregroundStyle(.white.opacity(0.54))
                .lineLimit(1)
        }
    }

    /// Everything in the category at once, said in so many words, for when that's what you mean. It skips what's in use.
    private var selectAll: some View {
        let all = (model.rowStates[box.id] ?? .none) == .all
        return HStack {
            Spacer(minLength: 0)
            Button(all ? "Deselect all" : "Select all") {
                Motion.animate(.snappy(duration: 0.18)) { model.toggle(box) }
            }
            .buttonStyle(.textLink)
            .help(box.rowsATickTakes.count < box.rows.count ? "Skips items in use or set up by hand" : "")
        }
        .padding(.trailing, Kit.rowInset)
        .padding(.top, 1)
        .padding(.bottom, 2)
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
                if box.rows.count > 1, !box.isShortlist { selectAll }
                let limit = showAll ? box.rows.count : 10
                ForEach(box.rows.prefix(limit)) { row in
                    ThingRow(model: model, row: row, color: box.color, box: box)
                }
                if box.rows.count > limit {
                    let rest = box.rows.dropFirst(limit)
                    Button("\(rest.count) more, \(formatBytes(rest.reduce(UInt64(0)) { $0 &+ $1.gain }))") {
                        Motion.animate(.snappy(duration: 0.2)) { showAll = true }
                    }
                    .buttonStyle(.textLink)
                    .padding(.leading, 32)
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
struct BoxBar: View {
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
            // What's pointed at in the panel, or else what the pointer on the ring lights: asked row by row, so only the bar
            // that holds it is drawn again.
            let pointing = model.pointing?.id
            let hotRows = Set(list.compactMap { $0.row?.id }.filter { pointing != nil ? $0 == pointing : model.litRow.isLit($0) })
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
                        let hot = piece.row.map { hotRows.contains($0.id) } ?? false
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
                    Motion.animate(.snappy(duration: 0.18)) { model.toggle(row) }
                } else {
                    Motion.animate(.snappy(duration: 0.18)) { model.toggle(box) }
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

extension AppModel {
    /// Selecting something in a box can give back less than it looks, when another copy of the files stays behind: what it
    /// really frees, and what it looks like it frees. Nil when it frees what it looks like.
    func shortfall(of box: Box) -> (real: UInt64, wanted: UInt64)? {
        let planned = box.rows.filter { (rowStates[$0.id] ?? .none) != .none }
        let wanted = planned.reduce(UInt64(0)) { $0 &+ $1.gain }
        let shared = planned.filter { !$0.otherCopies.isEmpty }
        let promised = shared.reduce(UInt64(0)) { $0 &+ $1.gain }
        let got = shared.reduce(UInt64(0)) { $0 &+ (planNumbers.byItem[$1.id] ?? 0) &+ (planNumbers.byItem[PlanItem.otherCopyID(of: $1.id)] ?? 0) }
        guard promised > 0, Double(got) < Double(promised) * 0.9 else { return nil }
        return (wanted &- (promised &- got), wanted)
    }
}
