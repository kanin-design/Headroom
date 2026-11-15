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
            .font(.system(size: 14, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.42))
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(isEnabled ? AnyShapeStyle(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(.white.opacity(0.08)))
            }
            .overlay {
                if isEnabled {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
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
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(.white.opacity(configuration.isPressed ? 0.16 : 0.1)))
            .contentShape(Rectangle())
    }
}

// MARK: Small buttons in rows and cards

/// How big a pill is: the size of Copies' Delete, Hardlink and Symlink, or the small one that fits on a row's line.
enum PillSize {
    case regular, small

    var font: Font { self == .regular ? .system(size: 11.5, weight: .semibold) : .system(size: 10.5, weight: .semibold) }
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
        guard let tint else { return .white.opacity(isEnabled ? (lit ? 0.17 : 0.1) : 0.06) }
        switch prominence {
        case .filled: return tint.opacity(isEnabled ? (lit ? 0.42 : 0.3) : 0.12)
        case .tinted: return tint.opacity(isEnabled ? (lit ? 0.24 : 0.16) : 0.08)
        }
    }

    private var ink: Color {
        guard isEnabled else { return .white.opacity(0.4) }
        if let tint, prominence == .tinted { return tint }
        return .white.opacity(tint == nil ? 0.88 : 0.95)
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

/// The same capsule for words that aren't a button: the copy that's kept, or a menu's label.
struct PillLabel: View {
    let text: String
    var tint: Color? = nil
    var size: PillSize = .small
    var prominence: PillProminence = .filled
    var isLit = false

    var body: some View {
        Text(text)
            .modifier(PillChrome(tint: tint, size: size, prominence: prominence, isLit: isLit, isEnabled: true))
            .fixedSize()
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static func pill(_ tint: Color?, size: PillSize = .regular, prominence: PillProminence = .filled) -> PillButtonStyle {
        PillButtonStyle(tint: tint, size: size, prominence: prominence)
    }
}

// MARK: Links

/// Words that do something, with nothing round them: Deselect all, Not now, Open Trash, Select. White and quiet unless it's
/// given a tint, and brighter under the pointer. (SwiftUI's own `LinkButtonStyle` is a different thing, hence the name.)
struct TextLinkStyle: ButtonStyle {
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        TextLinkBody(configuration: configuration, tint: tint)
    }
}

private struct TextLinkBody: View {
    let configuration: ButtonStyleConfiguration
    let tint: Color?
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var ink: Color {
        guard isEnabled else { return (tint ?? .white).opacity(0.3) }
        let lit = isHovered || configuration.isPressed
        if let tint { return tint.opacity(lit ? 1 : 0.88) }
        return .white.opacity(lit ? 0.88 : 0.6)
    }

    var body: some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(ink)
            .lineLimit(1)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .fixedSize()
    }
}

extension ButtonStyle where Self == TextLinkStyle {
    static var textLink: TextLinkStyle { TextLinkStyle() }
    static func textLink(_ tint: Color?) -> TextLinkStyle { TextLinkStyle(tint: tint) }
}
