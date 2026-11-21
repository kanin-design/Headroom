import Observation

/// Which one of many rows the pointer on the ring lights, kept row by row. A list whose rows each asked one shared value
/// "is it me?" would all be made again whenever the answer changed for any of them: with the pointer crossing the ring,
/// that's many times a second, and in Copies it was a third of the main thread's time. A row that reads `isLit(_:)` in
/// its body is made again only when it lights or stops.
@MainActor
final class LitRow {
    @Observable
    final class Flag {
        var isOn: Bool
        init(_ isOn: Bool) { self.isOn = isOn }
    }

    // One for every row that ever asked, never taken away: a row's view goes on watching the one it was given.
    private var flags: [String: Flag] = [:]
    private(set) var lit: String?

    /// Whether this row is the one that's lit.
    func isLit(_ id: String) -> Bool {
        if let flag = flags[id] { return flag.isOn }
        let flag = Flag(id == lit)
        flags[id] = flag
        return flag.isOn
    }

    /// Lights this row, or with nil none, and tells only the rows it changes.
    func light(_ id: String?) {
        guard id != lit else { return }
        if let lit { flags[lit]?.isOn = false }
        if let id { flags[id]?.isOn = true }
        lit = id
    }
}
