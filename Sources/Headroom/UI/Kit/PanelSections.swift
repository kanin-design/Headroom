import SwiftUI

/// A section's name over what's in it, and on the right, how many or how much. In the inspector its text starts where rows'
/// text does; in a small window, at the window's edge.
struct SectionHeading: View {
    let text: String
    var trailing: String? = nil
    var colour: Color = Kit.Text.tertiary
    var inset: CGFloat = Kit.rowInset
    /// What the name means, where it needs saying, for pointing at it.
    var help: String? = nil

    var body: some View {
        HStack {
            Text(text)
                .font(Kit.Font.label)
                .foregroundStyle(colour)
                .help(help ?? "")
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(Kit.Font.detail.monospacedDigit())
                    .foregroundStyle(Kit.Text.tertiary)
            }
        }
        .padding(.horizontal, inset)
    }
}

/// A titled group in a panel or a small window: the heading, then what's in it.
struct PanelSection<Content: View>: View {
    let title: String
    var trailing: String? = nil
    var inset: CGFloat = Kit.rowInset
    var spacing: CGFloat = Kit.Space.small
    var help: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            SectionHeading(text: title, trailing: trailing, inset: inset, help: help)
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
                .font(Kit.Font.note)
                .foregroundStyle(Kit.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(Kit.Font.detail)
                    .foregroundStyle(Kit.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Kit.rowInset)
        .padding(.vertical, Kit.Space.medium)
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
        VStack(alignment: .leading, spacing: Kit.Space.small) {
            Button {
                Motion.animate(.snappy(duration: 0.22)) {
                    if let isOpen { isOpen.wrappedValue.toggle() } else { openHere.toggle() }
                }
            } label: {
                HStack(spacing: Kit.Space.medium) {
                    DisclosureChevron(isOpen: open)
                        .foregroundStyle(Kit.Text.tertiary)
                        .frame(width: 10)
                    Text(title)
                        .font(Kit.Font.strong)
                        .foregroundStyle(Kit.Text.secondary)
                    if let count {
                        Text(count)
                            .font(Kit.Font.detail.monospacedDigit())
                            .foregroundStyle(Kit.Text.tertiary)
                    }
                    Spacer()
                    if let trailing {
                        Text(trailing)
                            .font(Kit.Font.detail.monospacedDigit())
                            .foregroundStyle(Kit.Text.tertiary)
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

/// The line under a list that was cut short: how many more there are.
struct MoreLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Kit.Font.caption)
            .foregroundStyle(Kit.Text.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 3)
    }
}

/// One line in a fold of kept things: what it is, and the way to have it suggested again. Not a `ListRow`: it has no mark
/// and no value, only a path and a button.
struct KeptLine: View {
    let title: String
    let again: () -> Void

    var body: some View {
        HStack(spacing: Kit.Space.regular) {
            // Often a path: cut between its folders, never inside a name.
            FittedText(forms: ListNames.folderForms(title), font: FittedText.detail)
                .foregroundStyle(Kit.Text.secondary)
                .padding(.trailing, Kit.Space.large)
            Button("Suggest again", action: again)
                .buttonStyle(.pill(nil, size: .small))
        }
        .padding(.leading, Kit.rowInset + Kit.markSlot)
        .padding(.trailing, Kit.rowInset)
        .padding(.vertical, Kit.Space.hairline)
    }
}

/// The bar under the inspector, in every mode: the big button and what goes with it, its edges lined up with the cards'.
struct BarChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Kit.panelInset)
            .padding(.vertical, Kit.Space.section)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Kit.Fill.bar)
    }
}
