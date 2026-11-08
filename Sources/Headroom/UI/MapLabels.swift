import AppKit
import SwiftUI

/// A name on the map: inside a piece if it fits, otherwise out at the side with a thin line to its piece.
struct MapLabel: Identifiable, Equatable {
    enum Place { case inside, left, right }
    var id: UInt64
    var pieceIndex: Int
    var node: UInt32
    var title: String
    var value: String
    var position: CGPoint
    var anchor: CGPoint
    var elbow: CGPoint
    var place: Place
    var dark: Bool
    var large: Bool
}

enum LabelPlacer {
    private static let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Where a box of this size fits inside a piece: its middle if possible, otherwise slid along the arc to where the
    /// ring runs closer to level. A name that fits nearby is better than one out at the side.
    private static func fit(w: CGFloat, h: CGFloat, piece p: Piece, radius R: CGFloat) -> CGFloat? {
        let mid = CGFloat(p.midAngle)
        let sweep = CGFloat(p.sweep)
        // A big piece's name belongs on it, so those look harder for a place.
        let big = p.ring <= 1
        let steps: [CGFloat] = big ? [0, 0.08, -0.08, 0.16, -0.16, 0.24, -0.24, 0.3, -0.3, 0.36, -0.36, 0.42, -0.42]
                                   : [0, 0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.38, -0.38]
        for step in steps {
            let angle = mid + sweep * step
            if fits(w: w, h: h, angle: angle, piece: p, radius: R, margin: big ? 2 : 3) { return angle }
        }
        return nil
    }

