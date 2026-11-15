import AppKit
import SwiftUI

/// The keyboard in Free Up.
extension AppModel {
    // MARK: Keyboard

    func handlePlanKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125: moveCursor(1)
        case 126: moveCursor(-1)
        case 36:
            // Return never empties, and never starts a second clean on top of one that's waiting for you.
            guard afterClean == nil, !plan.isEmpty else { return false }
            cleanNow()
        case 51:
            guard let box = cursorBox else { return false }
            toggle(box)
        case 49:
            guard let row = cursorBox?.rows.first, let node = row.nodes.first else { return false }
            openLook(node)
        case 40:
            guard let box = cursorBox, box.rows.count == 1, let row = box.rows.first else { return false }
            moveCursor(1)
            keep(row)
        case 46:
            guard let box = cursorBox, box.rows.count == 1, let row = box.rows.first, let tree, let node = row.nodes.first, let path = tree.path(node), let disk = otherDisks(for: path).first else { return false }
            planMove(row, to: disk)
        default:
            return false
        }
        return true
    }

    func handleScriptKey(_ character: Character) {
        switch character {
        case "j": moveCursor(1)
        case "k": moveCursor(-1)
        case "x": if let box = cursorBox { toggle(box) }
        default: break
        }
    }

    var cursorBox: Box? { boxes.first { $0.id == cursorRow } }

    private func moveCursor(_ by: Int) {
        guard !boxes.isEmpty else { return }
        var at = boxes.firstIndex { $0.id == cursorRow } ?? (by > 0 ? -1 : boxes.count)
        at = min(max(at + by, 0), boxes.count - 1)
        cursorRow = boxes[at].id
        point(at: boxes[at])
    }
}
