import QuartzCore
import SwiftUI

/// What the middle of the ring says: the name of what's pointed at or in view, its size, and a line below. The chart keeps
/// one up to date; an app with a centre of its own reads it, or ignores it and shows its own.
public struct SunburstReadout: Equatable, Sendable {
    public var title: String
    /// The size, for the direction the number rolls in as it changes.
    public var size: UInt64
    /// What's written for it: a number, then a space and a unit, such as "4.20 GB".
    public var text: String
    public var detail: String
    /// A click in the middle goes back out.
    public var goesBack: Bool

    public init(title: String = "", size: UInt64 = 0, text: String = "", detail: String = "", goesBack: Bool = false) {
        self.title = title
        self.size = size
        self.text = text
        self.detail = detail
        self.goesBack = goesBack
    }
}

/// The kit's centre: a name above, the size large, and a line below. Each part keeps its place whatever is shown, so
/// nothing jumps as the pointer moves. `diameter` is the room the centre has, the hole's.
public struct SunburstReadoutView: View {
    let readout: SunburstReadout
    let diameter: CGFloat

    public init(_ readout: SunburstReadout, diameter: CGFloat) {
        self.readout = readout
        self.diameter = diameter
    }

    public var body: some View {
        let d = max(diameter, 1)
        let room = d * 0.18
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                Color.clear
                HStack(spacing: d * 0.018) {
                    if readout.goesBack {
                        Image(systemName: "chevron.left")
                            .font(.system(size: d * 0.055, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Text(readout.title)
                        .font(.system(size: d * 0.075, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .truncationMode(.middle)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .frame(width: d * 0.9, height: room)
            SunburstNumber(readout.text, size: readout.size, diameter: d, about: readout.title)
                .frame(width: d * 0.9, height: d * 0.28)
            ZStack(alignment: .top) {
                Color.clear
                Text(readout.detail)
                    .font(.system(size: d * 0.058, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: d * 0.9, height: room)
        }
        .frame(width: d, height: d)
        .multilineTextAlignment(.center)
    }
}

/// The centre's big number, its unit smaller beside it: for an app's own centre that should read like the kit's. `size` sets
/// which way the digits roll; `diameter` is the centre's room. In `color`, with the unit a little fainter. `widest` is the
/// widest text it will show, such as "−8.88 MB": the number and the unit each keep that much room, so neither moves as the
/// value changes.
///
/// The digits roll when the thing the number is about changes size, as while it's measured or after something is removed.
/// `about` says what that thing is: when it's another thing, as when the pointer moves to another piece, the number just
/// changes. Rolling digits say "this changed", which isn't what happened, and macOS draws each frame of them on the CPU,
/// blurred, which at this size is several milliseconds a frame: enough to make the ring's light stutter behind the pointer.
/// Without `about`, every new value rolls.
public struct SunburstNumber: View {
    let text: String
    let size: UInt64
    let diameter: CGFloat
    let color: Color
    let widest: String?
    let subject: AnyHashable?
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @State private var pace = RollPace()

    public init(
        _ text: String, size: UInt64, diameter: CGFloat, color: Color = .white, widest: String? = nil,
        about subject: AnyHashable? = nil
    ) {
        self.text = text
        self.size = size
        self.diameter = diameter
        self.color = color
        self.widest = widest
        self.subject = subject
    }

    public var body: some View {
        let d = max(diameter, 1)
        let (value, unit) = Self.split(text)
        let room = widest.map(Self.split)
        let digits = Font.system(size: d * 0.235, weight: .semibold, design: .rounded).monospacedDigit()
        let units = Font.system(size: d * 0.105, weight: .semibold, design: .rounded)
        HStack(alignment: .firstTextBaseline, spacing: d * 0.016) {
            ZStack(alignment: .trailing) {
                if let room { Text(room.0).font(digits).hidden() }
                Text(value)
                    .font(digits)
                    .contentTransition(reducesMotion ? .opacity : .numericText(value: Double(size)))
            }
            ZStack(alignment: .leading) {
                if let room { Text(room.1).font(units).hidden() }
                Text(unit)
                    .font(units)
                    .foregroundStyle(color.opacity(0.62))
            }
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .animation(pace.rolls(to: size, about: subject) ? .snappy(duration: 0.32) : nil, value: size)
    }

    /// "4.2 GB" as "4.2" and "GB". Text without a unit at its end stays whole.
    static func split(_ text: String) -> (String, String) {
        guard let space = text.lastIndex(of: " ") else { return (text, "") }
        let unit = text[text.index(after: space)...]
        guard !unit.isEmpty, !unit.contains(where: \.isNumber) else { return (text, "") }
        return (String(text[..<space]), String(unit))
    }
}

/// Whether a number rolls to its next value: when it's still about the same thing, and the last value was there long
/// enough to be read. Rolling digits are drawn again on every frame, which is worth it for a value someone watches change
/// and wasted on one that's replaced at once.
final class RollPace {
    /// A value that lasted less than this just changes: about four frames.
    static let least = 0.07

    private var size: UInt64?
    private var subject: AnyHashable?
    private var changedAt = 0.0
    private var rolls = false

    /// Whether the change to this value rolls: asked on every pass of the view, it answers the same until the value or
    /// what it's about changes again. The first value is simply there.
    func rolls(to size: UInt64, about subject: AnyHashable? = nil, now: Double = CACurrentMediaTime()) -> Bool {
        guard size != self.size || subject != self.subject else { return rolls }
        rolls = self.size != nil && subject == self.subject && now - changedAt >= Self.least
        self.size = size
        self.subject = subject
        changedAt = now
        return rolls
    }
}
