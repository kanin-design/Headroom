/// What a node is. It sets how the node's piece looks, wherever in the chart it's drawn.
///
/// A role is the app's word for a node, in the kit's terms: Headroom's free space is `room`, a budget's money not yet
/// spent would be too, and both are drawn the same way, so whoever knows one chart can read the other.
public enum SunburstRole: UInt8, Sendable, CaseIterable {
    /// Something that holds things, such as a folder: shaded from deep at the middle to bright at the edge.
    case container
    /// The end of a branch, such as a file.
    case item
    /// Room that isn't used, such as free space on a disk: plain, nearly empty, with a fine edge. Around the whole tree it
    /// closes the circle as a wedge (see `RingLayout`).
    case room
    /// Something that's there but can't be looked into: hatched. Around the whole tree it closes the circle too.
    case unreadable
    /// Something that isn't here any more, drawn where it was: its colour, nearly empty, with a clear outline.
    case gone

    /// Room and what can't be read: around the whole tree, these close the circle as wedges rather than rings of things.
    @inlinable public var isSpace: Bool { self == .room || self == .unreadable }
}
