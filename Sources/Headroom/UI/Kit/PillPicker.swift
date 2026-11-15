import SwiftUI

/// One of a few choices, side by side in a capsule, the chosen one lit: Changes' time windows, Large Files' age, an agent's
/// access. A value that isn't among the options lights none, so two pickers can share one choice.
struct PillPicker<Value: Hashable>: View {
    let options: [Value]
    let selection: Value
    let title: (Value) -> String
    var help: ((Value) -> String)? = nil
    /// Each option as wide as the widest, filling the row, or each as wide as its words.
    var fills = true
    var height: CGFloat = 26
    let select: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isOn = option == selection
                Button {
                    select(option)
                } label: {
                    Text(title(option))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(isOn ? Color.white : Color.white.opacity(0.58))
                        .lineLimit(1)
                        .padding(.horizontal, fills ? 4 : 10)
                        .frame(maxWidth: fills ? .infinity : nil)
                        .frame(height: height)
                        .background(Capsule().fill(.white.opacity(isOn ? 0.15 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(help?(option) ?? "")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.05)))
        .fixedSize(horizontal: !fills, vertical: false)
    }
}

/// A quiet word before a picker, saying what it picks: Untouched.
struct PickerLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .fixedSize()
    }
}
