import AppKit
import CoreServices
import Foundation
import SQLite3

/// What's known about the disk beyond names and sizes, from Spotlight and other apps' own records. It's all read-only,
/// nothing leaves the Mac, and the map never waits for it. An app that isn't installed simply adds nothing.
struct Facts: Sendable {
    static let none = Facts()
    var gatheredAt = Date.distantPast

    // Plex
    var plexRoots: [String] = []
    var plexFiles: [String: PlexFile] = [:]

    // Transmission
    var torrents: [Torrent] = []

    // Spotlight
    var lastOpened: [String: Date] = [:]
    var askedSpotlight: Set<String> = []

    // Apps
    var apps: [AppFact] = []

    // Steam
    var games: [SteamGame] = []

    // git
    var repos: [String: RepoFact] = [:]

    // Folders of frames
    var frames: [String: FrameFolder] = [:]

    // Data whose app is gone
    var leftBehind: [LeftBehind] = []

    // What other disks hold, from when they were last scanned
    var elsewhere: [String: [DiskIndex.Entry]] = [:]

    // Android tools in use right now
    var androidRunning = false

    // Disks you've had plugged in, even if they aren't now
    var knownDisks: [String] = []

    // AI models
    var models: [Model] = []

    // Screenshots and screen recordings, in the folders macOS saves them to
    var screenshots: [Screenshot] = []

    struct Screenshot: Sendable {
        var path: String
        var bytes: UInt64
        var changed: Date
    }

    struct Model: Sendable {
        var name: String
        var folder: String
        /// Files kept outside the model's own folder, which nothing else uses.
        var blobs: [String]
        var blobBytes: UInt64
        var changed: Date?
    }

    struct PlexFile: Sendable {
        var views: Int
        var lastViewed: Date?
    }

    struct Torrent: Sendable {
        var path: String
        var name: String
        var finished: Date?
        var uploaded: Int
        var isPaused: Bool
    }

    struct SteamGame: Sendable {
        var appID: String
        var name: String
        var folder: String
        var manifest: String
        var lastPlayed: Date?
        var size: UInt64
    }

    struct RepoFact: Sendable {
        var path: String
        var lastCommit: Date?
        var remote: String?
        var isClean: Bool
        var allPushed: Bool
    }

    struct FrameFolder: Sendable {
        var path: String
        var frames: Int
        var video: String?
    }

    struct LeftBehind: Sendable {
        var path: String
        var bundleID: String
        var place: String
    }

    func torrent(holding path: String) -> Torrent? {
        torrents.first { PathMath.isInside(path, $0.path) || PathMath.isInside($0.path, path) }
    }

    /// Visible path: without the data volume's prefix, as other apps write it.
    static func visible(_ path: String) -> String {
        path.hasPrefix("/System/Volumes/Data/") ? String(path.dropFirst("/System/Volumes/Data".count)) : path
    }
}

/// An app, and what can be told about it from the outside.
struct AppFact: Sendable {
    var path: String
    var name: String
    var bundleID: String
    var fromAppStore: Bool
    var addedAt: Date?
    var newestSign: Date?
    var signCount: Int
    var isRunning: Bool
    /// Something else from the same maker that's running or starts by itself.
    var makerNote: String?
    /// Goes with the app: settings and caches.
    var settings: [String]
    /// May hold your own work, so it's your choice.
    var data: [String]
}

/// What's on a disk, in as few bytes as can answer "is this file there?", even when that disk is unplugged.
enum DiskIndex {
    struct Entry: Codable, Sendable {
        var disk: String
        var size: UInt64
        /// When this disk was last read, because that's as far as it's known.
        var readAt: Date = .distantPast
    }

    private struct File: Codable {
        var disk: String
        var files: [String: UInt64]
        var readAt: Date?
    }

    private static func url(_ volume: String) -> URL {
        AppData.folder.appendingPathComponent("index-" + String(volume.map { $0.isLetter || $0.isNumber ? $0 : "_" }) + ".json")
    }

