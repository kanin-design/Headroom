import AppKit
import SwiftUI

// The small pieces the inspector's lists are made of.

/// The tick for a box or a thing, in its colour, so the list is the ring's legend.
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
                .strokeBorder(color.opacity(state == .none ? (isLit ? 1 : 0.78) : 1), lineWidth: size > 17 ? 1.6 : 1.3)
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

/// A file's icon as the Finder shows it. Asking for one reads the disk, and a row asks every time it redraws, which is
/// every time the pointer moves over it: so each is asked for once and kept.
@MainActor
enum FileIcons {
    private static let known = NSCache<NSString, NSImage>()

    static func icon(for path: String) -> NSImage {
        if let found = known.object(forKey: path as NSString) { return found }
        let icon = NSWorkspace.shared.icon(forFile: path)
        known.setObject(icon, forKey: path as NSString)
        return icon
    }
}

struct AppIcon: View {
    let path: String

    var body: some View {
        Image(nsImage: FileIcons.icon(for: path))
            .resizable()
            .frame(width: 17, height: 17)
            .padding(.vertical, -3)
    }
}

/// The words on a small button inside a row.
struct CapsuleLabel: View {
    let text: String
    var isLit = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(.white.opacity(isLit ? 0.18 : 0.1)))
    }
}

extension TickState {
    /// What a row is filled with: its own colour once something in it is ticked, and more of it under the pointer. A small
    /// row inside an open box is a little quieter than a box.
    func rowFill(_ tint: Color, isLit: Bool, small: Bool = false) -> Color {
        switch self {
        case .all: tint.opacity(isLit ? 0.2 : (small ? 0.1 : 0.14))
        case .some: tint.opacity(isLit ? 0.13 : 0.07)
        case .none: .white.opacity(isLit ? 0.07 : 0)
        }
    }
}

/// The arrow on anything that opens. It points down when it's open.
struct DisclosureChevron: View {
    let isOpen: Bool
    var size: CGFloat = 9.5

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: size, weight: .bold))
            .rotationEffect(.degrees(isOpen ? 90 : 0))
    }
}