    private static func fits(w: CGFloat, h: CGFloat, angle: CGFloat, piece p: Piece, radius R: CGFloat, margin: CGFloat) -> Bool {
        let mid = CGFloat(p.midAngle)
        let rm = CGFloat(p.r0 + p.r1) * 0.5 * R
        let cx = sin(angle) * rm, cy = -cos(angle) * rm
        let inner = CGFloat(p.r0) * R + margin, outer = CGFloat(p.r1) * R - margin
        for (sx, sy) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)] {
            let x = cx + CGFloat(sx) * w / 2, y = cy + CGFloat(sy) * h / 2
            let r = hypot(x, y)
            if r < inner || r > outer { return false }
            var a = atan2(x, -y)
            if a < 0 { a += 2 * .pi }
            // Near 12 o'clock the angle wraps around, so measure from the piece's middle.
            var delta = a - mid
            if delta > .pi { delta -= 2 * .pi }
            if delta < -.pi { delta += 2 * .pi }
            let half = CGFloat(p.sweep) * 0.5 - margin / max(r, 1)
            if abs(delta) > half { return false }
        }
        return true
    }

    private static func isBright(_ c: SIMD3<Float>) -> Bool {
        0.2289 * c.x + 0.6917 * c.y + 0.0793 * c.z > 0.40
    }

    /// A piece to name, with what to call it.
    struct Pick {
        var index: Int
        var title: String
        var value: String
        var score: Double
    }

    /// `only` names just these at the sides: what you're pointing at in the panel.
    @MainActor
    static func place(layout: RingLayout, ring: RingGeometry, lens: Lens, tree: DiskTree, model: AppModel, only: [Pick]? = nil) -> [MapLabel] {
        let R = ring.radius
        guard R > 0, !layout.pieces.isEmpty else { return [] }
        var out: [MapLabel] = []
        var labelled = Set<Int>()
        let cx = ring.center.x, cy = ring.center.y

        func point(_ angle: CGFloat, _ radius: CGFloat) -> CGPoint {
            CGPoint(x: cx + sin(angle) * radius, y: cy - cos(angle) * radius)
        }

        // Inside the pieces, biggest first. Only in the Map view: elsewhere most of the ring is dimmed on purpose.
        let order = layout.pieces.indices.sorted { layout.pieces[$0].bytes > layout.pieces[$1].bytes }
        if lens == .map || lens == .freeUp {
            for i in order.prefix(160) {
                let p = layout.pieces[i]
                if p.isSmaller || p.isMark || p.ring > 3 { continue }
                if lens == .freeUp && p.style != 1 { continue }
                let isFree = p.style == 1
                let isHidden = p.style == 2
                // The top of a chain is what you'd call it. The whole chain shows when you point at it.
                let title = isFree ? "Free" : model.displayName(p.node)
                let value = tree.sizeText(p.node)
                let w = max(width(title, titleFont), width(value, valueFont)) + 2
                let h: CGFloat = 31
                if let angle = fit(w: w, h: h, piece: p, radius: R) {
                    // Free space reads best out in the open part of the wedge, away from the crowded middle.
                    let rm = CGFloat(p.r0 + p.r1) * 0.5 * R * (isFree ? 1.08 : 1)
                    out.append(MapLabel(id: p.key, pieceIndex: i, node: p.node, title: title, value: value, position: point(angle, rm),
                                        anchor: .zero, elbow: .zero, place: .inside, dark: !isFree && !isHidden && isBright(p.color), large: isFree))
                    labelled.insert(i)
                    if out.count >= 36 { break }
                }
            }
        }

        // Out at the sides: what's big but can't hold its own name.
        typealias Candidate = Pick
        var candidates: [Candidate] = only ?? []
        if only == nil {
        switch lens {
        case .map:
            let total = Double(max(tree.totals[Int(layout.focus)], 1))
            for i in order.prefix(260) where !labelled.contains(i) {
                let p = layout.pieces[i]
                if p.isSmaller || p.isMark || p.style == 1 || p.ring > 4 { continue }
                let share = Double(p.bytes) / total
                if share < 0.015 { continue }
                if p.ring == 0 && layout.focus == 0 { continue }
                // Skip it if the name on a piece just inside it says nearly the same thing.
                var a = p.parent
                var redundant = false
                while a >= 0 {
                    let q = layout.pieces[Int(a)]
                    if labelled.contains(Int(a)) && Double(p.bytes) > Double(q.bytes) * 0.72 { redundant = true }
                    a = q.parent
                }
                if redundant { continue }
                candidates.append(Candidate(index: i, title: model.displayName(p.node), value: tree.sizeText(p.node), score: share * (1 - 0.13 * Double(p.ring))))
            }
        case .changes:
            for row in model.changeRows.prefix(18) {
                if let i = visiblePiece(for: row.node, layout: layout, tree: tree), !candidates.contains(where: { $0.index == i }) {
                    // What grew has a plus. What's gone untouched is just how much.
                    let sign = model.changeWindow.isUntouched ? "" : "+"
                    candidates.append(Candidate(index: i, title: row.title, value: sign + formatBytes(UInt64(max(row.delta, 0))), score: Double(row.delta)))
                }
            }
        case .freeUp:
            // Things spread over many places are lit up from the panel. A line to just one of them would mislead.
            let bar = Double(max(tree.capacityBytes, 1)) * 0.002
            // What's in use lately is folded away in the list, so it doesn't take up a name here unless it's planned.
            for row in model.shownRows.sorted(by: { $0.gain > $1.gain }).prefix(40) where row.action != .restart && row.action != .softwareUpdate && row.nodes.count <= 3 && Double(row.gain) >= bar
                && !(row.inUse != nil && row.tier <= .rebuilds && model.rowStates[row.id] == TickState.none) {
                let biggest = row.nodes.max { tree.totals[Int($0)] < tree.totals[Int($1)] }
                if let biggest, let i = visiblePiece(for: biggest, layout: layout, tree: tree), !candidates.contains(where: { $0.index == i }) {
                    candidates.append(Candidate(index: i, title: row.title, value: formatBytes(row.gain), score: Double(row.gain)))
                }
            }
            // What's been moved is on its way out through here.
            if let after = model.afterClean, after.state == .waiting, let trash = model.trashNode(in: tree), let i = visiblePiece(for: trash, layout: layout, tree: tree) {
                candidates.removeAll { $0.index == i }
                candidates.insert(Candidate(index: i, title: "In the Trash", value: tree.sizeText(trash), score: .greatestFiniteMagnitude), at: 0)
            }
        }
        }
        candidates.sort { $0.score > $1.score }
        // A name just outside a piece that's already named would say nearly the same thing.
        var kept: [Candidate] = []
        for c in candidates {
            let p = layout.pieces[c.index]
            var a = p.parent
            var repeats = false
            while a >= 0 {
                let q = layout.pieces[Int(a)]
                if kept.contains(where: { $0.index == Int(a) }) && Double(p.bytes) > Double(q.bytes) * 0.72 { repeats = true }
                a = q.parent
            }
            if !repeats { kept.append(c) }
        }
        candidates = kept

        let spacing: CGFloat = 35
        let maxPerSide = min(max(Int((ring.windowHeight - 120) / spacing), 3), 7)
        var rightSide: [Candidate] = [], leftSide: [Candidate] = []
        for c in candidates {
            let mid = layout.pieces[c.index].midAngle
            if mid < .pi {
                if rightSide.count < maxPerSide { rightSide.append(c) }
            } else if leftSide.count < maxPerSide {
                leftSide.append(c)
            }
        }

        /// How far out this wedge reaches along its own centre line. The line to a name starts there, so it never
        /// crosses the ring.
        func silhouette(_ index: Int, _ angle: Float) -> Float {
            let p = layout.pieces[index]
            var edge = p.r1
            var j = index + 1
            while j < Int(p.end) {
                let q = layout.pieces[j]
                if angle >= q.a0 && angle < q.a1 {
                    edge = max(edge, q.r1)
                    j += 1
                } else {
                    j = Int(q.end)
                }
            }
            return edge
        }

        func layoutSide(_ side: [Candidate], right: Bool) {
            guard !side.isEmpty else { return }
            let reach = R + 26
            struct Slot { var c: Candidate; var y: CGFloat; var mid: CGFloat }
            var slots = side.map { c -> Slot in
                let mid = CGFloat(layout.pieces[c.index].midAngle)
                return Slot(c: c, y: cy - cos(mid) * reach, mid: mid)
            }.sorted { $0.y < $1.y }
            let top: CGFloat = 78, bottom = ring.windowHeight - 26
            for i in slots.indices {
                slots[i].y = max(slots[i].y, i == 0 ? top : slots[i - 1].y + spacing)
            }
            if let last = slots.last, last.y > bottom {
                var limit = bottom
                for i in slots.indices.reversed() {
                    slots[i].y = min(slots[i].y, limit)
                    limit = slots[i].y - spacing
                }
            }
            let columnX = right ? cx + R + 34 : cx - R - 34
            for slot in slots {
                let p = layout.pieces[slot.c.index]
                let edge = CGFloat(silhouette(slot.c.index, p.midAngle)) * R + 2
                let anchor = point(slot.mid, edge)
                // The line leaves along its wedge until it's level with the name, then runs dead level to it.
                let side: CGFloat = right ? 1 : -1
                let rise = slot.y - anchor.y
                let along = -cos(slot.mid)
                var bend = anchor.x + side * max(abs(rise) * 1.5, 14)
                if abs(along) > 0.05, rise * along > 0 { bend = anchor.x + sin(slot.mid) * rise / along }
                // Never back into the ring, and never past the name.
                let nameEnd = columnX - side * 7
                bend = right ? min(max(bend, anchor.x + 6), nameEnd - 8) : max(min(bend, anchor.x - 6), nameEnd + 8)
                // A name that changes sides is a new label, so it fades across instead of flying over the ring.
                out.append(MapLabel(id: p.key ^ (right ? 0xABCD : 0xDCBA), pieceIndex: slot.c.index, node: p.node, title: slot.c.title, value: slot.c.value,
                                    position: CGPoint(x: columnX, y: slot.y), anchor: anchor, elbow: CGPoint(x: bend, y: slot.y),
                                    place: right ? .right : .left, dark: false, large: false))
            }
        }
        // Only when there's room beside the ring.
        if ring.mapWidth - R * 2 > 200 {
            layoutSide(rightSide, right: true)
            layoutSide(leftSide, right: false)
        }
        return out
    }

    private static func visiblePiece(for node: UInt32, layout: RingLayout, tree: DiskTree) -> Int? {
        var target = node
        while true {
            if let i = layout.pieces.firstIndex(where: { !$0.isSmaller && !$0.isMark && $0.node == target }) { return i }
            if target == 0 || target == layout.focus { return nil }
            target = tree.nodes[Int(target)].parent
        }
    }
}

