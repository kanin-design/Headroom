import Foundation
import CoreServices
import SQLite3

/// The line under the size in the middle of the ring, when nothing about links needs saying: when you last used the thing
/// you're pointing at. Each answer is asked for just that thing, when it's pointed at: Plex's database, Steam's record of the
/// game, git's log and Spotlight. Anything else says when it last changed, from the scan.
enum LastUse {
    /// What the line says once it's worked out: hard links come first, then when it was last used.
    static func find(_ node: UInt32, bytes: UInt64, links wantsLinks: Bool, use tellsUse: Bool, in tree: DiskTree) -> (links: String?, use: String?) {
        let links = wantsLinks ? Accounting.hoverLine(node, bytes: bytes, in: tree) : nil
        guard links == nil, tellsUse, !Task.isCancelled else { return (links, nil) }
        return (nil, line(node, in: tree))
    }

    static func line(_ node: UInt32, in tree: DiskTree, now: Date = Date(), home: String = NSHomeDirectory()) -> String? {
        guard let full = tree.path(node) else { return nil }
        let path = Facts.visible(full)
        let isFolder = tree.nodes[Int(node)].has(NodeFlag.directory)
        if let watched = plexWatched(path, database: home + plexDatabase, now: now) { return watched }
        if let played = steamPlayed(path, library: home + "/Library/Application Support/Steam/steamapps") {
            return played == .distantPast ? "Not played yet" : "Played " + ago(played, now: now)
        }
        if isFolder, hasGit(node, in: tree), let commit = lastCommit(in: full) { return "Last commit " + ago(commit, now: now) }
        if !isFolder || path.hasSuffix(".app"), let opened = openedBySpotlight(path) { return "Opened " + ago(opened, now: now) }
        let newest = newestChange(node, in: tree)
        guard newest > 0, !Task.isCancelled else { return nil }
        return "Changed " + ago(Date(timeIntervalSince1970: TimeInterval(newest)), now: now)
    }

    // MARK: Plex

    static let plexDatabase = "/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db"

    /// Plex's library folders: a few short paths, read once and again after ten minutes, so that only what's inside a
    /// library ever opens Plex's database.
    nonisolated(unsafe) private static var libraries: [String: (read: Date, roots: [String])] = [:]
    private static let librariesLock = NSLock()

