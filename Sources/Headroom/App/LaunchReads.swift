import Foundation
import os

/// What the app reads from the disk at launch that needs no window: whether it may read everything, the drives that are
/// connected, and the last scan. They're read on other threads from the moment the app starts, while AppKit and SwiftUI
/// make the window on the main thread, and taken when the window appears. Read then, on the main thread, they held up
/// the scan's start and the first frame by as long as they took: about 40 ms.
///
/// Each is taken once. Without `begin`, or once taken, the caller reads for itself, as it always did.
enum LaunchReads {
    /// Something worked out on another thread, for whoever asks first. Asking waits for it if it isn't done.
    private final class Ahead<T>: @unchecked Sendable {
        private let work: DispatchWorkItem
        private let lock = OSAllocatedUnfairLock<T?>(uncheckedState: nil)

        init(_ read: @escaping @Sendable () -> T) {
            let lock = self.lock
            work = DispatchWorkItem(qos: .userInitiated) {
                let value = read()
                lock.withLockUnchecked { $0 = value }
            }
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }

        /// The value, the first time. Nil after that.
        func take() -> T? {
            work.wait()
            return lock.withLockUnchecked { value in
                defer { value = nil }
                return value
            }
        }
    }

    /// The last scan of the startup disk, and whose it is: only that disk's map is this one.
    struct SavedMap {
        let volume: String
        let ruleBook: UInt64
        let tree: DiskTree?
    }

    nonisolated(unsafe) private static var access: Ahead<Bool>?
    nonisolated(unsafe) private static var connected: Ahead<[DriveInfo]>?
    nonisolated(unsafe) private static var saved: Ahead<SavedMap?>?

    /// Called once, before the app's own start, on the main thread.
    static func begin() {
        let access = Ahead { DiskScan.hasFullDiskAccess() }
        self.access = access
        connected = Ahead { DriveInfo.connected() }
        let arguments = CommandLine.arguments
        // The same conditions as `AppModel.start` reads the saved map under.
        guard !arguments.contains("--no-cache"), !(ScriptRunner.path != nil && arguments.contains("--locked")) else { return }
        saved = Ahead {
            // Asked here without taking it: whoever takes it still gets it.
            guard DiskScan.hasFullDiskAccess(), let volume = VolumeFacts.available().first else { return nil }
            let rules = RuleBook(homePath: NSHomeDirectory())
            return SavedMap(volume: volume.name, ruleBook: rules.fingerprint, tree: TreeCache.load(for: volume, rules: rules))
        }
    }

    /// Whether every folder may be read, as `DiskScan.hasFullDiskAccess` said when the app started.
    static func takeFullDiskAccess() -> Bool? {
        defer { access = nil }
        return access?.take()
    }

    /// The drives connected when the app started.
    static func takeConnectedDrives() -> [DriveInfo]? {
        defer { connected = nil }
        return connected?.take()
    }

    /// The last scan of this disk under these rules, if it was read ahead. `.some(nil)`: it was looked for, and there's none.
    static func takeSavedMap(for volume: VolumeFacts, rules: RuleBook) -> DiskTree?? {
        defer { saved = nil }
        guard let read = saved?.take(), let map = read, map.volume == volume.name, map.ruleBook == rules.fingerprint else { return nil }
        return .some(map.tree)
    }
}