struct LabelsLayer: View {
    let model: AppModel

    /// Quicker than the glide of the names that stay, so a name on its way out is soon gone.
    private static let comeAndGo = AnyTransition.opacity.animation(.easeOut(duration: 0.18))

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.labels.filter { $0.place != .inside }) { label in
                let isOn = model.hover?.node == label.node
                LeaderLine(anchor: label.anchor, elbow: label.elbow,
                           end: CGPoint(x: label.position.x + (label.place == .right ? -7 : 7), y: label.position.y))
                    .stroke(.white.opacity(isOn ? 0.7 : 0.26), lineWidth: isOn ? 1 : 0.75)
                    .allowsHitTesting(false)
                    .transition(Self.comeAndGo)
                Circle()
                    .fill(.white.opacity(isOn ? 1 : 0.7))
                    .frame(width: 3.2, height: 3.2)
                    .position(label.anchor)
                    .allowsHitTesting(false)
                    .transition(Self.comeAndGo)
            }

            ForEach(model.labels) { label in
                if label.place == .inside {
                    InsideLabel(label: label)
                        .opacity(model.hover == nil || model.hover?.node == label.node ? 1 : 0.5)
                        .animation(.easeOut(duration: 0.14), value: model.hover?.node)
                        .position(label.position)
                        .allowsHitTesting(false)
                        .transition(Self.comeAndGo)
                } else {
                    let right = label.place == .right
                    let room = max(right ? model.ring.mapWidth - label.position.x - 6 : label.position.x - 12, 60)
                    OuterLabel(label: label, isOn: model.hover?.node == label.node)
                        .onHover { inside in
                            if inside { model.enterLabel(piece: label.pieceIndex) } else { model.leaveLabel(piece: label.pieceIndex) }
                        }
                        .onTapGesture { model.openLabel(piece: label.pieceIndex, count: NSApp.currentEvent?.clickCount ?? 1) }
                        .named(NamedThing(label.node), in: model)
                        .frame(width: room, alignment: right ? .leading : .trailing)
                        .position(x: right ? label.position.x + room / 2 : label.position.x - room / 2, y: label.position.y)
                        .transition(Self.comeAndGo)
                }
            }
        }
        .opacity(model.labelsVisible ? 1 : 0)
    }
}

