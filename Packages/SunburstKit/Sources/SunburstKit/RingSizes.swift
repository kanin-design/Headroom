import Foundation

/// How many rings a picture draws and how thick they are.
public struct RingSizes: Equatable, Sendable {
    /// The most rings a picture draws, not counting the thin band around the whole tree. A picture never gets more than it
    /// can fill.
    public var depth = 6
    /// How thick each ring is.
    public var style = RingStyle.tapered

    /// The most rings there can be.
    public static let most = 12

    public init(depth: Int = 6, style: RingStyle = .tapered) {
        self.depth = depth
        self.style = style
    }
}

/// How thick each ring is, and which rings a picture can fill. Rings always get thinner going out, so far-out folders don't
/// look bigger than they are.
public enum RingStyle: String, CaseIterable, Sendable {
    /// The curve six rings have always had, stretched or squeezed to however many there are.
    case standard
    /// Each ring a fifth thinner than the one inside it, so the rings near the middle keep more of their room as rings are
    /// added. With many rings it eases off, so the outermost is never thinner than `thinnestTip` of the first.
    case tapered
    /// Each ring as thick as it's full, every ring with something in it, and a lip on folders in the outermost ring that go on.
    case adaptive

    /// Each ring's share of the room, from the middle out. `fill` is how far around each ring goes, as a share of the first.
    public func shares(count: Int, fill: [Float]) -> [Float] {
        switch self {
        case .standard:
            let last = Float(Self.sixRings.count - 1)
            return (0..<count).map { k in
                let x = count > 1 ? Float(k) * last / Float(count - 1) : 0
                let i = min(Int(x), Self.sixRings.count - 2)
                return Self.sixRings[i] + (Self.sixRings[i + 1] - Self.sixRings[i]) * (x - Float(i))
            }
        case .tapered:
            let step = count > 1 ? max(Self.taper, pow(Self.thinnestTip, 1 / Float(count - 1))) : 1
            return (0..<count).map { pow(step, Float($0)) }
        case .adaptive:
            return (0..<count).map { $0 < fill.count ? fill[$0] : 1 }
        }
    }

    /// The least a ring has to go around, as a share of the first, to be drawn. Less is a sliver or two in an empty ring,
    /// though a few thin spokes count: they show which folders go deeper. Adaptive rings draw every ring with something in
    /// it, since one that's nearly empty is thin.
    public var leastFill: Float { self == .adaptive ? 0 : 0.03 }

    /// Whether folders in the outermost ring show that they go on.
    public var marksDeeper: Bool { self == .adaptive }

    /// A fifth thinner each time keeps five and six rings practically as they are in the standard curve. What changes is
    /// what more rings cost: the first ring keeps more of its room than in the standard curve, and the tips less.
    public static let taper: Float = 0.8
    /// The thinnest the outermost tapered ring gets, as a share of the first: about halfway between the standard curve and
    /// a fifth thinner all the way out, so the tips stay easy to read.
    public static let thinnestTip: Float = 0.3
    private static let sixRings: [Float] = [0.150, 0.128, 0.108, 0.090, 0.074, 0.060]
}
