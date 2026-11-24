import SwiftUI

/// The inspector's shared look, in one place: its type, its text tints, its colours, its fills, its corners and its edges.
/// Views ask for a role (`Kit.Font.detail`, `Kit.Text.tertiary`), never a size or an opacity, so changing one here changes
/// it everywhere it's used. DESIGN.md, *The panel's type, tints and controls*.
enum Kit {
    // MARK: Type

    /// Five sizes a clear step apart, each with its weight, and a few more weights of the same sizes: what reads first is
    /// the biggest and the boldest. The middle of the ring, the path bar and the names around the ring have their own
    /// specced sizes (DESIGN.md, *Specs*) and don't take these.
    enum Font {
        /// A panel's or a small window's title: what a search found, the card's name, Agents, an update.
        static let title = SwiftUI.Font.system(size: Size.title, weight: .semibold)
        /// What a card, a box or a set is, and its size; a line that stands for an empty list; the big button's words.
        static let headline = SwiftUI.Font.system(size: Size.headline, weight: .semibold)
        /// A thing's name in a list: the font `FittedText` measures names with.
        static let name = SwiftUI.Font.system(size: Size.body, weight: .medium)
        /// Sentences: what a window explains, what's new.
        static let body = SwiftUI.Font.system(size: Size.body)
        /// A line that says what a list holds, or that it holds nothing: quieter than a title, louder than a name.
        static let note = SwiftUI.Font.system(size: Size.headline, weight: .medium)
        /// A name that's also something to press: Select recommended, an action, a fold, Undo.
        static let strong = SwiftUI.Font.system(size: Size.body, weight: .semibold)
        /// The line under a name, what's said about it, and a size at a line's end.
        static let detail = SwiftUI.Font.system(size: Size.detail)
        /// A section's name, a pill's words, what a picker picks.
        static let label = SwiftUI.Font.system(size: Size.detail, weight: .semibold)
        /// The least said: a count of what isn't listed, a small pill, a command.
        static let caption = SwiftUI.Font.system(size: Size.caption)
        /// A size at a row's end, with digits of equal width so a column of them lines up.
        static let number = name.monospacedDigit()
        /// A big number that stands on its own: the card's size.
        static let figure = SwiftUI.Font.system(size: Size.figure, weight: .semibold, design: .rounded).monospacedDigit()

        /// The sizes the roles are made of, for text measured with AppKit (`FittedText`).
        enum Size {
            static let figure: CGFloat = 20
            static let title: CGFloat = 18
            static let headline: CGFloat = 13
            static let body: CGFloat = 12
            static let detail: CGFloat = 11
            static let caption: CGFloat = 10
        }
    }

    // MARK: Text

    /// Text tints, from the most to the least said, a clear step apart.
    enum Text {
        /// Names and titles.
        static let primary = Color.white.opacity(0.92)
        /// Sizes and values, and what's said about a thing that should still be read.
        static let secondary = Color.white.opacity(0.7)
        /// The line under a name, a section's name, a count.
        static let tertiary = Color.white.opacity(0.5)
        /// What's switched off, a hint, an arrow at rest, what hasn't started.
        static let quaternary = Color.white.opacity(0.35)
    }

    // MARK: Colours

    /// What goes to a drive, what's selected for Backup, and every link that isn't white.
    static let blue = Color(red: 0.42, green: 0.70, blue: 1)
    /// What's done, and what you get back.
    static let green = Palette.gain
    /// What needs a look before going on.
    static let amber = Palette.amber
    /// What deletes for good.
    static let red = Palette.delete

    // MARK: Fills

    /// White fills on the dark window, from the quietest up.
    enum Fill {
        /// The band under the inspector.
        static let bar = Color.white.opacity(0.03)
        /// A card, and a picture before it's read.
        static let card = Color.white.opacity(0.05)
        /// A card's hairline, and a divider inside one.
        static let hairline = Color.white.opacity(0.07)
        /// A row under the pointer.
        static let hover = Color.white.opacity(0.07)
        /// The empty part of a bar or a ring.
        static let track = Color.white.opacity(0.08)
        /// A control at rest: a pill, a round button, a chip.
        static let control = Color.white.opacity(0.1)
        /// A control under the pointer, or pressed.
        static let controlLit = Color.white.opacity(0.17)
        /// What's on a disk already, in a bar of its room.
        static let used = Color.white.opacity(0.28)
    }

    // MARK: Shapes

    enum Radius {
        /// A card's corners: the ring cards, Free Up's boxes, Copies' sets, the actions.
        static let card: CGFloat = 12
        /// A row's corners, inside a card or a list.
        static let row: CGFloat = 9
        /// A small thing's corners: a file's line inside a row, a command.
        static let small: CGFloat = 6
        /// The big buttons under the inspector.
        static let barButton: CGFloat = 15
        /// A pane of glass in a small window.
        static let pane: CGFloat = 18
    }

    // MARK: Edges

    /// From the inspector's edge to a card's or a box's edge, in every mode, and in the bar under it.
    static let panelInset: CGFloat = 12
    /// From a card's, box's or row's edge to what's written in it. Headings use it too, so text starts at one edge.
    static let rowInset: CGFloat = 10
    /// The column a row's mark sits in: a tick, a step, an icon. The same width whatever the mark, so names line up.
    static let markSlot: CGFloat = 16
    /// How tall the big buttons under the inspector are.
    static let barButtonHeight: CGFloat = 38

    /// The room between things, a step apart.
    enum Space {
        /// A name and the line under it.
        static let hairline: CGFloat = 1
        static let tight: CGFloat = 2
        static let small: CGFloat = 4
        static let medium: CGFloat = 6
        /// A mark and its name; a row and what follows it.
        static let regular: CGFloat = 8
        /// A card's edge and what's in it; cards in a panel.
        static let large: CGFloat = 12
        /// Sections of a panel.
        static let section: CGFloat = 14
    }
}

extension View {
    /// The one card: a rounded rectangle in the card's fill with its hairline, or in a fill of its own (a box's colour, a
    /// warning's amber) without one.
    func card(_ fill: Color = Kit.Fill.card, hairline: Bool = true, radius: CGFloat = Kit.Radius.card) -> some View {
        modifier(CardChrome(fill: fill, hairline: hairline, radius: radius))
    }
}

/// The card's fill, and its hairline only where it has one: an overlay with nothing in it is still laid out, in every row of a
/// long list such as Copies' sets.
private struct CardChrome: ViewModifier {
    let fill: Color
    let hairline: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if hairline {
            content.background(shape.fill(fill)).overlay(shape.strokeBorder(Kit.Fill.hairline))
        } else {
            content.background(shape.fill(fill))
        }
    }
}
