/// A chart's parts, from the middle out: an optional split, thin bands, the rings, and the dial around them.
///
/// The parts are one description, handed to a chart whole, so the chart can swap all of them at once (another view,
/// more rings) and every piece glides to its new place. Each part has a slot of its own, so an arrangement that makes no
/// sense, such as two dials, can't be written.
///
/// ```swift
/// // A whole disk: what it's made of in a thin band, then six rings of folders.
/// let disk = SunburstParts(bands: [.init()], rings: .init(RingSizes(depth: 6)))
///
/// // Two disks side by side, each its own whole, their folders sorted by where their files are.
/// let pair = SunburstParts(split: .band, rings: .init(order: .byGroup))
/// ```
///
/// Each level of the tree, from the node in the middle down, goes to one part: the split takes the first level, each
/// band the next, and the rings the rest.
public struct SunburstParts: Sendable {
    /// Several wholes sharing the circle, such as this disk and that one. Nil for one whole.
    public var split: Split?
    /// Thin levels just outside the middle: what the whole is made of. The first band is innermost.
    public var bands: [Band]
    /// The rings of things.
    public var rings: Rings
    /// The scale just outside the rings. Nil for none.
    public var dial: Dial?

    public init(split: Split? = nil, bands: [Band] = [], rings: Rings = Rings(), dial: Dial? = Dial()) {
        self.split = split
        self.bands = bands
        self.rings = rings
        self.dial = dial
    }

    /// The same parts with rings of other sizes, keeping how they're ordered and cut.
    public func with(sizes: RingSizes) -> SunburstParts {
        var copy = self
        copy.rings.sizes = sizes
        return copy
    }
}

public extension SunburstParts {
    /// Several wholes that share the circle, such as two disks compared. The root's things are the sides (its room and
    /// what can't be read aren't drawn), each gets an equal share of the circle whatever it holds, and what's in a side
    /// is sized against that side alone. An empty side is still drawn: it says the thing isn't there. Zooming into a side
    /// shows it alone.
    struct Split: Sendable, Equatable {
        public enum Look: Sendable, Equatable {
            /// Thin, like a band: the sides frame the rings rather than being one.
            case band
            /// A full ring, with each side's name written on it.
            case ring
        }

        public var look: Look

        public init(look: Look) {
            self.look = look
        }

        /// The sides as a thin band.
        public static var band: Split { Split(look: .band) }
        /// The sides as a full ring.
        public static var ring: Split { Split(look: .ring) }
    }

    /// A thin level just outside the middle: what the whole is made of, read rather than acted on. It takes the next level
    /// of the tree. A band is always thin and its segments are never named (room closing the circle through it can be),
    /// and it's drawn only while the node in the middle is above its level: zoom into one of its segments and it has been
    /// answered.
    ///
    /// Around the whole tree, room and what can't be read close the circle after everything else, as wedges that reach out
    /// as far as the rest does on average, so their area is their share.
    struct Band: Sendable {
        /// The order of what's in the band, clockwise from 12 o'clock. Room and what can't be read come last either way.
        public enum Order: Sendable {
            /// Biggest first.
            case bySize
            /// Lower ranks first, then biggest first: to keep things in their places while their sizes are still changing,
            /// as while a disk is being read.
            case ranked(@Sendable (UInt32) -> Int)
        }

        public var order: Order

        public init(order: Order = .bySize) {
            self.order = order
        }
    }

    /// The rings of things: one level of the tree deeper each ring, a piece for everything big enough to see, and the rest
    /// gathered into "smaller items" at the end of what holds it.
    struct Rings: Sendable {
        /// The order of what's in a folder, clockwise.
        public enum Order: Sendable, Equatable {
            /// Biggest first.
            case bySize
            /// By the tree's groups (`SunburstTree.group(of:)`) first, then biggest first. A folder whose contents fall in
            /// more than one group is drawn as one stretch for each, coloured by the first thing in it, so each group's
            /// things line up across the rings.
            case byGroup
        }

        /// How many rings, and how thick.
        public var sizes: RingSizes
        public var order: Order
        /// Drawn as a piece of its own however thin, never gathered into "smaller items": a film or an episode in a
        /// library, say, that should always be there to point at. Nil for none.
        public var keep: (@Sendable (UInt32) -> Bool)?
        /// A node's piece cut into stretches side by side, in this order, such as one for each place its files are in, or for
        /// what's selected and what isn't. What's inside it is drawn under the whole piece. Nil, or nil for a node, for one
        /// piece. A node drawn in stretches isn't also cut by groups.
        public var cuts: (@Sendable (UInt32) -> [SunburstStretch]?)?

        public init(_ sizes: RingSizes = RingSizes(), order: Order = .bySize, keep: (@Sendable (UInt32) -> Bool)? = nil,
                    cuts: (@Sendable (UInt32) -> [SunburstStretch]?)? = nil) {
            self.sizes = sizes
            self.order = order
            self.keep = keep
            self.cuts = cuts
        }
    }

    /// The scale just outside the rings: a mark for every 1% of the way round, a longer one for every 10%.
    struct Dial: Sendable, Equatable {
        public enum Counts: Sendable, Equatable {
            /// Around the whole circle.
            case whole
            /// From 0 to 100% across each side of a split, since each side is a whole of its own. With no split, the whole.
            case eachSide
        }

        public var counts: Counts

        public init(counts: Counts = .whole) {
            self.counts = counts
        }
    }
}
