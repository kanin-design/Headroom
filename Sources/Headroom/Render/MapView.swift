import AppKit
import SwiftUI

/// The ring in the window: SunburstKit's view, with what the pointer and the keys do on the disk map.
typealias MapHostView = SunburstView

struct MapView: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> MapHostView {
        let view = MapHostView(engine: model.engine)
        Self.connect(view, to: model)
        model.mapView = view
        return view
    }

    func updateNSView(_ view: MapHostView, context: Context) {}

    private static func connect(_ view: MapHostView, to model: AppModel) {
        view.polar = { [weak model] p in model?.polar(p) }
        view.onHover = { [weak model] polar in model?.pointerMoved(to: polar) }
        view.onHoverCovered = { [weak model] in model?.pointerOffRing() }
        view.onClick = { [weak model] polar, count in model?.click(at: polar, count: count) }
        // ⌘-click copies the name of what's under it, and that's all it does.
        view.onCommandClick = { [weak model] polar in
            if let model, let thing = model.thing(at: polar) { model.copyName(of: thing) }
        }
        view.menuAt = { [weak model] polar in
            guard let model, let thing = model.thing(at: polar) else { return nil }
            return model.menu(for: thing)
        }
        view.onPinch = { [weak model] opening, polar in
            if opening { model?.click(at: polar) } else { model?.goUp() }
        }
        view.onKey = { [weak model] event in
            guard let model else { return false }
            // In Free Up the keyboard steps through the list: nothing here does anything until you clean.
            if model.mode == .freeUp, model.handlePlanKey(event) { return true }
            switch event.keyCode {
            case 53, 51: model.goUp()                 // escape, delete
            case 49:                                  // space selects; with shift, the card
                if event.modifierFlags.contains(.shift) { model.toggleLook() } else { model.spaceSelect() }
            default: return false
            }
            return true
        }
        // Hold Option to see the disk as it will be after the clean. With ⌘ it's part of a shortcut.
        view.onModifiers = { [weak model] event in
            model?.setPreviewAfter(event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.command))
        }
        view.onVisibility = { [weak model] isVisible in model?.windowCameOrWent(isVisible: isVisible) }

        // To VoiceOver the map is a group of what's in the folder you're in, biggest first, each with its size and its share
        // of the folder. Pressing one does what a click does: a folder opens, a file is selected.
        view.accessibilityKind = "disk map"
        view.accessibilityName = { [weak model] in
            guard let model else { return "Disk map" }
            return "Map of " + (model.focus == 0 ? (model.volume?.shownName ?? "the disk") : model.displayName(model.focus))
        }
        view.accessibilityPicture = { [weak model] in
            guard let model, model.tree != nil, model.ring.radius > 0 else { return nil }
            return ("\(model.focus) \(model.treeVersion)", model.ring.center, model.ring.radius)
        }
        view.describePiece = { [weak model] piece, share in
            (model?.displayName(piece: piece) ?? "", "\(formatBytes(piece.bytes)), \(Int((share * 100).rounded()))%")
        }
        view.onPress = { [weak model] index in model?.click(piece: index) }
    }
}
