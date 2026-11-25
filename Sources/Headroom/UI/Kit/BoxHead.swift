import SwiftUI

/// The head of a box: a mark, the title with its size at the end of its line, a line under it with what can be done at its
/// end, and a bar. Free Up's boxes, the things in them and Copies' sets are all this head, so they read alike: large at the
/// top of a list, small inside an open box. Each says what fills it and what pointing at it and clicking it do.
struct BoxHead<Mark: View, Value: View, Line: View, Accessory: View, Bar: View>: View {
    let title: String
    /// Shorter ways to write the title, longest first, after the title itself, worked out among the list's titles
    /// (`ListNames`): the longest that fits is used.
    var titles: [String] = []
    /// An app's icon before its name, by the app's path.
    var app: String? = nil
    var isLarge = true
    @ViewBuilder let mark: () -> Mark
    @ViewBuilder let value: () -> Value
    @ViewBuilder let line: () -> Line
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let bar: () -> Bar

    var body: some View {
        HStack(alignment: .top, spacing: isLarge ? Kit.rowInset : Kit.Space.regular) {
            mark()
                .padding(.top, Kit.Space.hairline)
            VStack(alignment: .leading, spacing: Kit.Space.hairline) {
                HStack(alignment: .firstTextBaseline, spacing: Kit.Space.regular) {
                    // A stack of its own only round an icon. The line is set on the title's baseline, and a stack's baseline
                    // is found by laying out what's in it, on every row each time the list is measured: Copies' sixty
                    // sets made every step of a window resize miss its frame.
                    if let app {
                        HStack(spacing: Kit.Space.medium) {
                            AppIcon(path: app)
                            titleText
                        }
                    } else {
                        titleText
                    }
                    Spacer(minLength: Kit.Space.tight)
                    value()
                }
                HStack(spacing: Kit.Space.medium) {
                    line()
                    Spacer(minLength: 0)
                    accessory()
                }
                .frame(minHeight: 15)
                bar()
            }
        }
    }

    private var titleText: some View {
        FittedText(forms: titles.count > 1 ? titles : [title], font: isLarge ? FittedText.headline : FittedText.title)
            .foregroundStyle(Kit.Text.primary)
    }
}

/// A box's size at the end of its title's line, as loud as its title: what's large is bold and white, what's small a step
/// quieter. In amber when it frees less than it looks.
struct BoxValue: View {
    let text: String
    let isLarge: Bool
    var colour: Color? = nil

    var body: some View {
        Text(text)
            .font(isLarge ? Kit.Font.headline.monospacedDigit() : Kit.Font.number)
            .foregroundStyle(colour ?? (isLarge ? Kit.Text.primary : Kit.Text.secondary))
    }
}