/// The thin line from a piece to its name. It's a shape so that it can glide with the piece during a scan.
private struct LeaderLine: Shape {
    var anchor: CGPoint
    var elbow: CGPoint
    var end: CGPoint

    var animatableData: AnimatablePair<AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>, CGPoint.AnimatableData> {
        get { AnimatablePair(AnimatablePair(anchor.animatableData, elbow.animatableData), end.animatableData) }
        set {
            anchor.animatableData = newValue.first.first
            elbow.animatableData = newValue.first.second
            end.animatableData = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: anchor)
        path.addLine(to: elbow)
        path.addLine(to: end)
        return path
    }
}

private struct InsideLabel: View {
    let label: MapLabel

    var body: some View {
        VStack(spacing: 0) {
            Text(label.title)
                .font(.system(size: label.large ? 14 : 12.5, weight: .semibold))
            Text(label.value)
                .font(.system(size: label.large ? 13 : 11, weight: .medium).monospacedDigit())
                .opacity(label.dark ? 0.72 : 0.78)
        }
        // New numbers replace the old ones at once. Fading between them would leave both on screen as the label moves.
        .contentTransition(.identity)
        .foregroundStyle(label.dark ? Color.black.opacity(0.84) : Color.white.opacity(0.96))
        .shadow(color: label.dark ? .clear : .black.opacity(0.45), radius: 2, y: 0.5)
        .lineLimit(1)
        .fixedSize()
    }
}

private struct OuterLabel: View {
    let label: MapLabel
    let isOn: Bool

    var body: some View {
        VStack(alignment: label.place == .left ? .trailing : .leading, spacing: 0) {
            Text(label.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(isOn ? 1 : 0.88))
                // Beside the inspector there's less room: a long name gets a little smaller before it's cut short.
                .minimumScaleFactor(0.8)
                .truncationMode(.tail)
            Text(label.value)
                .font(.system(size: 11, weight: .regular).monospacedDigit())
                .foregroundStyle(.white.opacity(isOn ? 0.85 : 0.5))
        }
        .contentTransition(.identity)
        .lineLimit(1)
        .contentShape(Rectangle())
    }
}

/// The middle of the ring: the one number that matters, until you point at something else.
struct CenterReadout: View {
    let model: AppModel
    let ring: RingGeometry

    var body: some View {
        let size = ring.radius * CGFloat(RingLayout.hole) * 2 * 0.86
        Group {
            if let hover = model.hover {
                hoverContent(hover, size: size)
            } else if model.focus != 0, let tree = model.tree {
                folderContent(tree, size: size)
            } else if model.lens == .changes, model.changeUsesHistory || model.changeTotal > 0 {
                changesContent(size: size)
            } else {
                diskContent(size: size)
            }
        }
        .frame(width: size, height: size)
        .multilineTextAlignment(.center)
        .position(ring.center)
        .allowsHitTesting(false)
    }

