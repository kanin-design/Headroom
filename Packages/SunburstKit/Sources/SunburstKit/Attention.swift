/// Who points at the ring. Three things can, and the first that does wins: the pointer on the ring, a node that a name or
/// the app points at, and a node held while nothing else is pointed at, as while a card about it is open.
///
/// It only keeps who points; which piece that is depends on the picture, and is asked of each picture as it comes
/// (`pointedPiece(in:tree:)`), so what's pointed at stays lit while the pieces move under it.
struct RingAttention {
    /// Where the pointer is over the ring, if it is.
    private(set) var pointer: Polar?
    /// A node pointed at from outside the ring: by a name, or by the app for a row in a list.
    private(set) var pointed: UInt32?
    /// A node kept lit whenever nothing else is pointed at.
    private(set) var held: UInt32?
    /// Whether the pointer on the ring was the last to point. Then something drawn over the ring taking the pointer puts the
    /// light out; what a name or the app lit stays.
    private(set) var isThePointers = true

    /// The pointer moved over the ring, or left it (nil). It takes over from whatever else pointed.
    mutating func pointerMoved(to point: Polar?) {
        pointer = point
        pointed = nil
        isThePointers = true
    }

    /// Something drawn over the ring has the pointer now. Says whether what was lit should go: if the pointer lit it.
    mutating func pointerCovered() -> Bool {
        pointer = nil
        return isThePointers
    }

    /// A name or the app points at a node, or with nil, stops. The pointer takes over again when it next moves on the ring.
    mutating func point(at node: UInt32?) {
        pointer = nil
        pointed = node
        isThePointers = false
    }

    /// A node is held, or with nil, let go. Holding one takes over at once, even from a pointer resting on the ring.
    mutating func hold(_ node: UInt32?) {
        held = node
        guard node != nil else { return }
        pointer = nil
        pointed = nil
        isThePointers = false
    }

    /// The app lights something of its own instead: what a name or the app pointed at is let go. A pointer resting on the
    /// ring is still there, and lights what's under it again when the picture next changes.
    mutating func letGoOfPointed() {
        pointed = nil
    }

    /// The piece pointed at in a picture: under the pointer, or else the pointed node's, or what holds it if it's too small
    /// to have one. Nil when nothing points, or it points at nothing in view.
    func pointedPiece<T: SunburstTree>(in layout: RingLayout, tree: T) -> Int? {
        if let pointer, let under = layout.hit(angle: pointer.angle, radius: pointer.radius) { return under }
        return pointed.flatMap { layout.nearestPiece(to: $0, tree: tree) }
    }

    /// The held node's piece in a picture, if it has one in view.
    func heldPiece<T: SunburstTree>(in layout: RingLayout, tree: T) -> Int? {
        held.flatMap { layout.nearestPiece(to: $0, tree: tree) }
    }
}
