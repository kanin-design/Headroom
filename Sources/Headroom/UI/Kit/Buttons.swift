import SwiftUI

// MARK: The bar's buttons

/// The button that does what the ticks say. It's green in any window, focused or not, so it never looks switched off when it isn't.
/// Backup's is blue: it moves things rather than throwing them away, and the two must never look alike.
struct GoButton: ButtonStyle {
    var moves = false
    @Environment(\.isEnabled) private var isEnabled

    private var top: Color { moves ? Color(red: 0.25, green: 0.56, blue: 0.96) : Color(red: 0.15, green: 0.70, blue: 0.47) }
    private var bottom: Color { moves ? Color(red: 0.16, green: 0.42, blue: 0.82) : Color(red: 0.10, green: 0.54, blue: 0.35) }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Kit.Font.headline.monospacedDigit())
            .foregroundStyle(isEnabled ? Color.white : Kit.Text.quaternary)
            .frame(maxWidth: .infinity)
            .frame(height: Kit.barButtonHeight)
            .background {
                RoundedRectangle(cornerRadius: Kit.Radius.barButton, style: .continuous)
                    .fill(
                        isEnabled
                            ? AnyShapeStyle(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(Kit.Fill.track))
            }
            .overlay {
                if isEnabled {
                    RoundedRectangle(cornerRadius: Kit.Radius.barButton, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                }
            }
            .shadow(color: bottom.opacity(isEnabled ? 0.28 : 0), radius: 11, y: 6)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .contentShape(Rectangle())
    }
}

/// The quieter choice beside it, or in its place while something runs: Stop, Undo.
struct SoftButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Kit.Font.headline)
            .foregroundStyle(Kit.Text.primary)
            .padding(.horizontal, 16)
            .frame(height: Kit.barButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: Kit.Radius.barButton, style: .continuous).fill(
                    configuration.isPressed ? Kit.Fill.controlLit : Kit.Fill.control)
            )
            .contentShape(Rectangle())
    }
}

// MARK: Small buttons in rows and cards

/// How big a pill is: the size of Copies' Delete, Hardlink and Symlink, or the small one that fits on a row's line.
enum PillSize {
    case regular, small

    var font: Font { self == .regular ? Kit.Font.label : Kit.Font.caption.weight(.semibold) }
    var horizontal: CGFloat { self == .regular ? 11 : 8 }
    var vertical: CGFloat { self == .regular ? 5 : 2 }
}

/// How a pill wears its colour: filled with it and written in white, or lightly tinted and written in it.
enum PillProminence {
    case filled, tinted
}

/// A pill's look, for a button and for a label that isn't one: a capsule in a tint, or in white when it has none.
private struct PillChrome: ViewModifier {
    let tint: Color?
    let size: PillSize
    let prominence: PillProminence
    let isLit: Bool
    let isEnabled: Bool

    private var fill: Color {
        let lit = isLit && isEnabled
        guard let tint else { return isEnabled ? (lit ? Kit.Fill.controlLit : Kit.Fill.control) : Kit.Fill.card }
        switch prominence {
        case .filled: return tint.opacity(isEnabled ? (lit ? 0.42 : 0.3) : 0.12)
        case .tinted: return tint.opacity(isEnabled ? (lit ? 0.24 : 0.16) : 0.08)
        }
    }

    private var ink: Color {
        guard isEnabled else { return Kit.Text.quaternary }
        if let tint, prominence == .tinted { return tint }
        return Kit.Text.primary
    }

    func body(content: Content) -> some View {
        content
            .font(size.font)
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, size.horizontal)
            .padding(.vertical, size.vertical)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
    }
}

/// A small capsule button inside a row or a card: Clean anyway, Keep, Delete, Done, Verify all, Copy. White unless it's given
/// a tint; Copies' buttons wear their set's colour, Backup's wear the blue.
struct PillButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var size: PillSize = .regular
    var prominence: PillProminence = .filled

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, tint: tint, size: size, prominence: prominence)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color?
    let size: PillSize
    let prominence: PillProminence
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .modifier(PillChrome(tint: tint, size: size, prominence: prominence, isLit: isHovered || configuration.isPressed, isEnabled: isEnabled))
            .brightness(configuration.isPressed ? -0.05 : 0)
            .onHover { isHovered = $0 }
            .fixedSize()
    }
}

