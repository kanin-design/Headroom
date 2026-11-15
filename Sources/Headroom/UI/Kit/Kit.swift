import SwiftUI

/// The inspector's shared look, in one place: its colours, its corners and its edges. Every control in `UI/Kit` takes these,
/// so changing one here changes it everywhere it's used.
enum Kit {
    // MARK: Colours

    /// What goes to a drive, what's selected for Backup, and every link that isn't white.
    static let blue = Color(red: 0.42, green: 0.70, blue: 1)
    /// What's done, and what you get back.
    static let green = Palette.gain
    /// What needs a look before going on.
    static let amber = Palette.amber
    /// What deletes for good.
    static let red = Palette.delete

    /// Text, from the most to the least said.
    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.45)

    /// A card or a row's fill and its hairline, and a row's fill under the pointer.
    static let cardFill = Color.white.opacity(0.05)
    static let cardStroke = Color.white.opacity(0.07)
    static let hoverFill = Color.white.opacity(0.06)

    // MARK: Shapes

    /// A card's corners: the ring cards, Free Up's boxes, Copies' sets, the actions.
    static let cardRadius: CGFloat = 12
    /// A row's corners, inside a card or a list.
    static let rowRadius: CGFloat = 9

    // MARK: Edges

    /// From the inspector's edge to a card's or a box's edge, in every mode, and in the bar under it.
    static let panelInset: CGFloat = 12
    /// From a card's, box's or row's edge to what's written in it. Headings use it too, so text starts at one edge.
    static let rowInset: CGFloat = 10
    /// The column a row's mark sits in: a tick, a step, an icon. The same width whatever the mark, so names line up.
    static let markSlot: CGFloat = 16
}
