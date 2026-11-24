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

/// A named thing with the pointer on it or not, for the named things inside it: a file in an opened row is inside the row.
/// When the pointer leaves the file and is still on the row, the row is what's pointed at again.
final class PointedAt {
    var thing: NamedThing?
    var isInside = false

    /// What's pointed at once the pointer has left `thing`, which sits inside `enclosing` if anything. Something else
    /// that's already pointed at stays: going from one row to the next can arrive in either order. So can leaving a row
    /// and what it's in at once, which is why what it's in is asked whether the pointer is still there.
    static func afterLeaving(_ thing: NamedThing, pointed: NamedThing?, enclosing: PointedAt?) -> NamedThing? {
        guard pointed?.nodes == thing.nodes else { return pointed }
        return enclosing?.isInside == true ? enclosing?.thing : nil
    }

    /// What lights on the ring once the pointer has left something inside `enclosing`: what it's in, while the pointer
    /// is still on that, and otherwise nothing.
    static func litAfterLeaving(inside enclosing: PointedAt?) -> [UInt32] {
        enclosing?.isInside == true ? enclosing?.thing?.nodes ?? [] : []
    }
}

extension EnvironmentValues {
    /// The named thing this view is inside, if any.
    @Entry var enclosingThing: PointedAt?
}

private struct Named: ViewModifier {
    let model: AppModel
    let thing: NamedThing
    @Environment(\.enclosingThing) private var enclosing
    @State private var here = PointedAt()

    func body(content: Content) -> some View {
        here.thing = thing
        return
            content
            .environment(\.enclosingThing, here)
            .contextMenu { ThingMenu(model: model, thing: thing) }
            .highPriorityGesture(TapGesture().modifiers(.command).onEnded { model.copyName(of: thing) })
            .onHover { inside in
                here.isInside = inside
                if inside {
                    model.pointedThing = thing
                } else {
                    model.pointedThing = PointedAt.afterLeaving(thing, pointed: model.pointedThing, enclosing: enclosing)
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
                .font(Kit.Font.caption.weight(.semibold))
                .foregroundStyle(Kit.Text.tertiary)
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
