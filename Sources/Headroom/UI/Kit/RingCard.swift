import SwiftUI

/// The ring a card leads with: how far, or how much, at a glance. The accent part runs from twelve o'clock; an amber part can
/// follow it, up to `upTo`. Something short goes in the middle. While nothing can say how far, it turns instead.
struct CardRing<Centre: View>: View {
    let fraction: Double
    var upTo: Double? = nil
    let accent: Color
    var spins = false
    @ViewBuilder let centre: () -> Centre
    @State private var turned = false

    var body: some View {
        ZStack {
            Circle().stroke(Kit.Fill.track, lineWidth: 6)
            if spins {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(turned ? 270 : -90))
                    .onAppear { withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { turned = true } }
            } else {
                if let upTo, upTo > fraction + 0.001 {
                    Circle()
                        .trim(from: max(fraction, 0.004), to: upTo)
                        .stroke(Kit.amber.opacity(0.75), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Circle()
                    .trim(from: 0, to: max(fraction, 0.004))
                    .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            centre()
                .padding(.horizontal, 8)
        }
        .frame(width: 54, height: 54)
        .animation(.smooth(duration: 0.3), value: fraction)
    }
}

extension CardRing where Centre == CardRingText {
    /// A ring with a number, or a few letters, in the middle.
    init(fraction: Double, upTo: Double? = nil, accent: Color, text: String) {
        self.init(fraction: fraction, upTo: upTo, accent: accent) { CardRingText(text: text) }
    }
}

extension CardRing where Centre == CardRingMark {
    /// A ring that's whole, with how it ended in the middle: a tick, or a mark for what needs a look.
    init(ended accent: Color, symbol: String) {
        self.init(fraction: 1, accent: accent) { CardRingMark(symbol: symbol, colour: accent) }
    }
}

/// What a ring says in its middle, when it's words.
struct CardRingText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Kit.Font.headline)
            .fontDesign(.rounded)
            .monospacedDigit()
            .minimumScaleFactor(0.6)
            .lineLimit(1)
    }
}

/// What a ring says in its middle when it's done.
struct CardRingMark: View {
    let symbol: String
    let colour: Color

    var body: some View {
        Image(systemName: symbol)
            .font(Kit.Font.title)
            .foregroundStyle(colour)
    }
}

/// A card at the top of a panel: the ring, a title with a line or two beside it, and what follows below. What's selected, what's
/// being done with it and how that ended are the same card, so one turns into the next where it is. Backup's selection and its
/// runs, Free Up's selection and its cleans all use it.
struct RingCard<Ring: View, Lines: View, Content: View>: View {
    let title: String
    @ViewBuilder let ring: () -> Ring
    @ViewBuilder let lines: () -> Lines
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Kit.Space.large) {
            HStack(spacing: Kit.Space.section) {
                ring()
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(Kit.Font.headline.monospacedDigit())
                        .lineLimit(2)
                        .contentTransition(.numericText())
                    lines()
                }
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(Kit.rowInset)
        .card()
    }
}

extension RingCard where Content == EmptyView {
    init(title: String, @ViewBuilder ring: @escaping () -> Ring, @ViewBuilder lines: @escaping () -> Lines) {
        self.init(title: title, ring: ring, lines: lines, content: { EmptyView() })
    }
}

/// A line under a card's title, in the card's own grey or a colour. One line, cut in the middle, unless it's let wrap.
struct CardLine: View {
    let text: String
    var colour: Color = Kit.Text.tertiary
    var wraps = false

    var body: some View {
        Text(text)
            .font(Kit.Font.detail.monospacedDigit())
            .foregroundStyle(colour)
            .lineLimit(wraps ? 3 : 1)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: wraps)
    }
}

/// A card's line with something to do about it at the end: a warning and Deselect, what's in the Trash and Open Trash.
struct CardNote<Action: View>: View {
    let text: String
    var colour: Color = Kit.Text.tertiary
    var symbol: String? = nil
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Kit.Space.medium) {
            if let symbol {
                Image(systemName: symbol)
                    .font(Kit.Font.caption)
            }
            Text(text)
                .font(Kit.Font.detail.monospacedDigit())
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            action()
        }
        .foregroundStyle(colour)
    }
}

