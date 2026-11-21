import AppKit
import SwiftUI

/// The ring in the window: SunburstKit's view, driven by the map's chart, which takes its pointer, clicks, keys and VoiceOver.
typealias MapHostView = SunburstView

struct MapView: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> MapHostView {
        let view = MapHostView(engine: model.engine)
        // Hold Option to see the disk as it will be after the clean. With ⌘ it's part of a shortcut.
        view.onModifiers = { [weak model] event in
            model?.setPreviewAfter(event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.command))
        }
        view.onVisibility = { [weak model] isVisible in model?.windowCameOrWent(isVisible: isVisible) }
        model.mapView = view
        // Before the view is in its window, so it has the keyboard, and moves the window, from the start.
        model.chart.attach(to: view)
        return view
    }

    func updateNSView(_ view: MapHostView, context: Context) {}
}
