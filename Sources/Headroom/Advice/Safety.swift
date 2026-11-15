import Foundation

/// The last check before anything moves. Only your own files, never the folders that hold everything together.
enum Safety {
    /// An app's own settings live in a folder nothing else is allowed to touch.
    static func canUninstall(_ path: String) -> Bool {
        if canTrash(path) { return true }
        if HiddenNames.isOn { return false }
        let visible = PathMath.visible(path)
        return visible.hasPrefix(NSHomeDirectory() + "/Library/Preferences/") && visible.hasSuffix(".plist")
    }

    private static let home = NSHomeDirectory()
    private static let protected: Set<String> = Set([
        "/", home, "/Users", "/Applications", "/Library", "/System", "/private", "/usr", "/opt", "/bin", "/sbin", "/etc", "/var",
        home + "/Library", home + "/Desktop", home + "/Documents", home + "/Downloads", home + "/Pictures", home + "/Movies",
        home + "/Music", home + "/.Trash", home + "/Library/Application Support", home + "/Library/Caches", home + "/Library/Preferences",
        home + "/Library/Containers", home + "/Library/Group Containers", home + "/.config", home + "/.ssh",
    ] + projectHomes.map { home + "/" + $0 })

    /// What people call the folder all their projects are in. Like Documents, it never goes whole: what's in it can.
    static let projectHomes = ["dev", "Developer", "Projects", "projects", "Code", "code", "src", "repos", "workspace", "Sites"]

    static func canTrash(_ path: String) -> Bool {
        if HiddenNames.isOn { return false }
        var visible = PathMath.visible(path)
        // One spelling for each place: `/Users/me/` and `/Users/me//x` mustn't slip past a check written for `/Users/me`.
        while visible.count > 1, visible.hasSuffix("/") { visible.removeLast() }
        guard visible.hasPrefix("/"), !visible.dropFirst().split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { return false }
        if protected.contains(visible) { return false }
        for keep in ["/.Trash", "/.ssh", "/.gnupg", "/Library/Keychains", "/Library/Preferences", "/Library/Mail", "/Library/Messages", "/Library/Safari",
                     "/Library/Mobile Documents", "/Library/CloudStorage", "/Library/Calendars", "/Library/Reminders", "/Library/Accounts", "/Library/Cookies",
                     "/Music/Music"]
        where PathMath.isInside(visible, home + keep) { return false }
        // A package is one thing to the Finder. What's inside isn't yours to pick apart, and a library of photos is only
        // safe in the hands of its own app.
        let parts = visible.split(separator: "/")
        for (at, part) in parts.enumerated() {
            if part.hasSuffix(".photoslibrary") || part.hasSuffix(".musiclibrary") || part.hasSuffix(".tvlibrary") || part.hasSuffix(".imovielibrary") { return false }
            if at < parts.count - 1, part.hasSuffix(".app") || part.hasSuffix(".framework") || part.hasSuffix(".fcpbundle") || part.hasSuffix(".logicx")
                || part.hasSuffix(".sparsebundle") || part.hasSuffix(".xcarchive") || part.hasSuffix(".band") { return false }
        }
        if visible.hasPrefix(home + "/") { return true }
        if visible.hasPrefix("/Applications/") { return true }
        if visible.hasPrefix("/Volumes/") { return visible.split(separator: "/").count > 2 }
        return false
    }
}
