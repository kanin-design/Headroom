import SwiftUI

/// The one selection mark: a rounded square in the colour of what it selects, filled with a tick when all of it is selected,
/// half filled with a bar when some is, empty when none is. Free Up's boxes and things, Copies' sets and Backup's files all
/// wear it, so the list is the ring's legend. A run's steps aren't selections: they're drawn in the same slot by their rows.
struct TickMark: View {
    let state: TickState
    var color: Color = Palette.gain
    var size: CGFloat = 18
    var isLit = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .fill(state == .all ? color : (state == .some ? color.opacity(0.42) : .clear))
            RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                .strokeBorder(color.opacity(state == .none ? (isLit ? 1 : 0.78) : 1), lineWidth: size > 17 ? 1.6 : (size < 13 ? 1.1 : 1.3))
            if state == .all {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.52, weight: .heavy))
                    .foregroundStyle(.black.opacity(0.82))
            } else if state == .some {
                Image(systemName: "minus")
                    .font(.system(size: size * 0.52, weight: .heavy))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(isLit ? 0.5 : 0), radius: isLit ? 5 : 0)
    }
}

extension TickMark {
    /// A plain on-or-off tick.
    init(_ isOn: Bool, color: Color, size: CGFloat = 14, isLit: Bool = false) {
        self.init(state: isOn ? .all : .none, color: color, size: size, isLit: isLit)
    }
}

extension TickState {
    /// What a row is filled with: its own colour once something in it is ticked, and more of it under the pointer. A small
    /// row inside an open box is a little quieter than a box.
    func rowFill(_ tint: Color, isLit: Bool, small: Bool = false) -> Color {
        switch self {
        case .all: tint.opacity(isLit ? 0.2 : (small ? 0.1 : 0.14))
        case .some: tint.opacity(isLit ? 0.13 : 0.07)
        case .none: isLit ? Kit.Fill.hover : .clear
        }
    }
}

/// The arrow on anything that opens. It points down when it's open. A box at the top of a list has the large one.
struct DisclosureChevron: View {
    let isOpen: Bool
    var isLarge = false

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: isLarge ? 11 : 9.5, weight: .bold))
            .rotationEffect(.degrees(isOpen ? 90 : 0))
    }
}

/// The arrow that opens what's in a row, apart from the row's own click: quiet at rest, brighter on the row under the
/// pointer and while it's open. Free Up's things, the folders inside them and Copies' sets have it.
struct DisclosureButton: View {
    let isOpen: Bool
    /// The row it's on is under the pointer.
    let isLit: Bool
    /// What a click does, open and shut: "Hide contents", "Show contents".
    let help: (hide: String, show: String)
    var width: CGFloat = Kit.markSlot
    let toggle: () -> Void

    var body: some View {
        Button {
            Motion.animate(.snappy(duration: 0.22)) { toggle() }
        } label: {
            DisclosureChevron(isOpen: isOpen)
                .foregroundStyle(isLit || isOpen ? Kit.Text.secondary : Kit.Text.quaternary)
                .frame(width: width, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? help.hide : help.show)
    }
}
