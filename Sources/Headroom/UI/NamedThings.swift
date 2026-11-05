import SwiftUI

/// What you can do with something that has a name, in a right-click menu.
private struct ThingMenu: View {
    let model: AppModel
    let thing: NamedThing

    var body: some View {
        ForEach(model.actions(for: thing)) { action in
            if action.startsGroup { Divider() }
            if action.submenu.isEmpty {
                ThingMenuItem(action: action)
            } else {
                Menu {
                    ThingMenuItems(actions: action.submenu)
                } label: {
                    Label(action.title, systemImage: action.symbol)
                }
            }
        }
    }
}

/// The lines of a submenu.
struct ThingMenuItems: View {
    let actions: [ThingAction]

    var body: some View {
        ForEach(actions) { action in
            if action.startsGroup { Divider() }
            ThingMenuItem(action: action)
        }
    }
}

private struct ThingMenuItem: View {
    let action: ThingAction

    var body: some View {
        Button(action: action.run) {
            Label(action.title, systemImage: action.symbol)
        }
        .keyboardShortcut(action.shortcut)
        .disabled(action.isNote)
    }
}

private struct Named: ViewModifier {
    let model: AppModel
    let thing: NamedThing

    func body(content: Content) -> some View {
        content
            .contextMenu { ThingMenu(model: model, thing: thing) }
            .highPriorityGesture(TapGesture().modifiers(.command).onEnded { model.copyName(of: thing) })
            .onHover { inside in
                if inside {
                    model.pointedThing = thing
                } else if model.pointedThing?.nodes == thing.nodes {
                    // Going from one row to the next can arrive in either order.
                    model.pointedThing = nil
                }
            }
    }
}

/// Click it and it's on the clipboard. For names that don't do anything else when clicked.
private struct ClickToCopy: ViewModifier {
    let copy: () -> Void
    let help: String
    @State private var isHovered = false

    func body(content: Content) -> some View {
        HStack(spacing: 6) {
            content
            Image(systemName: "doc.on.doc")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .opacity(isHovered ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: copy)
        .pointerStyle(.link)
        .help(help)
    }
}

extension View {
    /// Makes this the name of something: right-click it for what you can do with it, ⌘-click it to copy the name, and whatever
    /// a shortcut does while you're pointing at it applies to it.
    func named(_ thing: NamedThing, in model: AppModel) -> some View {
        modifier(Named(model: model, thing: thing))
    }

    @ViewBuilder
    func clickToCopy(_ copy: (() -> Void)?, help: String) -> some View {
        if let copy {
            modifier(ClickToCopy(copy: copy, help: help))
        } else {
            self
        }
    }
}