    /// Whether Plex has played anything here, asked of Plex's own database for just this path.
    static func plexWatched(_ path: String, database: String, now: Date) -> String? {
        guard let roots = plexRoots(database), roots.contains(where: { PathMath.isInside(path, $0) }) else { return nil }
        return withPlex(database) { db -> String? in
            // The same name can be stored composed or decomposed, so both are asked for.
            for form in Set([path.precomposedStringWithCanonicalMapping, path.decomposedStringWithCanonicalMapping]) {
                var statement: OpaquePointer?
                let sql = """
                    select count(distinct p.id), count(distinct case when s.view_count > 0 then p.id end), max(coalesce(s.last_viewed_at, 0))
                    from media_parts p join media_items i on p.media_item_id = i.id join metadata_items m on i.metadata_item_id = m.id
                    left join metadata_item_settings s on s.guid = m.guid
                    where p.file = ?1 or (p.file >= ?2 and p.file < ?3)
                    """
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
                defer { sqlite3_finalize(statement) }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, 1, form, -1, transient)
                sqlite3_bind_text(statement, 2, form + "/", -1, transient)
                sqlite3_bind_text(statement, 3, form + "0", -1, transient)
                guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int(statement, 0) > 0 else { continue }
                let seen = sqlite3_column_int64(statement, 2)
                if seen > 0 { return "Watched " + ago(Date(timeIntervalSince1970: TimeInterval(seen)), now: now) }
                return sqlite3_column_int(statement, 1) > 0 ? "Watched" : "Not watched yet"
            }
            return nil
        } ?? nil
    }

    private static func plexRoots(_ database: String) -> [String]? {
        librariesLock.lock()
        let known = libraries[database]
        librariesLock.unlock()
        if let known, Date().timeIntervalSince(known.read) < 600 { return known.roots }
        guard FileManager.default.fileExists(atPath: database) else { return nil }
        let roots = withPlex(database) { db -> [String] in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "select root_path from section_locations", -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
            defer { sqlite3_finalize(statement) }
            var out: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW { if let text = sqlite3_column_text(statement, 0) { out.append(String(cString: text)) } }
            return out
        } ?? []
        librariesLock.lock()
        libraries[database] = (Date(), roots)
        librariesLock.unlock()
        return roots
    }

    private static func withPlex<T>(_ database: String, _ body: (OpaquePointer) -> T) -> T? {
        var db: OpaquePointer?
        let uri = "file:\(database.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        return body(db)
    }

    // MARK: Steam

    /// When Steam last started the game whose folder this is, from that game's own small record. A game it has never
    /// started gives `.distantPast`.
    static func steamPlayed(_ path: String, library: String) -> Date? {
        let games = library + "/common/"
        guard path.hasPrefix(games) else { return nil }
        let folder = String(path.dropFirst(games.count))
        guard !folder.isEmpty, !folder.contains("/") else { return nil }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: library)) ?? []
        for name in names where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
            guard let text = try? String(contentsOfFile: library + "/" + name, encoding: .utf8) else { continue }
            let values = SteamText.values(text)
            guard values["installdir"] == folder else { continue }
            guard let played = values["LastPlayed"].flatMap(TimeInterval.init) else { return nil }
            return played > 0 ? Date(timeIntervalSince1970: played) : .distantPast
        }
        return nil
    }

    // MARK: git

    /// Whether the scan saw a `.git` folder directly inside.
    private static func hasGit(_ node: UInt32, in tree: DiskTree) -> Bool {
        var child = tree.nodes[Int(node)].firstChild
        while child != 0 {
            let n = tree.nodes[Int(child)]
            if n.nameLength == 4, n.has(NodeFlag.directory), tree.name(child) == ".git" { return true }
            child = n.nextSibling
        }
        return false
    }

    /// The last commit made here, from git's own log of where HEAD has been. It reads the last two kilobytes of that log,
    /// more only if no commit is in them, and never runs git.
    static func lastCommit(in repo: String) -> Date? {
        let file = open(repo + "/.git/logs/HEAD", O_RDONLY)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0 else { return nil }
        let end = Int(info.st_size)
        var size = 2_048
        while true {
            let start = max(end - size, 0)
            var bytes = [UInt8](repeating: 0, count: end - start)
            guard bytes.withUnsafeMutableBytes({ pread(file, $0.baseAddress, end - start, off_t(start)) }) == end - start else { return nil }
            var lines = bytes.split(separator: UInt8(ascii: "\n"))
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            for line in lines.reversed() { if let date = commitDate(line) { return date } }
            if start == 0 || size >= 262_144 { return nil }
            size *= 8
        }
    }

    /// One line of that log: old and new commit, who, when in seconds and the time zone, then a tab and what happened.
    private static func commitDate(_ line: ArraySlice<UInt8>) -> Date? {
        guard let tab = line.firstIndex(of: UInt8(ascii: "\t")), line[(tab + 1)...].starts(with: "commit".utf8) else { return nil }
        let head = line[..<tab]
        guard let zone = head.lastIndex(of: UInt8(ascii: " ")), let when = head[..<zone].lastIndex(of: UInt8(ascii: " ")) else { return nil }
        var seconds = 0
        for digit in head[(when + 1)..<zone] {
            guard digit >= 48, digit <= 57 else { return nil }
            seconds = seconds * 10 + Int(digit - 48)
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    // MARK: Spotlight and the scan

    /// When Spotlight saw it opened. A file gets a "last used" date just from being indexed; only a use count means
    /// someone opened it.
    private static func openedBySpotlight(_ path: String) -> Date? {
        guard let item = MDItemCreateWithURL(nil, URL(fileURLWithPath: path) as CFURL),
              let count = MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? Int, count > 0 else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// The newest file date anywhere inside, from the scan, so it costs no disk reads. It stops early once the pointer has
    /// moved on.
    static func newestChange(_ node: UInt32, in tree: DiskTree) -> UInt32 {
        var newest = tree.nodes[Int(node)].modTime
        var folders = [node]
        var seen = 0
        while let folder = folders.popLast() {
            var child = tree.nodes[Int(folder)].firstChild
            while child != 0 {
                seen &+= 1
                if seen & 8_191 == 0, Task.isCancelled { return 0 }
                let n = tree.nodes[Int(child)]
                newest = max(newest, n.modTime)
                if n.firstChild != 0 { folders.append(child) }
                child = n.nextSibling
            }
        }
        return newest
    }

    // MARK: Words

    nonisolated(unsafe) private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()

    /// "3 days ago", "yesterday", "last month".
    static func ago(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        return relative.localizedString(for: date, relativeTo: now)
    }
}