    /// Big files only, by name. Called when a scan has finished.
    static func save(_ tree: DiskTree) {
        var files: [String: UInt64] = [:]
        let nodes = tree.nodes
        for i in 1..<max(tree.count, 1) {
            let n = nodes[i]
            guard !n.has(NodeFlag.directory), !n.has(NodeFlag.synthetic) else { continue }
            let size = max(n.bytes, n.aliasBytes)
            guard size >= 50_000_000 else { continue }
            // A copy in the Trash isn't a copy to count on.
            if let path = tree.path(UInt32(i)), Cleaner.isInTrash(path) { continue }
            files[tree.name(UInt32(i)).lowercased()] = size
        }
        guard let data = try? JSONEncoder().encode(File(disk: tree.volumeName, files: files, readAt: Date())) else { return }
        try? data.write(to: url(tree.volumeName), options: .atomic)
    }

    /// How long ago this disk was last read, in seconds.
    static func age(of volume: String) -> TimeInterval {
        guard let values = try? url(volume).resourceValues(forKeys: [.contentModificationDateKey]), let date = values.contentModificationDate else { return .infinity }
        return Date().timeIntervalSince(date)
    }

    static func diskNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(at: AppData.folder, includingPropertiesForKeys: nil)) ?? []
        return names.filter { $0.lastPathComponent.hasPrefix("index-") }.compactMap { file in
            guard let data = try? Data(contentsOf: file), let index = try? JSONDecoder().decode(File.self, from: data) else { return nil }
            return index.disk
        }
    }

    /// Everything known about every other disk.
    static func loadOthers(than volume: String) -> [String: [Entry]] {
        var out: [String: [Entry]] = [:]
        let names = (try? FileManager.default.contentsOfDirectory(at: AppData.folder, includingPropertiesForKeys: nil)) ?? []
        for file in names where file.lastPathComponent.hasPrefix("index-") {
            guard let data = try? Data(contentsOf: file), let index = try? JSONDecoder().decode(File.self, from: data), index.disk != volume else { continue }
            for (name, size) in index.files { out[name, default: []].append(Entry(disk: index.disk, size: size, readAt: index.readAt ?? .distantPast)) }
        }
        return out
    }
}

extension Facts {
    /// Off the main thread, at low priority. With what was read moments ago, on a saved map, only what that map couldn't
    /// know is read again: other apps' records say the same, and a project's git doesn't need asking twice.
    static func gather(tree: DiskTree, running: [PlanChecks.RunningApp], fullAccess: Bool, reusing earlier: Facts? = nil) -> Facts {
        var facts = Facts()
        if let earlier {
            facts = earlier
            facts.repos = [:]
            facts.frames = [:]
            facts.lastOpened = [:]
            facts.askedSpotlight = []
        } else {
            let home = NSHomeDirectory()
            readPlex(into: &facts, home: home)
            readTransmission(into: &facts, home: home)
            readSteam(into: &facts, home: home)
            let open = OpenFiles.snapshot()
            facts.androidRunning = open.running(containing: "/platform-tools/adb") != nil || open.running(containing: "/emulator/qemu") != nil
            readApps(into: &facts, home: home, running: running, open: open, fullAccess: fullAccess)
            readLeftBehind(into: &facts, home: home, apps: facts.apps, fullAccess: fullAccess)
        }
        facts.gatheredAt = Date()
        // The Desktop is guarded: without Full Disk Access, looking there would bring up a prompt.
        facts.screenshots = fullAccess ? readScreenshots(home: NSHomeDirectory()) : []
        readTree(into: &facts, tree: tree, earlier: earlier)
        facts.elsewhere = DiskIndex.loadOthers(than: tree.volumeName)
        // Plex remembers disks too, even when they're away.
        var known = Set(DiskIndex.diskNames())
        for root in facts.plexRoots where root.hasPrefix("/Volumes/") {
            let parts = root.split(separator: "/")
            if parts.count >= 2 { known.insert(String(parts[1])) }
        }
        facts.knownDisks = known.sorted()
        return facts
    }

    // MARK: Screenshots

