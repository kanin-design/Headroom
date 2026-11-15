import SwiftUI

/// Backup's colours: blue for what goes to the drive, green for what's done, amber for what needs a look.
enum BackupColours {
    static let blue = Color(red: 0.42, green: 0.70, blue: 1)
    static let green = Color(red: 0.36, green: 0.82, blue: 0.56)
}

/// The ring Backup's cards lead with: how far, or how much, at a glance. The accent part runs from twelve o'clock; an amber
/// part can follow it, up to `upTo`. Something short goes in the middle.
struct CardRing<Centre: View>: View {
    let fraction: Double
    var upTo: Double? = nil
    let accent: Color
    @ViewBuilder let centre: () -> Centre

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.08), lineWidth: 6)
            if let upTo, upTo > fraction + 0.001 {
                Circle()
                    .trim(from: max(fraction, 0.004), to: upTo)
                    .stroke(Palette.amber.opacity(0.75), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Circle()
                .trim(from: 0, to: max(fraction, 0.004))
                .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            centre()
                .padding(.horizontal, 8)
        }
        .frame(width: 54, height: 54)
        .animation(.smooth(duration: 0.3), value: fraction)
    }
}

/// A card in Backup's panel: the ring, a title with a line or two beside it, and what follows below. What's selected and
/// what's being moved are the same card, so one turns into the other where it is.
struct BackupCard<Ring: View, Lines: View, Content: View>: View {
    let title: String
    @ViewBuilder let ring: () -> Ring
    @ViewBuilder let lines: () -> Lines
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ring()
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .lineLimit(2)
                    lines()
                }
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.07)))
    }
}

/// A line under a card's title, in the card's own grey.
struct CardLine: View {
    let text: String
    var colour: Color = .white.opacity(0.55)

    var body: some View {
        Text(text)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(colour)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// Where it goes, and the drive's room: what's on it already in grey, what this adds in blue, and, while it's being moved,
/// how much of that has landed, brighter.
struct DriveRoomBar: View {
    let place: String
    let capacity: UInt64
    let free: UInt64
    let adds: UInt64
    var landed: UInt64? = nil
    let trailing: String
    var trailingColour: Color = .white.opacity(0.55)

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                Text(place)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(trailing)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(trailingColour)
            }
            if capacity > 0 {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let used = Double(capacity &- min(capacity, free)) / Double(capacity)
                    let share = Double(min(adds, free)) / Double(capacity)
                    let done = landed.map { Double(min($0, adds, free)) / Double(capacity) }
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.08))
                        Capsule().fill(.white.opacity(0.28)).frame(width: max(width * (used + share), 4))
                        Capsule().fill(BackupColours.blue.opacity(done == nil ? 1 : 0.35)).frame(width: max(width * share, 3)).offset(x: width * used)
                        if let done {
                            Capsule().fill(BackupColours.blue).frame(width: max(width * done, done > 0 ? 3 : 0)).offset(x: width * used)
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
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .semibold))
            Text(name)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(BackupColours.blue.opacity(0.16)))
        .foregroundStyle(BackupColours.blue)
        .padding(.top, 1)
    }
}
