import AppKit
import SwiftUI

/// Looking at everything planned as it is on the disk right now, before anything is allowed to go.
extension AppModel {
    // MARK: Checks

    /// Looks at everything planned as it is now. Nothing changes. `fresh` is for when you asked, or came back: while you're
    /// ticking things, what was seen a moment ago will do.
    func runChecks(fresh: Bool = false) {
        // Checking reads the planned things, and nothing is read without Full Disk Access. A clean checks for itself.
        guard !isCleaning, let tree, hasFullAccess else { return }
        checkRun?.cancel()
        checkGeneration += 1
        let generation = checkGeneration
        isChecking = true
        let items = plan.items
        let bytes = planNumbers.byItem
        let apps = runningApps()
        let byItem = planPlaces.nodes
        let fullAccess = hasFullAccess
        checkRun = Task.detached(priority: .userInitiated) {
            var others: [String: OtherCopy] = [:]
            for item in items {
                if Task.isCancelled { return }
                guard let nodes = byItem[item.id], !nodes.isEmpty, !item.isEmptyTrash, !tree.links.isEmpty else { continue }
                let found = Accounting.otherCopies(of: nodes, in: tree)
                if let first = found.folders.first, found.bytes > 1_000_000 {
                    others[item.id] = OtherCopy(paths: found.folders.compactMap { tree.path($0).map(PathMath.visible) }, bytes: found.bytes, title: tree.friendlyPath(first))
                }
            }
            let othersNow = others
            let result = PlanChecks.run(items: items, trueBytes: bytes, otherCopy: othersNow.mapValues { (title: $0.title, bytes: $0.bytes) }, runningApps: apps, fullAccess: fullAccess, fresh: fresh)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // A newer check has taken over, or a clean that has already ended this one.
                guard self.checkGeneration == generation else { return }
                self.isChecking = false
                guard self.tree === tree else { return }
                self.checks = Self.adding(self.cleanFailures, to: result)
                self.otherCopies = othersNow
            }
        }
    }

    /// No more looking: a clean is about to look once more, itself, as the first thing it does.
    func stopChecks() {
        checkTask?.cancel()
        checkRun?.cancel()
        checkGeneration &+= 1
        isChecking = false
    }

    var readyItems: [PlanItem] { plan.items.filter { checks[$0.id]?.canGo ?? true } }
    var heldBackItems: [PlanItem] { plan.items.filter { !(checks[$0.id]?.canGo ?? true) } }

    /// What the last clean couldn't move stays on the list with the reason, until you say try again.
    nonisolated static func adding(_ failures: [String: CheckProblem], to checks: [String: ItemCheck]) -> [String: ItemCheck] {
        var out = checks
        for (id, problem) in failures where out[id] != nil { out[id]?.problems.append(problem) }
        return out
    }

    func tryAgain(_ item: PlanItem) {
        cleanFailures[item.id] = nil
        message = nil
        runChecks(fresh: true)
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
    }
}
