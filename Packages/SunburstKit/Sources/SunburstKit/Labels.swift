import AppKit
import SwiftUI

/// A name on the ring: inside a piece if it fits, otherwise out at the side with a thin line to its piece.
public struct MapLabel: Identifiable, Equatable, Sendable {
    public enum Place: Sendable { case inside, left, right }
    public var id: UInt64
    public var pieceIndex: Int
    public var node: UInt32
    public var title: String
    public var value: String
    public var position: CGPoint
    public var anchor: CGPoint
    public var elbow: CGPoint
    public var place: Place
    public var dark: Bool
    public var large: Bool
}

/// Whether the pointer is on anything on the ring, and which named piece it's on, if any.
public struct LabelLight: Equatable, Sendable {
    public var onAnything = false
    public var node: UInt32?

    public init() {}

    /// For the piece the pointer is on, if any, and the pieces that have names.
    public init(hovering node: UInt32?, named: Set<UInt32>) {
        onAnything = node != nil
        self.node = node.flatMap { named.contains($0) ? $0 : nil }
    }
}

/// Where names can go: the ring, the width of the part of the window it's centred in, and how far up and down the names
/// at the sides may go.
public struct LabelArea: Sendable {
    public var center: CGPoint
    public var radius: CGFloat
    public var width: CGFloat
    public var height: CGFloat
    /// The highest a name at the side may sit, and the lowest.
    public var top: CGFloat
    public var bottom: CGFloat

    public init(center: CGPoint, radius: CGFloat, width: CGFloat, height: CGFloat, top: CGFloat = 78, bottom: CGFloat) {
        self.center = center
        self.radius = radius
        self.width = width
        self.height = height
        self.top = top
        self.bottom = bottom
    }
}

/// Places names on and around the ring. What each piece is called, and which pieces are named at the sides, is the host's:
/// these find where the names fit.
public enum LabelPlacer {
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

    /// A piece to name at the side, with what to call it.
    public struct Pick: Sendable {
        public var index: Int
        public var title: String
        public var value: String
        public var score: Double
        /// Tells apart names that share a piece, such as two copies too small to show apart.
        public var salt: UInt64 = 0

        public init(index: Int, title: String, value: String, score: Double, salt: UInt64 = 0) {
            self.index = index
            self.title = title
            self.value = value
            self.score = score
            self.salt = salt
        }
    }

    /// What's been named so far, so a piece isn't named twice.
    public struct Placed: Sendable {
        /// Pieces named inside themselves.
        public var labelled = Set<Int>()
        /// A folder drawn as several stretches is named once.
        public var nodes = Set<UInt32>()

        public init() {}
    }

    /// Pieces biggest first. With halves, the halves come first, whatever they hold.
    public static func order(_ layout: RingLayout, halvesFirst: Bool) -> [Int] {
        layout.pieces.indices.sorted { a, b in
            let pa = layout.pieces[a], pb = layout.pieces[b]
            if halvesFirst, (pa.ring == 0) != (pb.ring == 0) { return pa.ring == 0 }
            return pa.bytes > pb.bytes
        }
    }

    /// Names inside the pieces, biggest first, wherever they fit. `name` says what a piece is called and what it holds, or
    /// nil to leave it unnamed. With `halves`, the two halves of the root are always named, just either side of six o'clock.
    public static func inside(layout: RingLayout, order: [Int], area: LabelArea, halves: Bool, named: inout Placed,
                              name: (Piece) -> (title: String, value: String)?) -> [MapLabel] {
        let R = area.radius
        guard R > 0, !layout.pieces.isEmpty else { return [] }
        var out: [MapLabel] = []
        for i in order.prefix(160) {
            let p = layout.pieces[i]
            if p.isSmaller || p.ring > 3 || named.nodes.contains(p.node) { continue }
            guard let said = name(p) else { continue }
            let isFree = p.style == .free
            // A ghost is drawn faint, whatever its colour, so its name is light like on the dark parts.
            let isHidden = p.style == .hidden || p.style == .ghost
            let w = max(width(said.title, titleFont), width(said.value, valueFont)) + 2
            let h: CGFloat = 31
            let halfSpot: CGFloat? = halves && layout.focus == 0 && p.ring == 0 ? (p.a0 < .pi ? .pi - 0.27 : .pi + 0.27) : nil
            if let angle = halfSpot ?? fit(w: w, h: h, piece: p, radius: R) {
                // Free space reads best out in the open part of the wedge, away from the crowded middle.
                let rm = CGFloat(p.r0 + p.r1) * 0.5 * R * (isFree ? 1.08 : 1)
                out.append(MapLabel(id: p.key, pieceIndex: i, node: p.node, title: said.title, value: said.value,
                                    position: point(area, angle, rm), anchor: .zero, elbow: .zero, place: .inside,
                                    dark: !isFree && !isHidden && isBright(p.color), large: isFree))
                named.labelled.insert(i)
                named.nodes.insert(p.node)
                if out.count >= 36 { break }
            }
        }
        return out
    }

    /// What's big but couldn't hold its own name, to name at the side: anything over 1.5% of `total` in the first five rings,
    /// unless a name on a piece just inside it says nearly the same thing.
    public static func bigPieces(layout: RingLayout, order: [Int], total: UInt64, named: inout Placed,
                                 name: (Piece) -> (title: String, value: String)) -> [Pick] {
        let total = Double(max(total, 1))
        var picks: [Pick] = []
        for i in order.prefix(260) where !named.labelled.contains(i) {
            let p = layout.pieces[i]
            if p.isSmaller || p.style == .free || p.ring > 4 || named.nodes.contains(p.node) { continue }
            let share = Double(p.bytes) / total
            if share < 0.015 { continue }
            if p.ring == 0 && layout.focus == 0 { continue }
            var a = p.parent
            var redundant = false
            while a >= 0 {
                let q = layout.pieces[Int(a)]
                if named.labelled.contains(Int(a)) && Double(p.bytes) > Double(q.bytes) * 0.72 { redundant = true }
                a = q.parent
            }
            if redundant { continue }
            let said = name(p)
            picks.append(Pick(index: i, title: said.title, value: said.value, score: share * (1 - 0.13 * Double(p.ring))))
            named.nodes.insert(p.node)
        }
        return picks
    }

