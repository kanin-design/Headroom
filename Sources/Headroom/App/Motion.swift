import AppKit
import SwiftUI

/// Reduce Motion, in System Settings › Accessibility › Display. With it on, the ring dissolves from one picture to the next
/// instead of zooming, springs settle without overshooting, and what would slide in fades in. It's read each time, so a
/// change in System Settings shows at once.
enum Motion {
    /// A scripted check started with `--reduce-motion` sees it on, whatever System Settings says.
    private static let forced = CommandLine.arguments.contains("--reduce-motion")
    static var isReduced: Bool { forced || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Something coming in from an edge, or fading in where it is.
    static func arrival(from edge: Edge) -> AnyTransition {
        isReduced ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    /// Numbers that roll from one value to the next, or change in place.
    static func rolling(_ value: Double? = nil) -> ContentTransition {
        if isReduced { return .opacity }
        return value.map { .numericText(value: $0) } ?? .numericText()
    }

    /// What `withAnimation` does, except SwiftUI takes the change in at once instead of at the end of this turn of the run
    /// loop. A change still waiting there can meet a new window frame from the same turn (macOS tiling the window, a zoom,
    /// Stage Manager, a window manager), and on macOS 27 SwiftUI then fights over the window's size: the window shrinks to
    /// its smallest, or AppKit stops the app. Every animated change in the app goes through here; `jiggle` and `collide` in
    /// ScriptRunner check it.
    @MainActor @discardableResult
    static func animate<Result>(_ animation: Animation?, _ change: () throws -> Result) rethrows -> Result {
        let result = try withAnimation(animation, change)
        CATransaction.flush()
        return result
    }
}
