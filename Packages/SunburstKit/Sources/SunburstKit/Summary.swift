import Foundation

/// What's on a chart's ring, in words: for an app's own logic, a test, or an agent.
public struct SunburstSummary: Codable, Sendable, Equatable {
    /// One piece of the ring.
    public struct Piece: Codable, Sendable, Equatable {
        /// The node it stands for, as the other calls take it.
        public var node: UInt32
        public var name: String
        public var size: UInt64
        public var sizeText: String
        /// Its share of the node in the middle, from 0 to 1.
        public var share: Double
        /// Which level, from 0 in the middle, counting bands and a split (`RingLayout.levels`).
        public var ring: Int
        /// The node it sits in.
        public var inside: UInt32
        /// Where it starts and ends, in degrees clockwise from 12 o'clock.
        public var from: Double
        public var to: Double
        /// Whether it gathers what's too small to draw alone.
        public var isGathered: Bool
        /// Whether it's drawn striped (`SunburstChart.marked`, or `isMarked`).
        public var isMarked: Bool
    }

    /// The node in the middle, its name and size.
    public var focus: UInt32
    public var name: String
    public var size: UInt64
    public var sizeText: String
    /// How many rings are drawn.
    public var rings: Int
    /// The node under the pointer, if any.
    public var hovered: UInt32?
    /// The biggest pieces, biggest first.
    public var pieces: [Piece]
    /// How many smaller pieces aren't listed.
    public var more: Int
}
