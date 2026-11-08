import AppKit
import Foundation
import Security

/// Looks on GitHub for a newer Headroom at launch, and puts it in place of this one when you say so. Newer is a higher
/// version, or the same version with a higher build number. A version you say no to isn't offered again, though a newer
/// one is, and Check for Updates always looks.
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
        /// Its build number, from the small file beside its disk image. Nil when it doesn't say.
        var build: Int? = nil
        /// That file, which says the release's version and build.
        var facts: URL? = nil

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
    /// Which look the window is waiting for, so an older answer can't overwrite a newer one.
    @ObservationIgnored private var checkToken = 0

    static let currentNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let current = parse(currentNumber)
    /// This copy's build number. It goes up with every build, so it tells two copies of one version apart.
    static let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
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
                  Self.shouldOffer(release.version, build: release.build, current: Self.current, currentBuild: Self.currentBuild,
                                   skipped: UserDefaults.standard.string(forKey: Self.skippedKey)),
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

    /// From the menu or About: always looks, and always says what it found. An answer that arrives after you've closed the
    /// window, or asked again, is out of date and let go.
    func checkNow() {
        let had: Release?
        switch state {
        case .downloading, .installing:
            return
        case .available(let release), .failed(let release, _):
            had = release
        default:
            had = nil
        }
        state = .checking
        checkToken &+= 1
        let token = checkToken
        Task {
            let found: Result<Release?, Error>
            do { found = .success(try await Self.newest()) } catch { found = .failure(error) }
            guard token == checkToken, state == .checking else { return }
            state = Self.answer(found, had: had, current: Self.current, currentBuild: Self.currentBuild)
        }
    }

    /// What a look ends in. A version found before stays on offer when the look can't get through.
    static func answer(_ found: Result<Release?, Error>, had: Release?, current: [Int], currentBuild: Int = 0) -> State {
        switch found {
        case .success(let release):
            return release.map { isNewer($0.version, build: $0.build, than: current, currentBuild: currentBuild) ? .available($0) : .upToDate } ?? .upToDate
        case .failure(let error):
            return had.map { .available($0) } ?? .couldNotCheck(say(error))
        }
    }

    /// No to this version: it isn't offered at launch again, only the next one is, or the same version with a newer build.
    func skip(_ release: Release) {
        UserDefaults.standard.set(release.number + (release.build.map { "+\($0)" } ?? ""), forKey: Self.skippedKey)
        state = .idle
    }

    /// Brings the update window forward, for whatever it has to say.
    func bringForward() { windowRequests += 1 }

    func dismiss() {
        if case .downloading = state { return }
        if case .installing = state { return }
        state = .idle
    }

    nonisolated static func shouldOffer(_ version: [Int], build: Int? = nil, current: [Int], currentBuild: Int = 0, skipped: String?) -> Bool {
        guard isNewer(version, build: build, than: current, currentBuild: currentBuild) else { return false }
        guard let skipped else { return true }
        return isNewer(version, build: build, than: parse(skipped), currentBuild: skippedBuild(skipped) ?? 0)
    }

    /// The build in a no: "0.0.6+124" is build 124. A no from before builds were kept has none.
    nonisolated static func skippedBuild(_ text: String) -> Int? {
        text.split(separator: "+").dropFirst().first.flatMap { Int($0) }
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

    nonisolated static func isSame(_ a: [Int], _ b: [Int]) -> Bool { !isNewer(a, than: b) && !isNewer(b, than: a) }

    /// Whether a release is newer than this copy. As in Sparkle, the updater most Mac apps use, the build number decides
    /// between two copies of one version: it goes up with every build, so a release put out again under the same version
    /// reaches the copies that have it. A lower version is never offered, whatever its build, and a release that doesn't
    /// say its build is newer only by its version.
    nonisolated static func isNewer(_ version: [Int], build: Int?, than current: [Int], currentBuild: Int) -> Bool {
        if isNewer(version, than: current) { return true }
        guard isSame(version, current), let build else { return false }
        return build > currentBuild
    }

    /// What a release is called: "0.0.6 beta", with its build beside a copy of the same version, since only the build tells
    /// the two apart then.
    static func name(of release: Release, current: [Int] = Updater.current) -> String {
        guard let build = release.build, isSame(release.version, current) else { return release.shown }
        return "\(release.shown), build \(build)"
    }

    /// What this copy is called beside a release: with its build when the two are the same version.
    static func currentName(besides release: Release) -> String {
        guard release.build != nil, isSame(release.version, current) else { return currentShown }
        return "\(currentShown), build \(currentBuild)"
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

    /// The build in a release's small file, `{"version": "0.0.6", "build": 124}`, when it's about that version.
    nonisolated static func build(in data: Data, version: [Int]) -> Int? {
        guard let facts = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let said = facts["version"] as? String, isSame(parse(said), version) else { return nil }
        if let build = facts["build"] as? Int { return build }
        return (facts["build"] as? String).flatMap { Int($0) }
    }

    /// The newest version that has a disk image to install from, from GitHub's list of releases.
    nonisolated static func newest(in data: Data) -> Release? {
        guard let list = try? JSONDecoder().decode([GitHubRelease].self, from: data) else { return nil }
        let releases = list.compactMap { release -> Release? in
            guard !release.draft, let disk = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else { return nil }
            let tag = release.tag_name.hasPrefix("v") ? release.tag_name.dropFirst() : Substring(release.tag_name)
            let stage = tag.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init)
            let facts = release.assets.first { $0.name.lowercased().hasSuffix(".json") }?.browser_download_url
            return Release(version: parse(release.tag_name), stage: stage, notes: release.body ?? "", download: disk.browser_download_url,
                           size: disk.size, page: release.html_url, facts: facts)
        }
        return releases.max { isNewer($1.version, than: $0.version) }
    }

    private static func newest() async throws -> Release? {
        let list: Data
        if let feedFile {
            list = try Data(contentsOf: feedFile)
        } else {
            let (data, response) = try await URLSession.shared.data(for: request(releases, accept: "application/vnd.github+json"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Problem.noAnswer }
            list = data
        }
        guard var release = newest(in: list) else { return nil }
        if let facts = release.facts { release.build = await build(from: facts, version: release.version) }
        return release
    }

    /// The build a release says it is. Nil when it can't be read: the release is then newer only by its version.
    private static func build(from facts: URL, version: [Int]) async -> Int? {
        if facts.isFileURL { return (try? Data(contentsOf: facts)).flatMap { build(in: $0, version: version) } }
        guard let (data, response) = try? await URLSession.shared.data(for: request(facts, accept: "application/json")),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return build(in: data, version: version)
    }

    private static func request(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Headroom/\(current.map(String.init).joined(separator: "."))", forHTTPHeaderField: "User-Agent")
        return request
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
                let app = try await Task.detached(priority: .userInitiated) { try Updater.putInPlace(from: disk, version: release.number, build: release.build) }.value
                isInstalling = false
                if quitWhenInPlace { return AppModel.shared.quitWhenNothingIsLeft() }
                Self.reopen(app)
            } catch is CancellationError {
                state = .available(release)
            } catch {
                isInstalling = false
                state = .failed(release, Self.say(error))
                if quitWhenInPlace { AppModel.shared.quitWhenNothingIsLeft() }
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
            // Done with no error but no file handed over, the window would say "Downloading" for ever. After a file, the
            // download has already finished, and this changes nothing.
            guard let error else { return finish(.failure(Problem.noAnswer)) }
            finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : error))
        }
    }

    /// Opens the disk image, checks it holds this app at that version and build, unharmed, and swaps it in. The old version
    /// goes to the Trash, so it can come back, and it's put back if the swap fails.
    nonisolated static func putInPlace(from disk: URL, version: String, build: Int? = nil) throws -> URL {
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
              info["CFBundleShortVersionString"] as? String == version,
              build.map({ info["CFBundleVersion"] as? String == String($0) }) ?? true else { throw Problem.notThisApp }
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

    /// Quits, and opens the new version the way this one was opened. While you're using Headroom, the new version opens
    /// before this one quits and is handed the front, because macOS only lets the app in front pass it on. Opened after this
    /// one had gone, it would stay behind whatever came forward in between as soon as you touched the mouse.
    private static func reopen(_ app: URL) {
        guard ScriptRunner.path == nil, NSApp.isActive else { return reopenOnceGone(app) }
        Task {
            let handover = NSWorkspace.OpenConfiguration()
            // This version is still running, from the Trash.
            handover.createsNewApplicationInstance = true
            handover.arguments = Array(CommandLine.arguments.dropFirst())
            guard let opened = try? await NSWorkspace.shared.openApplication(at: app, configuration: handover) else {
                return reopenOnceGone(app)
            }
            NSApp.yieldActivation(to: opened)
            _ = opened.activate(from: .current, options: [])
            // A moment at most: a new version that never comes forward mustn't keep this one open.
            let giveUp = Date.now.addingTimeInterval(3)
            while !opened.isActive, Date.now < giveUp { try? await Task.sleep(for: .milliseconds(100)) }
            NSApp.terminateSoon()
        }
    }

    /// Quits, and opens the new version once this one has gone.
    private static func reopenOnceGone(_ app: URL) {
        let passed = Array(CommandLine.arguments.dropFirst())
        // A scripted check stays behind whatever you're doing.
        let behind = ScriptRunner.path == nil ? "" : "-g "
        let open = "/usr/bin/open " + behind + (passed.isEmpty ? "\"$0\"" : "\"$0\" --args \"$@\"")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; " + open, app.path] + passed
        try? task.run()
        NSApp.terminateSoon()
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
