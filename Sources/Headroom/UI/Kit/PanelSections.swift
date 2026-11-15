import SwiftUI

/// A section's name over what's in it, and on the right, how many or how much. Its text starts where rows' text does.
struct SectionHeading: View {
    let text: String
    var trailing: String? = nil
    var colour: Color = .white.opacity(0.5)

    var body: some View {
        HStack {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(colour)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, Kit.rowInset)
    }
}

/// A titled group in a panel: the heading, then what's in it.
struct PanelSection<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeading(text: title, trailing: trailing)
            content()
        }
    }
}

/// What a list says when there's nothing in it: a line, and perhaps a quieter one under it.
struct EmptyNote: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Kit.rowInset)
        .padding(.vertical, 6)
    }
}

/// A section that stays folded until it's wanted: an arrow, its name, how many, and on the right how much. Free Up's other
/// actions and kept things, Copies' hardlinks and symlinks, and Backup's kept files all fold this way.
struct Fold<Content: View>: View {
    let title: String
    var count: String? = nil
    var trailing: String? = nil
    var help: String? = nil
    /// Where it's remembered as open, when something outside keeps that. Otherwise it keeps it itself.
    var isOpen: Binding<Bool>? = nil
    @ViewBuilder let content: () -> Content
    @State private var openHere = false

    private var open: Bool { isOpen?.wrappedValue ?? openHere }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Motion.animate(.snappy(duration: 0.22)) {
                    if let isOpen { isOpen.wrappedValue.toggle() } else { openHere.toggle() }
                }
            } label: {
                HStack(spacing: 6) {
                    DisclosureChevron(isOpen: open, size: 9)
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 10)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    if let count {
                        Text(count)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                    if let trailing {
                        Text(trailing)
                            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Kit.rowInset)
            .help(help ?? "")
            if open { content() }
        }
    }
}

/// One line in a fold of kept things: what it is, and the way to have it suggested again.
struct KeptLine: View {
    let title: String
    let again: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button("Suggest again", action: again)
                .buttonStyle(.pill(nil, size: .small))
        }
        .padding(.leading, Kit.rowInset + 16)
        .padding(.trailing, Kit.rowInset)
        .padding(.vertical, 1)
    }
}

/// The bar under the inspector, in every mode: the big button and what goes with it, its edges lined up with the cards'.
struct BarChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Kit.panelInset)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.03))
    }
}
