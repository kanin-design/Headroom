import AppKit
import Foundation
import Security

/// Looks on GitHub for a newer Headroom at launch, and puts it in place of this one when you say so. A version you say no
/// to isn't offered again, though a newer one is, and Check for Updates always looks.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    /// One version on GitHub, with its disk image.
    struct Release: Equatable, Sendable {
        var version: [Int]
        var stage: String?
        var notes: String
        var download: URL
        var size: Int64
        var page: URL

        var number: String { version.map(String.init).joined(separator: ".") }
        var shown: String { number + (stage.map { " " + $0 } ?? "") }
        /// What the notes say is new, a line each.
        var whatsNew: [String] { Updater.newThings(in: notes) }
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case couldNotCheck(String)
        case available(Release)
        case downloading(Release, received: Int64)
        case installing(Release)
        case failed(Release, String)
    }

    private(set) var state: State = .idle
    /// Goes up each time the update window should come forward.
    private(set) var windowRequests = 0
    @ObservationIgnored private var download: URLSessionDownloadTask?
    /// A new version found while the Full Disk Access guide was open waits for it to close.
    @ObservationIgnored private var offerWaiting = false
    /// You quit while the new version was being put in place, so the app quits once that's done, and doesn't open again.
    @ObservationIgnored var quitWhenInPlace = false
    /// While the old version goes and the new one comes, quitting would leave neither.
    @ObservationIgnored private(set) var isInstalling = false

    static let currentNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let current = parse(currentNumber)
    static var currentShown: String {
        let number = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return number + ((Bundle.main.object(forInfoDictionaryKey: "HeadroomStage") as? String).map { " " + $0 } ?? "")
    }

    private static let skippedKey = "skippedUpdate"
    private static let releases = URL(string: "https://api.github.com/repos/kanin-design/Headroom/releases?per_page=20")!
    /// What Headroom is and how it works, for Help.
    static let readme = URL(string: "https://github.com/kanin-design/Headroom#readme")!
    /// A scripted check reads its releases from a file instead.
    private static var feedFile: URL? {
        let args = CommandLine.arguments
        guard let at = args.firstIndex(of: "--update-feed"), at + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[at + 1])
    }

    // MARK: Looking

    /// A moment after launch, so it never competes with the first picture. Says nothing unless there's something to say.
    func checkAtLaunch() {
        guard ScriptRunner.path == nil || Self.feedFile != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            guard let release = try? await Self.newest(),
                  Self.shouldOffer(release.version, current: Self.current, skipped: UserDefaults.standard.string(forKey: Self.skippedKey)),
                  state == .idle else { return }
            state = .available(release)
            if AppModel.shared.accessGuideShowing { offerWaiting = true } else { windowRequests += 1 }
        }
    }

    /// The guide has closed: a new version found meanwhile is offered now.
    func offerIfWaiting() {
        guard offerWaiting else { return }
        offerWaiting = false
        if case .available = state { windowRequests += 1 }
    }

    /// From the menu or About: always looks, and always says what it found.
    func checkNow() {
        switch state {
        case .downloading, .installing:
            return
        default:
            state = .checking
        }
        Task {
            do {
                let release = try await Self.newest()
                state = release.map { Self.isNewer($0.version, than: Self.current) ? .available($0) : .upToDate } ?? .upToDate
            } catch {
                state = .couldNotCheck(Self.say(error))
            }
        }
    }

    /// No to this version: it isn't offered at launch again, only the next one is.
    func skip(_ release: Release) {
        UserDefaults.standard.set(release.number, forKey: Self.skippedKey)
        state = .idle
    }

    /// Brings the update window forward, for whatever it has to say.
    func bringForward() { windowRequests += 1 }

    func dismiss() {
        if case .downloading = state { return }
        if case .installing = state { return }
        state = .idle
    }

    nonisolated static func shouldOffer(_ version: [Int], current: [Int], skipped: String?) -> Bool {
        guard isNewer(version, than: current) else { return false }
        guard let skipped else { return true }
        return isNewer(version, than: parse(skipped))
    }

    /// "v0.0.3-beta" and "0.0.3" are both 0.0.3.
    nonisolated static func parse(_ text: String) -> [Int] {
        var number = Substring(text)
        if number.hasPrefix("v") { number = number.dropFirst() }
        number = number.prefix { $0.isNumber || $0 == "." }
        return number.split(separator: ".").map { Int($0) ?? 0 }
    }

    nonisolated static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for at in 0..<max(a.count, b.count) {
            let x = at < a.count ? a[at] : 0, y = at < b.count ? b[at] : 0
            if x != y { return x > y }
        }
        return false
    }

    private struct GitHubRelease: Decodable {
        var tag_name: String
        var body: String?
        var draft: Bool
        var html_url: URL
        var assets: [Asset]

        struct Asset: Decodable {
            var name: String
            var browser_download_url: URL
            var size: Int64
        }
    }

    /// The newest version that has a disk image to install from, from GitHub's list of releases.
    nonisolated static func newest(in data: Data) -> Release? {
        guard let list = try? JSONDecoder().decode([GitHubRelease].self, from: data) else { return nil }
        let releases = list.compactMap { release -> Release? in
            guard !release.draft, let disk = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else { return nil }
            let tag = release.tag_name.hasPrefix("v") ? release.tag_name.dropFirst() : Substring(release.tag_name)
            let stage = tag.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init)
            return Release(version: parse(release.tag_name), stage: stage, notes: release.body ?? "", download: disk.browser_download_url,
                           size: disk.size, page: release.html_url)
        }
        return releases.max { isNewer($1.version, than: $0.version) }
    }

    private static func newest() async throws -> Release? {
        if let feedFile { return newest(in: try Data(contentsOf: feedFile)) }
        var request = URLRequest(url: releases, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Headroom/\(current.map(String.init).joined(separator: "."))", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Problem.noAnswer }
        return newest(in: data)
    }

    /// The lines of a release's notes that say what's new: its list, or its first paragraph if it has none.
    nonisolated static func newThings(in notes: String) -> [String] {
        let lines = notes.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let listed = lines.filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }.map { String($0.dropFirst(2)) }
        if !listed.isEmpty { return listed }
        return lines.first { !$0.isEmpty && !$0.hasPrefix("#") }.map { [$0] } ?? []
    }

    // MARK: Installing

    func install(_ release: Release) {
        state = .downloading(release, received: 0)
        Task {
            do {
                let disk = try await fetch(release)
                state = .installing(release)
                isInstalling = true
                let app = try await Task.detached(priority: .userInitiated) { try Updater.putInPlace(from: disk, version: release.number) }.value
                isInstalling = false
                if quitWhenInPlace { return NSApp.reply(toApplicationShouldTerminate: true) }
                Self.reopen(app)
            } catch is CancellationError {
                state = .available(release)
            } catch {
                isInstalling = false
                state = .failed(release, Self.say(error))
                if quitWhenInPlace { NSApp.reply(toApplicationShouldTerminate: true) }
            }
        }
    }

    func cancel() { download?.cancel() }

    private func fetch(_ release: Release) async throws -> URL {
        if release.download.isFileURL {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Headroom-\(UUID().uuidString).dmg")
            try FileManager.default.copyItem(at: release.download, to: copy)
            return copy
        }
        return try await withCheckedThrowingContinuation { continuation in
            let receiver = Receiver(continuation) { [weak self] received in
                Task { @MainActor in
                    guard let self, case .downloading(let shown, _) = self.state, shown == release else { return }
                    self.state = .downloading(release, received: received)
                }
            }
            let session = URLSession(configuration: .ephemeral, delegate: receiver, delegateQueue: nil)
            let task = session.downloadTask(with: release.download)
            download = task
            task.resume()
            session.finishTasksAndInvalidate()
        }
    }

    /// Hands over the download as it arrives, and the file once it's all there.
    private final class Receiver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private var continuation: CheckedContinuation<URL, Error>?
        private let progress: @Sendable (Int64) -> Void
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<URL, Error>, progress: @escaping @Sendable (Int64) -> Void) {
            self.continuation = continuation
            self.progress = progress
        }

        private func finish(_ result: Result<URL, Error>) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(with: result)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite _: Int64) {
            progress(totalBytesWritten)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { return finish(.failure(Problem.noAnswer)) }
            // The file goes the moment this returns, so it's moved first.
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent("Headroom-\(UUID().uuidString).dmg")
            do {
                try FileManager.default.moveItem(at: location, to: kept)
                finish(.success(kept))
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : error))
        }
    }

    /// Opens the disk image, checks it holds this app at that version, unharmed, and swaps it in. The old version goes to the
    /// Trash, so it can come back, and it's put back if the swap fails.
    nonisolated static func putInPlace(from disk: URL, version: String) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("Headroom-update-\(UUID().uuidString)")
        let mount = work.appendingPathComponent("disk")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: disk) }
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, disk.path]) == 0 else {
            try? fm.removeItem(at: work)
            throw Problem.notADisk
        }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? fm.removeItem(at: work)
        }
        let found = mount.appendingPathComponent("Headroom.app")
        guard let info = NSDictionary(contentsOf: found.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version else { throw Problem.notThisApp }
        guard isSignedLikeThis(found) else { throw Problem.damaged }

        let target = installTarget()
        let staged = target.deletingLastPathComponent().appendingPathComponent(".Headroom-\(version)-\(UUID().uuidString.prefix(8)).app")
        guard run("/usr/bin/ditto", [found.path, staged.path]) == 0 else {
            try? fm.removeItem(at: staged)
            throw Problem.cantWrite
        }
        var trashed: NSURL?
        if fm.fileExists(atPath: target.path) {
            do {
                try fm.trashItem(at: target, resultingItemURL: &trashed)
            } catch {
                try? fm.removeItem(at: staged)
                throw Problem.cantWrite
            }
        }
        do {
            try fm.moveItem(at: staged, to: target)
        } catch {
            if let trashed = trashed as URL? { try? fm.moveItem(at: trashed, to: target) }
            try? fm.removeItem(at: staged)
            throw Problem.cantWrite
        }
        return target
    }

    /// Whether an app is whole and signed the way this one is, with the same certificate, so that only whoever has its key
    /// can make a version this one takes.
    nonisolated static func isSignedLikeThis(_ app: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let strict = SecCSFlags(rawValue: SecCSFlags.RawValue(kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode))
        return SecStaticCodeCheckValidity(code, strict, ownRequirement()) == errSecSuccess
    }

    /// What this app's signature asks of another version: its certificate. Nil when it's signed ad hoc, as a build without
    /// the certificate is, because then the rule names this build's own code and no other version could meet it.
    nonisolated static func ownRequirement() -> SecRequirement? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var onDisk: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &onDisk) == errSecSuccess, let onDisk else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(onDisk, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text, (text as String).contains("certificate") else { return nil }
        return requirement
    }

    /// Where this app is, unless macOS is running it from somewhere it can't be replaced: a hidden copy it makes of an app
    /// opened straight from Downloads, or the disk image itself. Then the new one goes to Applications.
    nonisolated static func installTarget() -> URL {
        let here = Bundle.main.bundleURL
        let folder = here.deletingLastPathComponent().path
        if !here.path.contains("/AppTranslocation/"), !here.path.hasPrefix("/Volumes/"), FileManager.default.isWritableFile(atPath: folder) {
            return here
        }
        return URL(fileURLWithPath: "/Applications/Headroom.app")
    }

    /// Quits, and opens the new version once this one has gone, the way this one was opened.
    private static func reopen(_ app: URL) {
        let passed = Array(CommandLine.arguments.dropFirst())
        // A scripted check stays behind whatever you're doing.
        let behind = ScriptRunner.path == nil ? "" : "-g "
        let open = "/usr/bin/open " + behind + (passed.isEmpty ? "\"$0\"" : "\"$0\" --args \"$@\"")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; " + open, app.path] + passed
        try? task.run()
        NSApp.terminate(nil)
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return -1 }
        task.waitUntilExit()
        return task.terminationStatus
    }

    enum Problem: LocalizedError {
        case noAnswer, notADisk, notThisApp, damaged, cantWrite

        var errorDescription: String? {
            switch self {
            case .noAnswer: "GitHub didn't answer as it should. Try again in a while."
            case .notADisk: "The download isn't a disk image that opens."
            case .notThisApp: "The download doesn't hold the version it should."
            case .damaged: "The new version isn't signed the way this one is, so it wasn't put in place."
            case .cantWrite: "Headroom couldn't put the new version where this one is."
            }
        }
    }

    private static func say(_ error: Error) -> String {
        if let problem = error as? Problem { return problem.errorDescription ?? "" }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: return "This Mac isn't online."
            case .timedOut: return "GitHub took too long to answer."
            default: break
            }
        }
        return error.localizedDescription
    }
}