/// The same capsule for words that aren't a button, at the small size: the copy that's kept, or a menu's label.
struct PillLabel: View {
    let text: String
    var tint: Color? = nil
    var prominence: PillProminence = .filled

    var body: some View {
        Text(text)
            .modifier(PillChrome(tint: tint, size: .small, prominence: prominence, isLit: false, isEnabled: true))
            .fixedSize()
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static func pill(_ tint: Color?, size: PillSize = .regular, prominence: PillProminence = .filled) -> PillButtonStyle {
        PillButtonStyle(tint: tint, size: size, prominence: prominence)
    }
}

// MARK: Cards

/// A card that's pressed as a whole: Select recommended in Free Up, Backup's actions. In a colour of its own, or white, and
/// brighter under the pointer; dimmed while it can't be pressed.
struct CardButtonStyle: ButtonStyle {
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        CardButtonBody(configuration: configuration, tint: tint)
    }
}

private struct CardButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color?
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var fill: Color {
        let lit = isEnabled && (isHovered || configuration.isPressed)
        guard let tint else { return lit ? Kit.Fill.control : Kit.Fill.card }
        return tint.opacity(lit ? 0.18 : 0.1)
    }

    var body: some View {
        configuration.label
            .padding(.horizontal, Kit.rowInset)
            .padding(.vertical, Kit.Space.regular)
            .card(fill, hairline: false)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.6)
            .onHover { isHovered = $0 }
    }
}

extension ButtonStyle where Self == CardButtonStyle {
    static var card: CardButtonStyle { CardButtonStyle() }
    static func card(_ tint: Color?) -> CardButtonStyle { CardButtonStyle(tint: tint) }
}

// MARK: Links

/// Words that do something, with nothing round them: Deselect all, Not now, Open Trash, Select, Undo. White and quiet unless
/// it's given a tint, and brighter under the pointer. (SwiftUI's own `LinkButtonStyle` is a different thing, hence the name.)
struct TextLinkStyle: ButtonStyle {
    var tint: Color? = nil
    /// The size of the words around it, when it's among them rather than on a line of its own.
    var font: Font = Kit.Font.detail.weight(.medium)

    func makeBody(configuration: Configuration) -> some View {
        TextLinkBody(configuration: configuration, tint: tint, font: font)
    }
}

private struct TextLinkBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color?
    let font: Font
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var ink: Color {
        guard isEnabled else { return tint?.opacity(0.3) ?? Kit.Text.quaternary }
        let lit = isHovered || configuration.isPressed
        if let tint { return tint.opacity(lit ? 1 : 0.88) }
        return lit ? Kit.Text.primary : Kit.Text.secondary
    }

    var body: some View {
        configuration.label
            .font(font)
            .foregroundStyle(ink)
            .lineLimit(1)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .fixedSize()
    }
}

extension ButtonStyle where Self == TextLinkStyle {
    static var textLink: TextLinkStyle { TextLinkStyle() }
    static func textLink(_ tint: Color?, font: Font = Kit.Font.detail.weight(.medium)) -> TextLinkStyle { TextLinkStyle(tint: tint, font: font) }
}

// MARK: Symbols

/// A button that's only a symbol: Close on a message over the map, or Back and Close in a circle of their own on the card.
struct SymbolButtonStyle: ButtonStyle {
    /// Drawn in a circle this wide, or bare.
    var circle: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Kit.Font.caption.weight(.bold))
            .foregroundStyle(circle == nil ? Kit.Text.tertiary : Kit.Text.primary)
            .frame(width: circle, height: circle)
            .background {
                if circle != nil { Circle().fill(configuration.isPressed ? Kit.Fill.controlLit : Kit.Fill.control) }
            }
            .contentShape(Circle())
    }
}

extension ButtonStyle where Self == SymbolButtonStyle {
    static var symbol: SymbolButtonStyle { SymbolButtonStyle() }
    static func symbol(circle: CGFloat) -> SymbolButtonStyle { SymbolButtonStyle(circle: circle) }
}