    /// macOS names a screenshot or a screen recording with the date and time it was taken, in any language: `Screenshot
    /// 2026-11-09 at 12.00.00.png`, `Skjermbilde 2026-11-09 kl. 12.00.00.png`. The word in front is whatever you set.
    static func isScreenshotName(_ name: String) -> Bool {
        screenshotName.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    private static let screenshotName = try! NSRegularExpression(
        pattern: #"\d{4}-\d{2}-\d{2}\D{1,8}\d{1,2}\.\d{2}\.\d{2}(\s?[AP]M)?( \(\d+\)| \d+)?\.(png|jpe?g|heic|tiff?|pdf|gif|mov|mp4)$"#, options: [.caseInsensitive])

    /// Where screenshots are saved: the folder set in macOS, the Desktop it defaults to, and the usual folders people pick.
    static func screenshotFolders(home: String) -> [String] {
        var folders: [String] = []
        if let set = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String {
            folders.append((set as NSString).expandingTildeInPath)
        }
        folders += [home + "/Desktop", home + "/Pictures/Screenshots", home + "/Documents/Screenshots"]
        var seen = Set<String>()
        return folders.map { ($0 as NSString).standardizingPath }.filter { seen.insert($0).inserted }
    }

    /// One listing of each folder, top level only. Most screenshots are too small to have a place on the map, so this is the
    /// only way to count them.
    static func readScreenshots(home: String, folders: [String]? = nil) -> [Screenshot] {
        var out: [Screenshot] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        for folder in folders ?? screenshotFolders(home: home) {
            let files = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            for file in files where isScreenshotName(file.lastPathComponent) {
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true, let changed = values.contentModificationDate else { continue }
                out.append(Screenshot(path: file.path, bytes: UInt64(values.totalFileAllocatedSize ?? 0), changed: changed))
            }
        }
        return out
    }

    // MARK: Plex

    private static func readPlex(into facts: inout Facts, home: String) {
        let path = home + "/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db"
        guard FileManager.default.fileExists(atPath: path) else { return }
        var db: OpaquePointer?
        // Read-only, so Plex can't be disturbed.
        guard sqlite3_open_v2("file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        func each(_ sql: String, _ row: (OpaquePointer) -> Void) {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
        }
        each("select root_path from section_locations") { row in
            if let text = sqlite3_column_text(row, 0) { facts.plexRoots.append(String(cString: text)) }
        }
        each("""
             select p.file, coalesce(s.view_count, 0), s.last_viewed_at from media_parts p
             join media_items i on p.media_item_id = i.id
             join metadata_items m on i.metadata_item_id = m.id
             left join metadata_item_settings s on s.guid = m.guid
             """) { row in
            guard let text = sqlite3_column_text(row, 0) else { return }
            let views = Int(sqlite3_column_int(row, 1))
            let seen = sqlite3_column_int64(row, 2)
            facts.plexFiles[String(cString: text)] = PlexFile(views: views, lastViewed: seen > 0 ? Date(timeIntervalSince1970: TimeInterval(seen)) : nil)
        }
    }

    // MARK: Transmission

    private static func readTransmission(into facts: inout Facts, home: String) {
        let folder = home + "/Library/Application Support/Transmission/Resume"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        for name in names where name.hasSuffix(".resume") {
            guard let data = FileManager.default.contents(atPath: folder + "/" + name),
                  let record = Bencode.parse(data)?.dict,
                  let destination = record["destination"]?.string, let title = record["name"]?.string else { continue }
            let done = record["done-date"]?.int ?? 0
            facts.torrents.append(Torrent(path: destination + "/" + title, name: title, finished: done > 0 ? Date(timeIntervalSince1970: TimeInterval(done)) : nil,
                                          uploaded: record["uploaded"]?.int ?? 0, isPaused: (record["paused"]?.int ?? 0) != 0))
        }
    }

    // MARK: Steam

    private static func readSteam(into facts: inout Facts, home: String) {
        let library = home + "/Library/Application Support/Steam/steamapps"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: library)) ?? []
        for name in names where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
            let path = library + "/" + name
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let values = SteamText.values(text)
            guard let title = values["name"], let dir = values["installdir"], let appID = values["appid"] else { continue }
            // A game's folder is one plain name. Anything else could point at the whole library.
            guard !dir.isEmpty, !dir.contains("/"), dir != ".", dir != ".." else { continue }
            let played = TimeInterval(values["LastPlayed"] ?? "") ?? 0
            facts.games.append(SteamGame(appID: appID, name: title, folder: library + "/common/" + dir, manifest: path,
                                         lastPlayed: played > 0 ? Date(timeIntervalSince1970: played) : nil, size: UInt64(values["SizeOnDisk"] ?? "") ?? 0))
        }
    }

    // MARK: Apps

    private static func newest(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        var latest = info.st_mtimespec.tv_sec
        if info.st_mode & S_IFMT == S_IFDIR, let names = try? FileManager.default.contentsOfDirectory(atPath: path) {
            for name in names.prefix(400) {
                var child = stat()
                if lstat(path + "/" + name, &child) == 0 { latest = max(latest, child.st_mtimespec.tv_sec) }
            }
        }
        return Date(timeIntervalSince1970: TimeInterval(latest))
    }

    /// The makers whose name says nothing about who made it.
    private static let sharedPrefixes: Set<String> = ["com.github", "io.github", "com.electron", "org.electron", "com.apple", "dev.tauri", "com.tauri", "local.headroom", "com.example"]

    private static func readApps(into facts: inout Facts, home: String, running: [PlanChecks.RunningApp], open: OpenFiles, fullAccess: Bool) {
        let fm = FileManager.default
        var candidates: [String] = []
        for folder in ["/Applications", home + "/Applications"] {
            for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".app") {
                candidates.append(folder + "/" + name)
            }
        }
        let library = home + "/Library"
        for path in candidates {
            // An entry that's only a link into the system is part of macOS, like Safari.
            var link = stat()
            guard lstat(path, &link) == 0, link.st_mode & S_IFMT != S_IFLNK else { continue }
            guard let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"), let id = plist["CFBundleIdentifier"] as? String else { continue }
            let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            let fromAppStore = fm.fileExists(atPath: path + "/Contents/_MASReceipt/receipt")
            // Apple's apps only if the App Store can give them back.
            if id.hasPrefix("com.apple."), !fromAppStore { continue }
            if id == Bundle.main.bundleIdentifier { continue }

            var signs: [Date] = []
            var settings: [String] = []
            var data: [String] = []
            func sign(_ place: String, into list: inout [String]) {
                if let date = newest(place) {
                    signs.append(date)
                    list.append(place)
                }
            }
            sign(library + "/Preferences/\(id).plist", into: &settings)
            sign(library + "/Saved Application State/\(id).savedState", into: &settings)
            sign(library + "/Caches/\(id)", into: &settings)
            sign(library + "/HTTPStorages/\(id)", into: &settings)
            sign(library + "/HTTPStorages/\(id).binarycookies", into: &settings)
            sign(library + "/WebKit/\(id)", into: &settings)
            sign(library + "/Logs/\(id)", into: &settings)
            sign(library + "/Application Support/\(id)", into: &data)
            sign(library + "/Application Support/\(name)", into: &data)
            // A sandboxed app writes inside its own container, whose top doesn't change.
            // Other apps' containers are private: without Full Disk Access, asking would bring up a prompt.
            let container = library + "/Containers/\(id)"
            if fullAccess, fm.fileExists(atPath: container) {
                data.append(container)
                if let date = newest(container + "/Data/Library/Preferences") { signs.append(date) }
                if let date = newest(container + "/Data/Library/Saved Application State") { signs.append(date) }
                if let date = newest(container + "/Data/Library/Caches") { signs.append(date) }
            }
            if fullAccess {
                for name in (try? fm.contentsOfDirectory(atPath: library + "/Group Containers")) ?? [] where name.hasSuffix("." + id) {
                    data.append(library + "/Group Containers/" + name)
                }
            }

            var addedAt: Date?
            if let item = MDItemCreateWithURL(nil, URL(fileURLWithPath: path) as CFURL) {
                if let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date { signs.append(used) }
                addedAt = MDItemCopyAttribute(item, kMDItemDateAdded) as? Date
            }

            // Something else from the same maker is doing something: say so, rather than let it look forgotten.
            let parts = id.split(separator: ".")
            var makerNote: String?
            if parts.count >= 3 {
                let maker = parts.prefix(2).joined(separator: ".")
                if !sharedPrefixes.contains(maker) {
                    if let other = running.first(where: { $0.bundleID.hasPrefix(maker + ".") && $0.bundleID != id }) {
                        makerNote = "\(other.name), by the same developer, is running."
                    } else if let process = open.running(containing: maker) {
                        makerNote = "\(process.process), by the same developer, is running."
                    } else if startsByItself(maker: maker, home: home) {
                        makerNote = "A background item by the same developer is installed."
                    }
                }
            }
            facts.apps.append(AppFact(path: path, name: name, bundleID: id, fromAppStore: fromAppStore, addedAt: addedAt, newestSign: signs.max(), signCount: signs.count,
                                      isRunning: running.contains { $0.bundleID == id }, makerNote: makerNote, settings: settings, data: data))
        }
    }

    private static func startsByItself(maker: String, home: String) -> Bool {
        for folder in [home + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where name.hasPrefix(maker + ".") { return true }
        }
        return false
    }

    // MARK: Left behind

    private static func readLeftBehind(into facts: inout Facts, home: String, apps: [AppFact], fullAccess: Bool) {
        let installed = Set(apps.map(\.bundleID))
        let fm = FileManager.default
        var places = [(home + "/Library/Application Support", "Application Support")]
        if fullAccess { places.append((home + "/Library/Containers", "Containers")) }
        for (folder, place) in places {
            for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] {
                // Only a full bundle ID says for certain which app something belongs to.
                let parts = name.split(separator: ".")
                guard parts.count >= 3, !name.hasPrefix("com.apple."), !name.contains(" "), parts[0].count <= 5,
                      parts.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }) else { continue }
                if installed.contains(name) { continue }
                if NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) != nil { continue }
                // A helper inside an app that's still here: its maker still has an app on this Mac.
                let maker = parts.prefix(2).joined(separator: ".")
                if installed.contains(where: { $0.hasPrefix(maker + ".") || $0 == maker }) { continue }
                facts.leftBehind.append(LeftBehind(path: folder + "/" + name, bundleID: name, place: place))
            }
        }
    }

    // MARK: What the tree points at

    private static func readTree(into facts: inout Facts, tree: DiskTree, earlier: Facts?) {
        let nodes = tree.nodes
        let gitAvailable = Git.isAvailable
        var videos = 0
        var modelFolders: [String] = []
        for i in 1..<max(tree.count, 1) {
            let n = nodes[i]
            let id = UInt32(i)
            guard !n.has(NodeFlag.synthetic) else { continue }
            if n.has(NodeFlag.directory) {
                // A Hugging Face cache. Its model folders can be too small to be on a saved map, so they're read from here.
                if n.nameLength == 3, tree.name(id) == "hub", let path = tree.path(id),
                   let names = try? FileManager.default.contentsOfDirectory(atPath: path) {
                    for name in names where name.hasPrefix("models--") { modelFolders.append(path + "/" + name) }
                }
                guard nodes[Int(n.parent)].has(NodeFlag.projects) || n.has(NodeFlag.projects) else { continue }
                // A project under git.
                if gitAvailable, n.nameLength == 4, tree.name(id) == ".git", tree.totals[Int(n.parent)] >= 100_000_000, let path = tree.path(n.parent) {
                    // Worked on lately, or not yours to move: it won't be suggested, whatever git would say.
                    if tree.statRow(n.parent)[DiskTree.statRecent30] == 0, Safety.canTrash(path),
                       let fact = earlier?.repos[path] ?? Git.read(path) { facts.repos[path] = fact }
                    continue
                }
                // A folder of numbered images.
                if n.fileCount >= 100, tree.totals[i] >= 200_000_000 {
                    let images = UInt64(tree.statRow(i)[Int(Kind.image.rawValue)]) << 14
                    if Double(images) >= Double(tree.totals[i]) * 0.8, let path = tree.path(id) {
                        if let frames = earlier?.frames[path] ?? frameFolder(path) { facts.frames[path] = frames }
                    }
                }
            } else if n.kind == Kind.video.rawValue, max(n.bytes, n.aliasBytes) >= 100_000_000, videos < 800, let path = tree.path(id) {
                videos += 1
                let visible = Facts.visible(path)
                facts.askedSpotlight.insert(visible)
                if let earlier, earlier.askedSpotlight.contains(visible) {
                    facts.lastOpened[visible] = earlier.lastOpened[visible]
                    continue
                }
                // A new file gets a "last used" date just from being indexed. Only a use count means someone opened it.
                if let item = MDItemCreateWithURL(nil, URL(fileURLWithPath: visible) as CFURL),
                   let count = MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? Int, count > 0,
                   let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
                    facts.lastOpened[visible] = used
                }
            }
        }
        facts.models = readModels(modelFolders)
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A model's files can live in a store shared by the whole cache, with its own folder holding only links to them.
    /// So what a model really uses is found by following those links.
    private static func readModels(_ folders: [String]) -> [Model] {
        let fm = FileManager.default
        var usedBy: [String: [String]] = [:]
        var inner: [String: UInt64] = [:]
        for folder in folders {
            guard let walker = fm.enumerator(atPath: folder + "/snapshots") else { continue }
            let realFolder = realPath(folder)
            // Only the cache's own store. A link that leads anywhere else is to something that can't be downloaded again.
            let store = (realFolder as NSString).deletingLastPathComponent + "/blobs"
            for case let relative as String in walker {
                let path = folder + "/snapshots/" + relative
                guard (try? fm.destinationOfSymbolicLink(atPath: path)) != nil else { continue }
                // Follow it all the way: a link can lead to another link.
                let real = realPath(path)
                guard !PathMath.isInside(real, realFolder), PathMath.isInside(real, store) else { continue }
                if !(usedBy[real]?.contains(folder) ?? false) { usedBy[real, default: []].append(folder) }
            }
            inner[folder] = 0
        }
        var models: [Model] = []
        for folder in folders {
            var blobs: [String] = []
            var bytes: UInt64 = 0
            var newest: time_t = 0
            for (blob, users) in usedBy where users == [folder] {
                var info = stat()
                guard lstat(blob, &info) == 0 else { continue }
                blobs.append(blob)
                bytes &+= UInt64(info.st_blocks) * 512
                newest = max(newest, info.st_mtimespec.tv_sec)
            }
            let name = (folder as NSString).lastPathComponent.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
            models.append(Model(name: name, folder: folder, blobs: blobs, blobBytes: bytes, changed: newest > 0 ? Date(timeIntervalSince1970: TimeInterval(newest)) : nil))
        }
        return models
    }

    private static func frameFolder(_ path: String) -> FrameFolder? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path), names.count >= 100 else { return nil }
        let numbered = names.filter(Titles.isNumberedFrame).count
        guard Double(numbered) >= Double(names.count) * 0.9 else { return nil }
        // The finished video, if it's sitting next to its frames.
        let parent = (path as NSString).deletingLastPathComponent
        let videos = ["mp4", "mov", "mkv", "webm", "m4v"]
        let video = ((try? fm.contentsOfDirectory(atPath: parent)) ?? []).first { videos.contains(($0 as NSString).pathExtension.lowercased()) }
        return FrameFolder(path: path, frames: numbered, video: video)
    }
}

