import SwiftUI

/// A choice of one out of a few, as macOS draws it: its own segmented control, as wide as its words. The toolbar's two
/// pickers and the inspector's (Changes' time windows, Large Files' age, an agent's access) are this one control, small in
/// the inspector. A value that isn't among the options lights none, so two pickers can share one choice.
struct Segmented<Value: Hashable>: View {
    /// What VoiceOver calls it.
    let name: String
    let options: [Value]
    let selection: Value
    let title: (Value) -> String
    var help: ((Value) -> String)? = nil
    /// Small in the inspector. Nil leaves it the size of where it is: the toolbar sizes its own.
    var size: ControlSize? = .small
    let select: (Value) -> Void

    var body: some View {
        // Nil while the choice is one of another picker's options.
        let chosen = Binding<Value?>(get: { options.contains(selection) ? selection : nil }, set: { if let new = $0 { select(new) } })
        let picker = Picker(name, selection: chosen) {
            ForEach(options, id: \.self) { option in
                Text(title(option))
                    .help(help?(option) ?? "")
                    .tag(Optional(option))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        if let size { picker.controlSize(size) } else { picker }
    }
}

/// A quiet word before a picker, saying what it picks: Untouched.
struct PickerLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Kit.Font.label)
            .foregroundStyle(Kit.Text.tertiary)
            .fixedSize()
    }
}
