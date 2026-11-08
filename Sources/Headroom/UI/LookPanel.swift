import AppKit
import SwiftUI

/// The card Space opens, as a window of its own. It floats over the map, moves wherever it's dragged, takes the size it's
/// given and opens there again next time. It never takes the keyboard from the main window, so Space, Esc and the arrows
/// work as before, and it's out of sight while you're in another app.
@MainActor
final class LookPanel: NSObject, NSWindowDelegate {
    static let shared = LookPanel()

    private(set) var window: NSPanel?
    private weak var model: AppModel?
    private var miniaturizing: Any?
    private static let autosaveName = "Look"

    func show(for model: AppModel) {
        self.model = model
        let panel = window ?? make(for: model)
        if window == nil {
            window = panel
            // Where you left it last time, or beside the piece the first time. A scripted check always starts beside it.
            let restored = AppModel.remembersWindow && panel.setFrameUsingName(Self.autosaveName) && isOnAScreen(panel.frame)
            if !restored { panel.setFrame(firstFrame(for: model), display: false) }
            if AppModel.remembersWindow { panel.setFrameAutosaveName(Self.autosaveName) }
            watchMainWindow(of: model)
        }
        if !panel.isVisible { panel.orderFront(nil) }
        fit()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func make(for model: AppModel) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                            styleMask: [.titled, .fullSizeContentView, .resizable, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        // A scripted check runs in the background, where a panel that hides with the app would never be seen.
        panel.hidesOnDeactivate = ScriptRunner.path == nil
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.minSize = NSSize(width: 360, height: 260)
        panel.delegate = self
        let host = NSHostingView(rootView: LookWindow(model: model))
        // Its size is set here, never by SwiftUI, so nothing animates the window's size behind its back.
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    /// The first time, beside the piece, on the side of the ring away from it.
    private func firstFrame(for model: AppModel) -> NSRect {
        let isFolder = model.look.flatMap { look in model.tree.map { LookContents.isFolder(look.node, in: $0) } } ?? false
        let width: CGFloat = isFolder ? 420 : 620, height: CGFloat = 520
        guard let main = model.mapView?.window else {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return NSRect(x: screen.midX - width / 2, y: screen.midY - height / 2, width: width, height: height)
        }
        let mapWidth = min(model.ring.mapWidth, main.frame.width)
        let onLeft = model.look?.onLeft ?? true
        let x = onLeft ? main.frame.minX + 16 : main.frame.minX + max(mapWidth - 16 - width, 16)
        return NSRect(x: x, y: main.frame.midY - height / 2 - 12, width: width, height: height)
    }

    private func isOnAScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(frame.insetBy(dx: 40, dy: 40)) }
    }

    /// Minimizing the main window puts the card away with it.
    private func watchMainWindow(of model: AppModel) {
        guard miniaturizing == nil, let main = model.mapView?.window else { return }
        miniaturizing = NotificationCenter.default.addObserver(forName: NSWindow.willMiniaturizeNotification, object: main, queue: .main) { _ in
            MainActor.assumeIsolated { LookPanel.shared.model?.closeLook() }
        }
    }

    // MARK: A film's or a picture's own shape

    /// A film or a picture gets its own shape, so there's no band above or below it: as wide as the window is, as tall as
    /// that makes it, with its top where it was. Anything else keeps the size it was given.
    func fit() {
        guard let panel = window, panel.isVisible, let target = shaped(width: panel.frame.width, on: panel.screen) else { return }
        var frame = panel.frame
        guard abs(target.height - frame.height) > 1 || abs(target.width - frame.width) > 1 else { return }
        frame.origin.y = frame.maxY - target.height
        frame.size = target
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.isReduced ? 0 : 0.2
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// Dragging an edge keeps the shape too.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        shaped(width: frameSize.width, on: sender.screen) ?? frameSize
    }

    /// The window's size for this width, with the card's own parts above and below the picture. Too tall for the screen,
    /// it's narrower instead.
    private func shaped(width: CGFloat, on screen: NSScreen?) -> NSSize? {
        guard let model, let look = model.look, model.lookDetails.node == look.node, let aspect = model.lookDetails.aspect,
              aspect > 0, model.lookChrome > 0 else { return nil }
        let chrome = model.lookChrome
        var width = max(width, 360)
        var height = chrome + width / aspect
        let room = ((screen ?? NSScreen.main)?.visibleFrame.height ?? 900) - 24
        if height > room {
            height = room
            width = max((height - chrome) * aspect, 360)
        }
        return NSSize(width: width.rounded(), height: height.rounded())
    }
}

/// What the card's window shows: the card for what you're looking at, filling it. While the window fades out, the card
/// it had stays in it.
struct LookWindow: View {
    let model: AppModel
    @State private var lastShown: Look?

    var body: some View {
        Group {
            if let look = model.look ?? lastShown, let tree = model.tree {
                LookCard(model: model, look: look, isFolder: LookContents.isFolder(look.node, in: tree))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular.tint(.black.opacity(0.42)), in: Rectangle())
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
        // The window never takes the keyboard from the main one, so every click on it is a first click: it has to count.
        .allowsWindowActivationEvents(true)
        .onChange(of: model.look, initial: true) { _, look in if let look { lastShown = look } }
        .onChange(of: model.lookDetails) { LookPanel.shared.fit() }
        .onChange(of: model.lookChrome) { LookPanel.shared.fit() }
    }
}