/// A disk's room: where it is and what's said about it, then a bar of what's on it already in grey, what this adds in the
/// accent, and while it's going, how much of that has landed, brighter. What frees space is drawn the other way: the part of
/// what's on it that goes, in the accent, at the end of the grey.
struct RoomBar: View {
    var icon = "externaldrive.fill"
    let place: String
    let capacity: UInt64
    let free: UInt64
    let adds: UInt64
    var landed: UInt64? = nil
    /// `adds` is what leaves the disk, not what comes onto it.
    var frees = false
    let trailing: String
    var trailingColour: Color = Kit.Text.tertiary
    var accent: Color = Kit.blue

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(Kit.Font.caption)
                    .foregroundStyle(Kit.Text.tertiary)
                Text(place)
                    .font(Kit.Font.detail.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Kit.Space.medium)
                Text(trailing)
                    .font(Kit.Font.detail.monospacedDigit())
                    .foregroundStyle(trailingColour)
            }
            if capacity > 0 {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let filled = Double(capacity &- min(capacity, free)) / Double(capacity)
                    let share = Double(min(adds, frees ? capacity &- min(capacity, free) : free)) / Double(capacity)
                    let used = frees ? filled - share : filled
                    let done = landed.map { Double(min($0, adds, free)) / Double(capacity) }
                    ZStack(alignment: .leading) {
                        Capsule().fill(Kit.Fill.track)
                        Capsule().fill(Kit.Fill.used).frame(width: max(width * (used + share), 4))
                        // Nothing added, or nothing freed, draws nothing: a dot would say there was.
                        if adds > 0 {
                            Capsule().fill(accent.opacity(done == nil ? 1 : 0.35)).frame(width: max(width * share, 3)).offset(x: width * used)
                        }
                        if let done {
                            Capsule().fill(accent).frame(width: max(width * done, done > 0 ? 3 : 0)).offset(x: width * used)
                                .animation(.linear(duration: 0.2), value: done)
                        }
                    }
                }
                .frame(height: 6)
            }
        }
    }
}

/// Who picked it: an agent's name in a small blue capsule.
struct AgentChip: View {
    let name: String

    var body: some View {
        HStack(spacing: Kit.Space.small) {
            Image(systemName: "sparkles")
                .font(Kit.Font.caption.weight(.semibold))
            Text(name)
                .font(Kit.Font.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Kit.blue.opacity(0.16)))
        .foregroundStyle(Kit.blue)
        .padding(.top, 1)
    }
}

extension AgentChip {
    /// Who picked a selection, from each item's agent: the first agent, and how many it picked unless it picked them all.
    /// Nil when no agent picked any.
    init?(agents: [String], of total: Int) {
        guard let first = agents.first else { return nil }
        let count = agents.filter { $0 == first }.count
        self.init(name: count == total ? first : "\(count) by \(first)")
    }
}

/// How far, as a thin capsule that fills: in place of a stock progress bar.
struct ThinBar: View {
    let fraction: Double
    var tint: Color = Kit.blue
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Kit.Fill.track)
                Capsule().fill(tint.opacity(0.9))
                    .frame(width: max(g.size.width * min(max(fraction, 0), 1), height))
                    .animation(.linear(duration: 0.15), value: fraction)
            }
        }
        .frame(height: height)
    }
}

/// Something under way with no end in sight yet: a short arc going round, in the ring's own look. In place of a stock spinner.
struct Spinner: View {
    var size: CGFloat = 11
    var tint: Color = Kit.Text.secondary
    @State private var turned = false

    var body: some View {
        ZStack {
            Circle().stroke(Kit.Fill.control, lineWidth: max(size / 6, 1.5))
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(tint, style: StrokeStyle(lineWidth: max(size / 6, 1.5), lineCap: .round))
                .rotationEffect(.degrees(turned ? 360 : 0))
        }
        .frame(width: size, height: size)
        .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turned = true } }
    }
}