    /// Names out at the sides, best first, each with a thin line to its piece, as many as fit. Unless `eachCounts`, a name
    /// just outside a piece that's already named is left out, as it would say nearly the same thing.
    public static func sides(_ picks: [Pick], layout: RingLayout, area: LabelArea, eachCounts: Bool) -> [MapLabel] {
        let R = area.radius
        guard R > 0, !layout.pieces.isEmpty else { return [] }
        let cx = area.center.x, cy = area.center.y
        var candidates = picks
        candidates.sort { $0.score > $1.score }
        var kept: [Pick] = []
        for c in candidates {
            let p = layout.pieces[c.index]
            var a = p.parent
            var repeats = false
            while a >= 0 && !eachCounts {
                let q = layout.pieces[Int(a)]
                if kept.contains(where: { $0.index == Int(a) }) && Double(p.bytes) > Double(q.bytes) * 0.72 { repeats = true }
                a = q.parent
            }
            if !repeats { kept.append(c) }
        }
        candidates = kept

        let spacing: CGFloat = 35
        let maxPerSide = min(max(Int((area.height - 150) / spacing), 3), 7)
        var rightSide: [Pick] = [], leftSide: [Pick] = []
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

        var out: [MapLabel] = []
        func layoutSide(_ side: [Pick], right: Bool) {
            guard !side.isEmpty else { return }
            let reach = R + 26
            struct Slot { var c: Pick; var y: CGFloat; var mid: CGFloat }
            var slots = side.map { c -> Slot in
                let mid = CGFloat(layout.pieces[c.index].midAngle)
                return Slot(c: c, y: cy - cos(mid) * reach, mid: mid)
            }.sorted { $0.y < $1.y }
            let top = area.top, bottom = area.bottom
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
                let anchor = point(area, slot.mid, edge)
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
                out.append(MapLabel(id: p.key ^ (right ? 0xABCD : 0xDCBA) ^ slot.c.salt, pieceIndex: slot.c.index, node: p.node, title: slot.c.title, value: slot.c.value,
                                    position: CGPoint(x: columnX, y: slot.y), anchor: anchor, elbow: CGPoint(x: bend, y: slot.y),
                                    place: right ? .right : .left, dark: false, large: false))
            }
        }
        // Only when there's room beside the ring.
        if area.width - R * 2 > 200 {
            layoutSide(rightSide, right: true)
            layoutSide(leftSide, right: false)
        }
        return out
    }

    private static func point(_ area: LabelArea, _ angle: CGFloat, _ radius: CGFloat) -> CGPoint {
        CGPoint(x: area.center.x + sin(angle) * radius, y: area.center.y - cos(angle) * radius)
    }
}

/// The names: inside the pieces, and out at the sides with their lines. `outer` dresses each name at the side, such as
/// with a menu of its own.
public struct SunburstLabels<Outer: ViewModifier>: View {
    let labels: [MapLabel]
    let light: LabelLight
    let visible: Bool
    /// The width of the part of the window the ring is centred in.
    let width: CGFloat
    let onEnter: (Int) -> Void
    let onLeave: (Int) -> Void
    let onOpen: (_ piece: Int, _ clicks: Int) -> Void
    let outer: (MapLabel) -> Outer

    public init(labels: [MapLabel], light: LabelLight, visible: Bool, width: CGFloat, onEnter: @escaping (Int) -> Void,
                onLeave: @escaping (Int) -> Void, onOpen: @escaping (_ piece: Int, _ clicks: Int) -> Void,
                outer: @escaping (MapLabel) -> Outer) {
        self.labels = labels
        self.light = light
        self.visible = visible
        self.width = width
        self.onEnter = onEnter
        self.onLeave = onLeave
        self.onOpen = onOpen
        self.outer = outer
    }

    /// Quicker than the glide of the names that stay, so a name on its way out is soon gone.
    private static var comeAndGo: AnyTransition { AnyTransition.opacity.animation(.easeOut(duration: 0.18)) }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(labels.filter { $0.place != .inside }) { label in
                let isOn = light.node == label.node
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

            ForEach(labels) { label in
                if label.place == .inside {
                    InsideLabel(label: label)
                        .opacity(!light.onAnything || light.node == label.node ? 1 : 0.5)
                        .animation(.easeOut(duration: 0.14), value: light)
                        .position(label.position)
                        .allowsHitTesting(false)
                        .transition(Self.comeAndGo)
                } else {
                    let right = label.place == .right
                    let room = max(right ? width - label.position.x - 6 : label.position.x - 12, 60)
                    OuterLabel(label: label, isOn: light.node == label.node)
                        .onHover { inside in
                            if inside { onEnter(label.pieceIndex) } else { onLeave(label.pieceIndex) }
                        }
                        .onTapGesture { onOpen(label.pieceIndex, NSApp.currentEvent?.clickCount ?? 1) }
                        .modifier(outer(label))
                        .frame(width: room, alignment: right ? .leading : .trailing)
                        .position(x: right ? label.position.x + room / 2 : label.position.x - room / 2, y: label.position.y)
                        .transition(Self.comeAndGo)
                }
            }
        }
        .opacity(visible ? 1 : 0)
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
                // Beside a panel there's less room: a long name gets a little smaller before it's cut short.
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