/// What git can say about a project. Without git installed, nothing is claimed.
enum Git {
    /// Running Apple's stub without the command line tools would bring up an install prompt, so it's checked first.
    static let tool: String? = {
        let fm = FileManager.default
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: path) { return path }
        if fm.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/git") || fm.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git") { return "/usr/bin/git" }
        return nil
    }()

    static var isAvailable: Bool { tool != nil }

    private static func run(_ arguments: [String], in path: String) -> String? {
        guard let tool else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-C", path] + arguments
        // Without this, `git status` may rewrite the project's index just to save itself time next run. Looking changes nothing.
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_OPTIONAL_LOCKS": "0"]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A project is only suggested when all of this holds, so the first thing that doesn't saves asking the rest. Walking the
    /// whole project for uncommitted work is the slow part, so it goes last.
    static func read(_ path: String, now: Date = Date()) -> Facts.RepoFact? {
        let last = run(["log", "-1", "--format=%ct"], in: path)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastCommit = TimeInterval(last ?? "").map({ Date(timeIntervalSince1970: $0) }) else { return nil }
        var fact = Facts.RepoFact(path: path, lastCommit: lastCommit, remote: nil, isClean: false, allPushed: false)
        guard now.timeIntervalSince(lastCommit) >= TimeInterval(Advisors.projectQuietDays) * 86_400 else { return fact }
        fact.remote = run(["remote", "get-url", "origin"], in: path)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fact.remote != nil else { return fact }
        // Every local branch has to be somewhere else too, with nothing extra, and nothing tucked away in a stash, in another
        // working folder, or on a commit no branch points at.
        guard let branches = run(["for-each-ref", "--format=%(upstream)|%(upstream:track)", "refs/heads"], in: path) else { return fact }
        for line in branches.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            let upstream = parts.first.map(String.init) ?? ""
            let track = parts.count > 1 ? String(parts[1]) : ""
            if upstream.isEmpty || track.contains("ahead") || track.contains("gone") { return fact }
        }
        if let stashes = run(["stash", "list"], in: path), !stashes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return fact }
        if run(["symbolic-ref", "-q", "HEAD"], in: path) == nil { return fact }
        if let trees = run(["worktree", "list", "--porcelain"], in: path), trees.components(separatedBy: "worktree ").count > 2 { return fact }
        fact.allPushed = true
        guard let status = run(["status", "--porcelain"], in: path) else { return fact }
        fact.isClean = status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return fact
    }
}
