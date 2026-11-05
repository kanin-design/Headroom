import Foundation

/// Swaps folder and file names for made-up ones, so a screenshot shows what the app looks like and not what's on your disk.
/// Sizes and colours stay real. Started with `--hide-names`. Nothing can be moved to the Trash in this mode, because a made-up
/// name would hide what's really being moved. `leaks` in a script looks for any real name that still gets through.
enum HiddenNames {
    static let isOn = CommandLine.arguments.contains("--hide-names")
    private static let anotherUser = "Another user"
    private static let externalDisk = "External Disk"

    /// Every Mac has these, so they say nothing about you.
    private static let everyMac: Set<String> = [
        "Library", "Downloads", "Documents", "Desktop", "Movies", "Music", "Pictures", "Public", "Application Support", "Caches",
        "Containers", "Group Containers", "Logs", "Preferences", "Developer", "Fonts", "Frameworks", "Resources", "Contents",
        "MacOS", "PlugIns", "Saved Application State", "WebKit", "Mail", "Messages", "Safari", "Photos Library.photoslibrary",
        "node_modules", ".git", ".Trash",
    ]
    /// The same, at the very top of the disk.
    private static let topOfEveryMac: Set<String> = [
        "/System", "/Library", "/private", "/opt", "/usr", "/sw", "/cores", "/bin", "/sbin", "/etc", "/var", "/tmp", "/dev", "/MobileSoftwareUpdate",
    ]
    /// For the things you see first, biggest first within each kind.
    private static let topNames: [Kind: [String]] = [
        .video: ["Videos", "Film Archive", "Home Movies", "Footage"],
        .audio: ["Sound Library", "Recordings", "Podcasts", "Samples"],
        .image: ["Photo Archive", "Artwork", "Scans", "Wallpapers"],
        .document: ["Notes", "Papers", "Books", "Reports"],
        .code: ["Projects", "Code", "Experiments", "Scripts"],
        .app: ["Tools", "SDKs", "Emulators", "Runtimes"],
        .archive: ["Backups", "Disk Images", "Old Archives"],
        .model: ["AI Models", "Language Models", "Speech Models"],
        .cache: ["Build Output", "Temporary"],
        .system: ["Support Data", "Settings"],
        .other: ["Workspace", "Shared", "Storage", "Misc"],
    ]
    private static let folderWord: [Kind: String] = [
        .video: "Series", .audio: "Album", .image: "Album", .document: "Folder", .code: "Project", .app: "Package",
        .archive: "Backup", .model: "Model", .cache: "Cache", .system: "Data", .other: "Folder",
    ]
    private static let fileWord: [Kind: String] = [
        .video: "Episode", .audio: "Track", .image: "Image", .document: "Document", .code: "Source", .app: "Binary",
        .archive: "Archive", .model: "Weights", .cache: "Cache", .system: "Database", .other: "File",
    ]
    private static let appNames = ["Video Editor", "Chat", "Web Browser", "Browser Preview", "Music Studio", "3D Studio", "Code Editor",
                                   "Notes", "Photo Studio", "Player"]

    static func apply(to tree: DiskTree) {
        let nodes = tree.nodes
        var waiting: [(parent: UInt32, top: Bool)] = []
        for child in tree.children(0) where child != tree.free && child != tree.hidden {
            if nodes[Int(child)].has(NodeFlag.synthetic) {
                // Anything else in here that was scanned is a folder at the top of the disk, or another person's home.
                for inner in tree.children(child) where !nodes[Int(inner)].has(NodeFlag.synthetic) {
                    let shown = tree.displayNames[inner] ?? ""
                    if !topOfEveryMac.contains(shown) { tree.displayNames[inner] = shown.hasPrefix("/") ? "/Another folder" : anotherUser }
                    waiting.append((inner, false))
                }
            } else {
                waiting.append((child, true))
            }
        }
        while let (parent, top) = waiting.popLast() {
            var used: [String: Int] = [:]
            for child in tree.children(parent) {
                let n = nodes[Int(child)]
                let real = tree.rawName(child)
                if !everyMac.contains(real) { tree.displayNames[child] = madeUp(real, n, tree.dominantKind(child), top: top, &used) }
                if n.has(NodeFlag.directory) { waiting.append((child, false)) }
            }
        }
        lock.withLock {
            latest = tree
            remembered = [:]
        }
    }

    private static let lock = NSLock()
    private static var latest: DiskTree?
    private static var remembered: [String: String] = [:]

    /// A real path as it reads with the names swapped. Finding it means reading every name in each folder on the way, so a long
    /// list of results with the same few folders in it only does that once.
    static func madeUp(path: String) -> String {
        let (tree, known) = lock.withLock { (latest, remembered[path]) }
        if let known { return known }
        guard let tree else { return "/…" }
        let shown = madeUp(path: path, in: tree)
        lock.withLock { if latest === tree { remembered[path] = shown } }
        return shown
    }

    /// The same names as on the ring, for as far as the map knows the path. Whatever is past that isn't named at all.
    static func madeUp(path: String, in tree: DiskTree) -> String {
        // Already as you'd say it, so it has already been through here.
        if path.hasPrefix("~") { return path }
        var at: UInt32?
        var root = ""
        var rest = Substring()
        for whole in [path, "/System/Volumes/Data" + path] where at == nil {
            for i in 0..<min(tree.count, 64) where tree.nodes[i].has(NodeFlag.anchor) {
                let raw = tree.rawName(UInt32(i))
                if whole == raw || whole.hasPrefix(raw + "/"), raw.count > root.count {
                    at = UInt32(i)
                    root = raw
                    rest = whole.dropFirst(raw.count)
                }
            }
        }
        guard var node = at else { return path.hasPrefix("/Volumes/") ? "/Volumes/\(externalDisk)/…" : "/…" }
        var shown = root
        if root.hasPrefix("/Volumes/") {
            shown = "/Volumes/" + externalDisk
        } else if let display = tree.displayNames[node], node != tree.home {
            if display == anotherUser { shown = "/Users/" + anotherUser } else if display.hasPrefix("/") { shown = display }
        }
        for part in rest.split(separator: "/") {
            var child = tree.nodes[Int(node)].firstChild
            while child != 0, tree.rawName(child) != part { child = tree.nodes[Int(child)].nextSibling }
            guard child != 0 else { return shown + "/…" }
            shown += "/" + tree.name(child)
            node = child
        }
        return shown
    }

    /// A disk's name, for showing.
    static func name(ofDisk name: String, isBoot: Bool) -> String {
        guard isOn else { return name }
        return isBoot ? "Macintosh HD" : externalDisk
    }

    private static func madeUp(_ real: String, _ n: Node, _ kind: Kind, top: Bool, _ used: inout [String: Int]) -> String {
        let suffix = (real as NSString).pathExtension
        func next(_ group: String) -> Int {
            let at = (used[group] ?? 0) + 1
            used[group] = at
            return at
        }
        guard n.has(NodeFlag.directory) else {
            let word = fileWord[kind] ?? "File"
            return "\(word) \(next(word))" + (suffix.isEmpty || suffix.count > 5 ? "" : ".\(suffix)")
        }
        if suffix == "app" {
            let at = next("app")
            return (at <= appNames.count ? appNames[at - 1] : "App \(at)") + ".app"
        }
        if top, let names = topNames[kind] {
            let at = next("top \(kind)")
            if at <= names.count { return names[at - 1] }
        }
        let word = folderWord[kind] ?? "Folder"
        return "\(word) \(next(word))"
    }
}
