import Foundation

/// Swaps folder and file names for made-up ones, so a screenshot of the Map shows what the app looks like and not what's on
/// your disk. Sizes and colours stay real. Started with `--hide-names`. Nothing can be moved to the Trash in this mode,
/// because a made-up name would hide what's really being moved.
enum HiddenNames {
    static let isOn = CommandLine.arguments.contains("--hide-names")

    /// Every Mac has these, so they say nothing about you.
    private static let everyMac: Set<String> = [
        "Library", "Downloads", "Documents", "Desktop", "Movies", "Music", "Pictures", "Public", "Application Support", "Caches",
        "Containers", "Group Containers", "Logs", "Preferences", "Developer", "Fonts", "Frameworks", "Resources", "Contents",
        "MacOS", "PlugIns", "Saved Application State", "WebKit", "Mail", "Messages", "Safari", "Photos Library.photoslibrary",
        "node_modules", ".git", ".Trash",
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
                    if tree.displayNames[inner]?.hasPrefix("/") != true { tree.displayNames[inner] = "Another user" }
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
                let real = String(decoding: UnsafeBufferPointer(start: tree.names + Int(n.nameOffset), count: Int(n.nameLength)), as: UTF8.self)
                if !everyMac.contains(real) { tree.displayNames[child] = madeUp(real, n, tree.dominantKind(child), top: top, &used) }
                if n.has(NodeFlag.directory) { waiting.append((child, false)) }
            }
        }
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