    /// Every state puts its parts in the same places, so nothing moves with the pointer: the number at the very middle, a
    /// line's room above it for a name, and two lines' room below. A part with nothing to say keeps its room, and text
    /// that's too long shrinks a little, then is cut short.
    private func slots<Above: View, Below: View>(_ size: CGFloat, number: some View, @ViewBuilder above: () -> Above,
                                                 @ViewBuilder below: () -> Below) -> some View {
        let room = size * 0.18
        // Each room is held open by something clear, because an empty one would otherwise fold away.
        return VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Color.clear
                above()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: size * 0.9, height: room)
            number
                .frame(height: size * 0.28)
            ZStack(alignment: .top) {
                Color.clear
                below()
            }
            .frame(width: size * 0.9, height: room)
        }
    }

    private func bigNumber(_ bytes: UInt64, size: CGFloat, color: Color = .white, sign: String = "") -> some View {
        let (value, unit) = splitBytes(bytes)
        let digits = Font.system(size: size * 0.235, weight: .semibold, design: .rounded).monospacedDigit()
        let units = Font.system(size: size * 0.105, weight: .semibold, design: .rounded)
        // Each in a box as wide as it ever gets, so the digits' right edge and the unit stay put whatever the value.
        return HStack(alignment: .firstTextBaseline, spacing: size * 0.016) {
            ZStack(alignment: .trailing) {
                // Changes has a sign in front, so its box makes room for one in every number it shows.
                Text(model.lens == .changes ? "−8.88" : "8.88").font(digits).hidden()
                Text(sign + value)
                    .font(digits)
                    .contentTransition(Motion.rolling(Double(bytes)))
            }
            ZStack(alignment: .leading) {
                Text("MB").font(units).hidden()
                Text(unit)
                    .font(units)
                    .foregroundStyle(color.opacity(0.62))
            }
        }
        .foregroundStyle(color)
        .animation(.snappy(duration: 0.32), value: bytes)
    }

    /// Free space is on screen from the first frame, because the disk itself reports it.
    @ViewBuilder
    private func diskContent(size: CGFloat) -> some View {
        // Nothing until the disk is known, so the first frame doesn't roll up from zero.
        if let free = model.tree.map({ $0.totals[Int($0.free)] }) ?? model.volume?.free {
            let capacity = model.tree?.capacityBytes ?? model.volume?.capacity ?? 0
            let planning = model.planBytes >= 1_000_000 && model.lens == .freeUp
            let preview = free &+ model.planBytes
            let usedShare = 1 - Double(free) / Double(max(capacity, 1))
            slots(size, number: bigNumber(planning ? preview : free, size: size, color: planning ? Color(red: 0.45, green: 1, blue: 0.68) : .white)) {
                EmptyView()
            } below: {
                VStack(spacing: size * 0.012) {
                    Text(planning ? "free after this" : "free of \(formatBytes(capacity))")
                        .font(.system(size: size * 0.058, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    if let pointing = model.pointing, model.lens == .freeUp {
                        pointingLine(pointing, size: size)
                    } else if planning {
                        Text("+\(formatBytes(model.planBytes))")
                            .font(.system(size: size * 0.05, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color(red: 0.45, green: 1, blue: 0.68).opacity(0.8))
                    } else if let delta = sinceLast(free) {
                        deltaCapsule(delta, size: size)
                    } else {
                        Text(String(format: "%.0f%% full", usedShare * 100))
                            .font(.system(size: size * 0.05, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.36))
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
    }

    /// In Changes the middle says how much free space changed, from the scan it compares with, or else how much was
    /// touched, going by file dates.
    private func changeColour(_ note: String) -> Color {
        if model.changeWindow.isUntouched { return Palette.untouched.swiftUI }
        return note.hasPrefix("−") ? Palette.cool.swiftUI : Palette.grew.swiftUI
    }

    private func changesContent(size: CGFloat) -> some View {
        let window = model.changeWindow
        let when = window == .lastScan ? "since the last scan" : "in the last \(window.title)"
        let history = model.changeUsesHistory
        // `changeTotal` counts down from free space when comparing with history, and up from what was touched otherwise.
        let change = history ? -model.changeTotal : model.changeTotal
        let colour = history ? (change < 0 ? Palette.grew.swiftUI : (change > 0 ? Palette.cool.swiftUI : .white)) : .white
        let sign = history ? (change < 0 ? "−" : (change > 0 ? "+" : "")) : ""
        return slots(size, number: bigNumber(UInt64(abs(change)), size: size, color: colour, sign: sign)) {
            EmptyView()
        } below: {
            VStack(spacing: size * 0.012) {
                Text(window.isUntouched ? "untouched \(window.span)" : history ? "free space \(when)" : "touched \(when)")
                    .font(.system(size: size * 0.058, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                if !history {
                    Text("going by file dates")
                        .font(.system(size: size * 0.05, weight: .medium))
                        .foregroundStyle(.white.opacity(0.36))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    /// What you're pointing at in the panel, in its own colour.
    private func pointingLine(_ pointing: Pointing, size: CGFloat) -> some View {
        Text("\(pointing.title): \(formatBytes(pointing.bytes))")
            .font(.system(size: size * 0.05, weight: .semibold).monospacedDigit())
            .foregroundStyle(pointing.color.swiftUI)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// How much free space has changed since a day or so ago, once there's a history to compare with.
    private func sinceLast(_ free: UInt64) -> (delta: Int64, label: String)? {
        guard model.history.count >= 2 else { return nil }
        let now = Date()
        let day: TimeInterval = 86_400
        let older = model.history.dropLast().last { now.timeIntervalSince($0.date) >= day * 0.6 }
        guard let older else { return nil }
        let delta = Int64(bitPattern: free) - Int64(bitPattern: older.free)
        guard abs(delta) >= 500_000_000 else { return nil }
        let hours = now.timeIntervalSince(older.date) / 3600
        let label = hours < 36 ? "since yesterday" : (hours < 24 * 9 ? "in \(Int(hours / 24)) days" : "in \(Int(hours / 24 / 7)) weeks")
        return (delta, label)
    }

    private func deltaCapsule(_ info: (delta: Int64, label: String), size: CGFloat) -> some View {
        let down = info.delta < 0
        return HStack(spacing: 3) {
            Image(systemName: down ? "arrow.down" : "arrow.up")
                .font(.system(size: size * 0.042, weight: .bold))
            Text("\(formatBytes(UInt64(abs(info.delta)))) \(info.label)")
                .font(.system(size: size * 0.05, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(down ? Color(red: 1, green: 0.58, blue: 0.48) : Color(red: 0.5, green: 0.95, blue: 0.68))
        .padding(.top, size * 0.01)
    }

    private func folderContent(_ tree: DiskTree, size: CGFloat) -> some View {
        slots(size, number: bigNumber(tree.totals[Int(model.focus)], size: size)) {
            HStack(spacing: 2) {
                Image(systemName: "chevron.left")
                    .font(.system(size: size * 0.05, weight: .bold))
                    .foregroundStyle(.white.opacity(0.42))
                Text(model.displayName(model.focus))
                    .font(.system(size: size * 0.072, weight: .semibold))
                    .truncationMode(.middle)
            }
            .foregroundStyle(.white.opacity(0.92))
        } below: {
            Text(tree.isStillGrowing(model.focus) ? "so far" : shareOfDisk(tree))
                .font(.system(size: size * 0.052, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func shareOfDisk(_ tree: DiskTree) -> String {
        let percent = Double(tree.totals[Int(model.focus)]) / Double(max(tree.capacityBytes, 1)) * 100
        return (percent >= 10 ? String(format: "%.0f%%", percent) : String(format: "%.1f%%", percent)) + " of the disk"
    }

    private func hoverContent(_ hover: HoverInfo, size: CGFloat) -> some View {
        slots(size, number: bigNumber(hover.bytes, size: size)) {
            Text(hover.title)
                .font(.system(size: size * 0.072, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .truncationMode(.middle)
        } below: {
            if let links = hover.links {
                Text(links)
                    .font(.system(size: size * 0.072, weight: .semibold))
                    .foregroundStyle(Color(red: 1, green: 0.74, blue: 0.42))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.middle)
            } else if !hover.note.isEmpty {
                // In Changes the line says what changed, in the view's own colours. When it says when something was last
                // used, it looks as it does on the map.
                let saysChange = model.lens == .changes && !hover.tellsUse
                Text(hover.note)
                    .font(.system(size: size * 0.072, weight: saysChange ? .semibold : .medium))
                    .foregroundStyle(saysChange ? changeColour(hover.note) : .white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else if !hover.share.isEmpty {
                Text(hover.share)
                    .font(.system(size: size * 0.072, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.middle)
            }
        }
    }
}
