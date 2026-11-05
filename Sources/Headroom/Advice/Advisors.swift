import AppKit
import Foundation

/// Turns the tree and what's known about it into suggestions about whole things: a series, an app, a project. Everything
/// here is instant and touches nothing but memory, so it can be tested with made-up trees and run as often as needed.
/// A suggestion states facts and leaves the decision to you: "no sign of use for 7 months", never "unused".
enum Advisors {
    /// Apps with no sign of use for this long are worth asking about.
    static let appQuietDays = 183
    /// A project with no commits for this long is worth asking about.
    static let projectQuietDays = 183
    /// An episode has to be this much bigger than your usual to be called out, and this big at all.
    static let bigEpisodeRatio = 2.0
    static let bigEpisodeBytes: UInt64 = 2_000_000_000
    /// A torrent that finished less than this long ago may still be sharing.
    static let seedingDays = 7

    /// Adds what can be worked out about whole things, and tidies what the folder rules said about parts of them.
    static func add(to rows: inout [WinRow], tree: DiskTree, rules: RuleBook, facts: Facts, now: Date = Date()) {
        guard tree.count > 1 else { return }
        var new: [WinRow] = []
        new += media(tree: tree, facts: facts, now: now)
        new += apps(tree: tree, facts: facts, now: now)
        new += games(tree: tree, facts: facts, now: now)
        new += models(tree: tree, facts: facts, rows: &rows)
        new += projects(tree: tree, facts: facts, now: now)
        new += frames(tree: tree, facts: facts)
        new += leftBehind(tree: tree, facts: facts)
        new += handOffs(tree: tree)

        // What's said about a whole thing replaces what a rule said about it.
        let wholeThings = NodeSet(new.filter { $0.action != .uninstall }.flatMap(\.nodes), in: tree)
        rows.removeAll { row in
            row.isPlannable && !row.isQuick && row.tier >= .redownload && row.action != .emptyTrash && !row.nodes.isEmpty && row.nodes.allSatisfy { wholeThings.contains($0) }
        }
        rows += new
        if !tree.isPartial { markInUse(&rows, tree: tree, facts: facts) }
        groupAndroid(&rows)
    }

    /// Versions of the same tools are one decision until you look inside.
    private static func groupAndroid(_ rows: inout [WinRow]) {
        let parts = rows.filter { $0.tier == .redownload && $0.isPlannable && $0.title.hasPrefix("Android ") }
        guard parts.count >= 2 else { return }
        let ids = Set(parts.map(\.id))
        rows.removeAll { ids.contains($0.id) }
        var group = WinRow(id: "group:android", title: "Android tools", subtitle: "\(parts.count) versions and system images. Android Studio downloads them again.",
                           detail: "Android's build tools and the system images its emulator runs on. A project that asks for one downloads it again, but an emulator using one won't start until it does.",
                           tier: .redownload, nodes: parts.flatMap(\.nodes), bytes: parts.reduce(0) { $0 &+ $1.bytes }, paperBytes: parts.reduce(0) { $0 &+ $1.paperBytes }, action: .trash, command: nil, bundleID: nil)
        group.parts = parts.sorted { $0.bytes > $1.bytes }
        group.inUse = parts.compactMap(\.inUse).first
        rows.append(group)
    }

    /// The slider doesn't take what you've been using, even though it could come back.
    private static func markInUse(_ rows: inout [WinRow], tree: DiskTree, facts: Facts) {
        let home = NSHomeDirectory()
        var androidBusy = facts.androidRunning
        if !androidBusy, let avd = tree.find(path: "/System/Volumes/Data" + home + "/.android/avd") {
            androidBusy = tree.statRow(avd)[DiskTree.statRecent14] > 0
        }
        func mark(_ row: inout WinRow) {
            guard row.inUse == nil, row.tier >= .redownload, row.isPlannable, row.action != .emptyTrash else { return }
            // A series or an app says what it knows in its own words. A recent download isn't a sign of use.
            if row.id.hasPrefix("series:") || row.id.hasPrefix("film:") || row.id.hasPrefix("app:") || row.id.hasPrefix("group:quiet-apps") { return }
            if androidBusy, row.nodes.contains(where: { (tree.path($0) ?? "").contains("/Android/") || (tree.path($0) ?? "").contains("/.android/") }) {
                row.inUse = facts.androidRunning ? "Android tools are running" : "Android's emulator was used in the last two weeks"
            } else if row.parts.isEmpty, row.nodes.contains(where: { tree.statRow($0)[DiskTree.statRecent14] > 0 }) {
                row.inUse = "Changed in the last two weeks"
            }
        }
        for at in rows.indices {
            mark(&rows[at])
            for part in rows[at].parts.indices { mark(&rows[at].parts[part]) }
        }
    }

    private static func also(on facts: Facts, name: String, size: UInt64) -> String? {
        guard let entries = facts.elsewhere[name.lowercased()] else { return nil }
        // Block sizes differ between disks, so the same file can read a little differently.
        return entries.first { abs(Double($0.size) - Double(size)) <= Double(size) * 0.02 }?.disk
    }

    // MARK: Media

    private struct Show {
        var key: String
        var name: String
        var counted: [(node: UInt32, season: Int, episode: Int, bytes: UInt64)] = []
        var folders: [UInt32: UInt64] = [:]
        var seasonFolders = Set<UInt32>()
        var linkedElsewhere = false
    }

    static func media(tree: DiskTree, facts: Facts, now: Date) -> [WinRow] {
        let nodes = tree.nodes
        var shows: [String: Show] = [:]
        var films: [UInt32] = []
        for i in 1..<tree.count {
            let n = nodes[i]
            guard n.kind == Kind.video.rawValue, !n.has(NodeFlag.directory), !n.has(NodeFlag.synthetic), !n.has(NodeFlag.alias), !n.has(NodeFlag.gone), n.bytes >= 100_000_000,
                  n.rule == 0, nodes[Int(n.parent)].has(NodeFlag.projects) else { continue }
            let id = UInt32(i)
            let name = tree.name(id)
            guard let episode = Titles.parseEpisode(name) else {
                if n.bytes >= 700_000_000 { films.append(id) }
                continue
            }
            // Season folders sit inside the show's folder. Otherwise the folder it's in holds it.
            var folder = n.parent
            var seasonFolder: UInt32?
            if Titles.isSeasonFolder(tree.name(folder)) {
                seasonFolder = folder
                folder = nodes[Int(folder)].parent
            }
            let parentName = tree.name(folder)
            let fromFolder = Titles.key(parentName) == Titles.key(episode.show) && !episode.show.isEmpty
            let shown = fromFolder ? parentName : (episode.show.isEmpty ? Titles.cleanName(parentName) : episode.show)
            // The folder's whole name, year and all: two shows can share everything else.
            let key = fromFolder ? Titles.folderKey(parentName) : Titles.key(shown)
            guard !key.isEmpty else { continue }
            var show = shows[key] ?? Show(key: key, name: shown)
            show.counted.append((id, episode.season, episode.episode, n.bytes))
            show.folders[folder, default: 0] &+= n.bytes
            if let seasonFolder { show.seasonFolders.insert(seasonFolder) }
            shows[key] = show
        }
        guard !shows.isEmpty || !films.isEmpty else { return [] }

        // Only video files can be in here, which makes this quick even with hundreds of thousands of links.
        let videoLinks = tree.links.filter { $0.kind == Kind.video.rawValue }
        // "Big" means big for you: compared with what an episode usually is in your own library.
        let perEpisode = shows.values.map { Double($0.counted.reduce(UInt64(0)) { $0 &+ $1.bytes }) / Double($0.counted.count) }.sorted()
        let median = perEpisode.isEmpty ? 0 : perEpisode[perEpisode.count / 2]

        var out: [WinRow] = []
        for show in shows.values {
            var tops: [UInt32] = []
            for (folder, bytes) in show.folders {
                // The whole folder only if that's what this really is: named for it, and holding little else, counting links.
                let name = tree.name(folder)
                let isTheShow = Titles.key(name).hasPrefix(Titles.key(show.name)) || Titles.key(show.name).hasPrefix(Titles.key(name))
                let holds = tree.totals[Int(folder)] &+ tree.aliasTotals[Int(folder)]
                if isTheShow, !Titles.isGeneralFolder(name), Double(bytes) >= Double(holds) * 0.9, tree.nodes[Int(folder)].parent != 0, tree.path(folder).map(Safety.canTrash) == true {
                    tops.append(folder)
                } else {
                    tops += show.counted.filter { tree.isInside($0.node, folder) }.map(\.node)
                }
            }
            let nodesOfRow = NodeSet(tops, in: tree).tops
            let total = show.counted.reduce(UInt64(0)) { $0 &+ $1.bytes }
            let each = Double(total) / Double(show.counted.count)
            let paper = nodesOfRow.reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] }

            var bits: [String] = []
            let count = show.counted.count
            bits.append(count == 1 ? "1 episode" : "\(count) episodes, \(formatBytes(UInt64(each))) each")
            if shows.count >= 3, median > 0, each / median >= bigEpisodeRatio, each >= Double(bigEpisodeBytes) {
                bits[0] += ", \(Titles.timesText(each / median)) your other series"
            }
            let paths = show.counted.compactMap { tree.path($0.node).map(Facts.visible) }
            if let opened = paths.compactMap({ facts.lastOpened[$0] }).max() { bits.append("Opened \(Titles.dayText(opened, now: now))") }
            let plex = paths.compactMap { facts.plexFiles[$0] }
            if !plex.isEmpty {
                let watched = plex.filter { $0.views > 0 }.count
                if watched == 0 { bits.append("Not watched in Plex") }
                else if watched == plex.count { bits.append(watched == 1 ? "Watched in Plex" : "All \(watched) watched in Plex") }
                else { bits.append("\(watched) of \(plex.count) watched in Plex") }
            }
            let names = show.counted.map { (tree.name($0.node), $0.bytes) }
            let elsewhere = names.compactMap { also(on: facts, name: $0.0, size: $0.1) }
            if elsewhere.count == names.count, let disk = elsewhere.first {
                bits.insert(count == 1 ? "Same name and size on \(disk)" : "All \(count) have the same name and size on \(disk)", at: 0)
            } else if elsewhere.count >= 2, let disk = elsewhere.first {
                bits.append("\(elsewhere.count) of \(count) have the same name and size on \(disk)")
            }

            var row = WinRow(id: "series:" + show.key, title: show.name, subtitle: sentence(bits),
                             detail: "A series on your disk. If it's in a Plex library, Plex stops showing whatever goes.", tier: .yourCall, nodes: nodesOfRow, bytes: paper, paperBytes: paper,
                             action: .trash, command: nil, bundleID: nil)
            row.previewPath = paths.first
            addOtherCopies(to: &row, title: show.name, links: videoLinks, tree: tree, facts: facts, now: now)
            out.append(row)
        }

        // The same film in two qualities is one decision: which to keep.
        var filmsByFolder: [UInt32: [UInt32]] = [:]
        for film in films { filmsByFolder[nodes[Int(film)].parent, default: []].append(film) }
        var versioned = Set<UInt32>()
        for (folder, versions) in filmsByFolder where versions.count >= 2 && tree.nodes[Int(folder)].parent != 0 {
            let name = tree.name(folder)
            guard !Titles.isGeneralFolder(name) else { continue }
            let key = Titles.key(name)
            let same = versions.filter { Titles.key((tree.name($0) as NSString).deletingPathExtension).hasPrefix(key) }
            guard same.count >= 2 else { continue }
            versioned.formUnion(same)
            let parts = same.sorted { nodes[Int($0)].bytes > nodes[Int($1)].bytes }.map { version -> WinRow in
                let file = tree.name(version)
                let bytes = nodes[Int(version)].bytes
                return WinRow(id: "film:" + (tree.path(version) ?? file), title: (file as NSString).deletingPathExtension, subtitle: "One of \(same.count) versions in this folder.",
                              detail: "The same film in another quality. Plex shows both as one film, with a choice of versions.", tier: .yourCall, nodes: [version], bytes: bytes, paperBytes: bytes,
                              action: .trash, command: nil, bundleID: nil)
            }
            var group = WinRow(id: "versions:" + (tree.path(folder) ?? name), title: "\(name): \(same.count) versions", subtitle: parts.map { formatBytes($0.bytes) }.joined(separator: " and ") + ". You could keep just one.",
                               detail: "The same film in more than one quality. Open this row to choose which to remove.", tier: .yourCall, nodes: parts.flatMap(\.nodes), bytes: parts.reduce(0) { $0 &+ $1.bytes },
                               paperBytes: parts.reduce(0) { $0 &+ $1.paperBytes }, action: .trash, command: nil, bundleID: nil)
            group.parts = parts
            out.append(group)
        }

        for film in films where !versioned.contains(film) {
            let parent = nodes[Int(film)].parent
            let bytes = nodes[Int(film)].bytes
            let fileName = tree.name(film)
            // Its folder only if the folder is that film: named for it, and holding little else, counting links.
            let parentKey = Titles.key(tree.name(parent)), fileKey = Titles.key((fileName as NSString).deletingPathExtension)
            let isTheFilm = !parentKey.isEmpty && (parentKey.hasPrefix(fileKey) || fileKey.hasPrefix(parentKey))
            let holds = tree.totals[Int(parent)] &+ tree.aliasTotals[Int(parent)]
            let wholeFolder = isTheFilm && !Titles.isGeneralFolder(tree.name(parent)) && Double(bytes) >= Double(holds) * 0.9 && tree.path(parent).map(Safety.canTrash) == true
            let node = wholeFolder ? parent : film
            let title = wholeFolder ? tree.name(parent) : (fileName as NSString).deletingPathExtension
            guard let path = tree.path(film).map(Facts.visible) else { continue }
            let isLibrary = facts.plexFiles[path] != nil || path.split(separator: "/").contains { ["Movies", "Films", "Media", "TV", "Downloads", "Torrents"].contains(String($0)) }
            guard isLibrary else { continue }
            var bits: [String] = []
            if let disk = also(on: facts, name: fileName, size: bytes) { bits.append("Same name and size on \(disk)") }
            if let opened = facts.lastOpened[path] { bits.append("Opened \(Titles.dayText(opened, now: now))") }
            if let plex = facts.plexFiles[path] { bits.append(plex.views > 0 ? "Watched in Plex" : "Not watched in Plex") }
            if bits.isEmpty { bits.append("A video in \(DiskTree.friendly((path as NSString).deletingLastPathComponent))") }
            var row = WinRow(id: "film:" + (tree.path(node) ?? title), title: title, subtitle: sentence(bits),
                             detail: "A film on your disk. If it's in a Plex library, Plex stops showing it once it's gone.", tier: .yourCall, nodes: [node], bytes: tree.totals[Int(node)],
                             paperBytes: tree.totals[Int(node)], action: .trash, command: nil, bundleID: nil)
            row.previewPath = path
            addOtherCopies(to: &row, title: title, links: videoLinks, tree: tree, facts: facts, now: now)
            out.append(row)
        }
        return out
    }

    private static func sentence(_ bits: [String]) -> String {
        bits.joined(separator: ". ") + (bits.isEmpty ? "" : ".")
    }

    /// The same files in another folder: a torrent's, usually. They only free space once both are gone, so the row says
    /// what it would really give back, and the other copy gets its own tick.
    static func addOtherCopies(to row: inout WinRow, title: String, links: [LinkRecord], tree: DiskTree, facts: Facts, now: Date) {
        guard !links.isEmpty else { return }
        let found = Accounting.otherCopies(of: row.nodes, in: tree, links: links)
        guard !found.folders.isEmpty, found.bytes >= 50_000_000 else { return }
        row.bytes = row.paperBytes &- min(row.paperBytes, found.bytes)
        row.otherCopies = found.folders
        let paths = found.folders.compactMap { tree.path($0) }
        row.otherCopiesPath = paths.first.map(PathMath.visible)
        let torrents = paths.compactMap { facts.torrent(holding: Facts.visible($0)) }
        if !torrents.isEmpty {
            row.otherCopiesIsTorrent = true
            row.otherCopiesTitle = found.folders.count > 1 ? "Also remove the \(found.folders.count) torrent copies" : "Also remove the torrent copy"
            var note = "That's when you get \(formatBytes(row.paperBytes)) back. Transmission stops sharing \(found.folders.count > 1 ? "those torrents" : "that torrent")."
            // The newest one is the one that may still be sharing.
            if let finished = torrents.compactMap(\.finished).max() {
                let days = Int(now.timeIntervalSince(finished) / 86_400)
                if days < seedingDays {
                    let when = days == 0 ? "today" : (days == 1 ? "yesterday" : "\(days) days ago")
                    note = "That's when you get \(formatBytes(row.paperBytes)) back, but \(found.folders.count > 1 ? "the newest torrent" : "the torrent") only finished \(when), so it may still be sharing."
                    row.otherCopiesCaution = "\(found.folders.count > 1 ? "The newest torrent" : "The torrent") only finished \(when), so it may still be sharing."
                }
            }
            row.otherCopiesNote = note
        } else {
            row.otherCopiesTitle = "Also remove the copy in \(tree.name(tree.nodes[Int(found.folders[0])].parent))"
            row.otherCopiesNote = "That's when you get \(formatBytes(row.paperBytes)) back."
        }
    }

    // MARK: Apps

    static func apps(tree: DiskTree, facts: Facts, now: Date) -> [WinRow] {
        var parts: [WinRow] = []
        for app in facts.apps {
            guard let row = appRow(app, tree: tree, now: now) else { continue }
            parts.append(row)
        }
        guard !parts.isEmpty else { return [] }
        parts.sort { $0.bytes > $1.bytes }
        if parts.count == 1 { return parts }
        var group = WinRow(id: "group:quiet-apps", title: "\(parts.count) apps with no sign of use for 6 months", subtitle: parts.prefix(4).map(\.title).joined(separator: ", ") + (parts.count > 4 ? " and \(parts.count - 4) more." : "."),
                           detail: "Going by each app's own settings, caches and saved state, and by Spotlight. Open this row to decide about each one.", tier: .yourCall, nodes: parts.flatMap(\.nodes),
                           bytes: parts.reduce(0) { $0 &+ $1.bytes }, paperBytes: parts.reduce(0) { $0 &+ $1.paperBytes }, action: .uninstall, command: nil, bundleID: nil)
        group.parts = parts
        return [group]
    }

    static func appRow(_ app: AppFact, tree: DiskTree, now: Date) -> WinRow? {
        guard !app.isRunning, let newest = app.newestSign, app.signCount > 0 else { return nil }
        let day: TimeInterval = 86_400
        guard now.timeIntervalSince(newest) >= TimeInterval(appQuietDays) * day else { return nil }
        let data = "/System/Volumes/Data"
        guard let appNode = tree.find(path: data + app.path) ?? tree.find(path: app.path) else { return nil }
        var nodes = [appNode]
        var extras: [String] = []
        for path in app.settings {
            if let node = tree.find(path: data + path) ?? tree.find(path: path), tree.nodes[Int(node)].has(NodeFlag.synthetic) == false {
                nodes.append(node)
            } else {
                extras.append(path)
            }
        }
        var dataNodes: [UInt32] = []
        for path in app.data {
            if let node = tree.find(path: data + path) ?? tree.find(path: path) { dataNodes.append(node) }
        }
        let bytes = nodes.reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] }
        var bits = ["No sign of use for \(Titles.monthsText(since: newest, now: now))"]
        if app.fromAppStore { bits.append("You can download this again from the App Store") }
        if let note = app.makerNote { bits.append(String(note.dropLast())) }
        var row = WinRow(id: "app:" + app.bundleID, title: app.name, subtitle: sentence(bits),
                         detail: "Uninstalling moves the app, its settings and its caches to the Trash. Going by the app's own files and by Spotlight, so this may be wrong about an app that only runs in the background.",
                         tier: .yourCall, nodes: nodes, bytes: bytes, paperBytes: bytes, action: .uninstall, command: nil, bundleID: app.bundleID)
        row.appPath = app.path
        row.extraPaths = extras
        let dataBytes = dataNodes.reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] }
        if dataBytes >= 1_000_000 {
            row.alsoNodes = dataNodes
            row.alsoTitle = "Also remove its data: \(formatBytes(dataBytes))"
            row.alsoNote = "May hold your own work, so this stays unless you say so."
        }
        return row
    }

    // MARK: Games

    static func games(tree: DiskTree, facts: Facts, now: Date) -> [WinRow] {
        var out: [WinRow] = []
        for game in facts.games {
            guard let node = tree.find(path: "/System/Volumes/Data" + game.folder) ?? tree.find(path: game.folder) else { continue }
            var bits: [String] = []
            if let played = game.lastPlayed { bits.append("Last played \(Titles.dayText(played, now: now))") }
            bits.append("Steam can download this again")
            let bytes = tree.totals[Int(node)]
            var row = WinRow(id: "steam:" + game.appID, title: game.name, subtitle: sentence(bits),
                             detail: "Check first that your saves are in Steam Cloud. Steam shows this game as not installed afterwards, and you can install the game again from there.", tier: .redownload, nodes: [node], bytes: bytes, paperBytes: bytes,
                             action: .trash, command: nil, bundleID: "com.valvesoftware.steam")
            row.extraPaths = [game.manifest]
            // Saves may only be on this Mac, so a game only goes on a tick of your own.
            row.askFirst = true
            if let played = game.lastPlayed, now.timeIntervalSince(played) < 14 * 86_400 { row.inUse = "Played in the last two weeks" }
            out.append(row)
        }
        return out
    }

    // MARK: AI models

    /// Each model in a Hugging Face cache is a decision of its own. A cache's folders are named `models--org--name`.
    static func models(tree: DiskTree, facts: Facts, rows: inout [WinRow]) -> [WinRow] {
        var parts: [WinRow] = []
        for model in facts.models {
            guard Safety.canTrash(model.folder), !model.name.isEmpty else { continue }
            var nodes: [UInt32] = []
            var extras: [String] = []
            if let folder = tree.find(path: model.folder) { nodes.append(folder) } else { extras.append(model.folder) }
            for blob in model.blobs {
                if let node = tree.find(path: "/System/Volumes/Data" + blob) ?? tree.find(path: blob) { nodes.append(node) } else { extras.append(blob) }
            }
            let onTheMap = nodes.reduce(UInt64(0)) { $0 &+ tree.totals[Int($1)] }
            let bytes = max(onTheMap, model.blobBytes)
            guard bytes >= 50_000_000, !nodes.isEmpty else { continue }
            var bits = ["Can be downloaded again from Hugging Face"]
            if let changed = model.changed { bits.append("Downloaded \(Titles.dayText(changed))") }
            var row = WinRow(id: "model:" + model.name, title: model.name, subtitle: sentence(bits), detail: "AI model weights. It downloads again the next time something asks for it.",
                             tier: .redownload, nodes: nodes, bytes: bytes, paperBytes: bytes, action: .trash, command: nil, bundleID: nil)
            row.extraPaths = extras
            parts.append(row)
        }
        guard !parts.isEmpty else { return [] }
        parts.sort { $0.bytes > $1.bytes }
        let taken = parts.flatMap(\.nodes)
        // A rule's one row for the whole cache gives way to one row per model.
        rows.removeAll { row in
            row.isPlannable && row.tier == .redownload && row.nodes.count == 1 && taken.contains { tree.isInside($0, row.nodes[0]) }
        }
        if parts.count == 1 { return parts }
        var group = WinRow(id: "group:models", title: "\(parts.count) AI models", subtitle: parts.prefix(3).map { $0.title.split(separator: "/").last.map(String.init) ?? $0.title }.joined(separator: ", ") + (parts.count > 3 ? " and \(parts.count - 3) more." : "."),
                           detail: "AI model weights from Hugging Face. Each one downloads again the next time something asks for it.", tier: .redownload, nodes: taken,
                           bytes: parts.reduce(0) { $0 &+ $1.bytes }, paperBytes: parts.reduce(0) { $0 &+ $1.paperBytes }, action: .trash, command: nil, bundleID: nil)
        group.parts = parts
        return [group]
    }

    // MARK: Projects

    static func projects(tree: DiskTree, facts: Facts, now: Date) -> [WinRow] {
        var parts: [WinRow] = []
        for repo in facts.repos.values {
            // Never the only copy of your own work.
            guard repo.isClean, repo.allPushed, let remote = repo.remote, let last = repo.lastCommit,
                  now.timeIntervalSince(last) >= TimeInterval(projectQuietDays) * 86_400, let node = tree.find(path: repo.path), Safety.canTrash(repo.path) else { continue }
            // Worked on lately, even without a commit.
            if tree.statRow(node)[DiskTree.statRecent30] > 0 { continue }
            let bytes = tree.totals[Int(node)]
            let row = WinRow(id: "repo:" + repo.path, title: tree.name(node),
                             subtitle: "Last commit \(Titles.monthsText(since: last, now: now)) ago. Everything is pushed, so you can clone this project again from \(shortRemote(remote)).",
                             detail: "Files that git ignores aren't in that copy: settings, data and anything you generated. Open this row to check what's there.", tier: .yourCall, nodes: [node], bytes: bytes, paperBytes: bytes,
                             action: .trash, command: nil, bundleID: nil)
            parts.append(row)
        }
        guard !parts.isEmpty else { return [] }
        parts.sort { $0.bytes > $1.bytes }
        if parts.count == 1 { return parts }
        var group = WinRow(id: "group:quiet-projects", title: "\(parts.count) projects you could clone again", subtitle: "Nothing changed for 6 months, and everything is pushed.",
                           detail: "Only projects with no uncommitted work, every branch pushed, and nothing in a stash. Files that git ignores aren't in that copy.", tier: .yourCall, nodes: parts.flatMap(\.nodes),
                           bytes: parts.reduce(0) { $0 &+ $1.bytes }, paperBytes: parts.reduce(0) { $0 &+ $1.paperBytes }, action: .trash, command: nil, bundleID: nil)
        group.parts = parts
        return [group]
    }

    private static func shortRemote(_ remote: String) -> String {
        var text = remote
        for prefix in ["https://", "http://", "git@", "ssh://git@"] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        text = text.replacingOccurrences(of: ":", with: "/")
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        return text
    }

    // MARK: Frames

    static func frames(tree: DiskTree, facts: Facts) -> [WinRow] {
        var parts: [WinRow] = []
        for folder in facts.frames.values {
            guard let node = tree.find(path: folder.path), Safety.canTrash(folder.path) else { continue }
            let bytes = tree.totals[Int(node)]
            let parent = tree.name(tree.nodes[Int(node)].parent)
            var text = "\(folder.frames.formatted()) numbered frames"
            if let video = folder.video { text += " next to \(video)" }
            let above = tree.name(tree.nodes[Int(tree.nodes[Int(node)].parent)].parent)
            parts.append(WinRow(id: "frames:" + folder.path, title: "\(above) › \(parent) › \(tree.name(node))", subtitle: text + ".",
                                detail: "Numbered images like these are often rendered frames, which can be made again if you still have what made them. Look before you decide.", tier: .yourCall, nodes: [node], bytes: bytes, paperBytes: bytes,
                                action: .trash, command: nil, bundleID: nil))
        }
        guard !parts.isEmpty else { return [] }
        parts.sort { $0.bytes > $1.bytes }
        if parts.count == 1 { return parts }
        var group = WinRow(id: "group:frames", title: "\(parts.count) folders of numbered frames", subtitle: parts.prefix(3).map(\.title).joined(separator: ", ") + (parts.count > 3 ? " and \(parts.count - 3) more." : "."),
                           detail: "Numbered images like these are often rendered frames, which can be made again if you still have what made them. Look before you decide.", tier: .yourCall, nodes: parts.flatMap(\.nodes),
                           bytes: parts.reduce(0) { $0 &+ $1.bytes }, paperBytes: parts.reduce(0) { $0 &+ $1.paperBytes }, action: .trash, command: nil, bundleID: nil)
        group.parts = parts
        return [group]
    }

    // MARK: For another app to manage

    /// Some things only their own app can look after. Removing files from inside them would break them, so these get an
    /// explanation and a way there, and never a tick.
    static func handOffs(tree: DiskTree) -> [WinRow] {
        guard tree.home != 0 else { return [] }
        struct HandOff { var path: String; var id: String; var title: String; var app: String; var detail: String }
        let list = [
            HandOff(path: "Pictures/Photos Library.photoslibrary", id: "com.apple.Photos", title: "Photos library", app: "Photos",
                    detail: "Only Photos can look after this safely. If you use iCloud Photos, Optimize Mac Storage in its settings keeps smaller copies here."),
            HandOff(path: "Library/Messages", id: "com.apple.MobileSMS", title: "Messages", app: "Messages",
                    detail: "Messages can delete old messages and attachments itself: see Keep Messages in its settings."),
            HandOff(path: "Library/Mail", id: "com.apple.mail", title: "Mail", app: "Mail",
                    detail: "Only Mail can look after this safely. Removing a mailbox or an account in Mail is what frees this space."),
            HandOff(path: "Music/Music", id: "com.apple.Music", title: "Music library", app: "Music",
                    detail: "Only Music can look after this safely. Remove downloads from inside Music."),
        ]
        var out: [WinRow] = []
        for thing in list {
            guard let node = tree.find(path: "/System/Volumes/Data" + NSHomeDirectory() + "/" + thing.path), tree.totals[Int(node)] >= 1_000_000_000 else { continue }
            var row = WinRow(id: "handoff:" + thing.id, title: thing.title, subtitle: "Managed by \(thing.app), so this isn't something to remove by hand.", detail: thing.detail, tier: .handsOff, nodes: [node],
                             bytes: tree.totals[Int(node)], paperBytes: tree.totals[Int(node)], action: .openApp, command: nil, bundleID: thing.id)
            row.openAppName = thing.app
            out.append(row)
        }
        return out
    }

    // MARK: Left behind

    static func leftBehind(tree: DiskTree, facts: Facts) -> [WinRow] {
        var parts: [WinRow] = []
        for thing in facts.leftBehind {
            guard let node = tree.find(path: "/System/Volumes/Data" + thing.path) ?? tree.find(path: thing.path), tree.totals[Int(node)] >= 50_000_000, Safety.canTrash(thing.path) else { continue }
            let bytes = tree.totals[Int(node)]
            parts.append(WinRow(id: "left:" + thing.path, title: Wins.appName(forFolder: thing.bundleID), subtitle: "\(thing.bundleID), in \(thing.place). The app isn't on this Mac.",
                                detail: "An app's data, with no app to go with it. It may be from an app you've removed, or one that's on a disk that isn't plugged in.", tier: .yourCall, nodes: [node], bytes: bytes, paperBytes: bytes,
                                action: .trash, command: nil, bundleID: nil))
        }
        guard !parts.isEmpty else { return [] }
        parts.sort { $0.bytes > $1.bytes }
        if parts.count == 1 { return parts }
        var group = WinRow(id: "group:left-behind", title: "Left behind by apps you no longer have", subtitle: parts.prefix(3).map(\.title).joined(separator: ", ") + (parts.count > 3 ? " and \(parts.count - 3) more." : "."),
                           detail: "Only folders named with a full app ID, where that app isn't on this Mac. An app on a disk that isn't plugged in would look the same.", tier: .yourCall, nodes: parts.flatMap(\.nodes),
                           bytes: parts.reduce(0) { $0 &+ $1.bytes }, paperBytes: parts.reduce(0) { $0 &+ $1.paperBytes }, action: .trash, command: nil, bundleID: nil)
        group.parts = parts
        return [group]
    }
}

extension AppModel {
    /// Reads other apps' records, off the main thread, and then looks at the suggestions again.
    func gatherFacts(for tree: DiskTree, afresh: Bool = false) {
        if factsRunning {
            factsWanted = factsWanted || afresh
            return
        }
        guard afresh || Date().timeIntervalSince(facts.gatheredAt) > 30 else { return }
        factsRunning = true
        // At launch these are read for the saved map, and again when the scan that follows has finished, seconds later.
        let earlier = factsOfSavedMap && afresh && Date().timeIntervalSince(facts.gatheredAt) < 300 ? facts : nil
        factsOfSavedMap = !afresh
        let fullAccess = hasFullAccess
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> PlanChecks.RunningApp? in
            guard let id = app.bundleIdentifier else { return nil }
            return PlanChecks.RunningApp(bundleID: id, name: app.localizedName ?? id)
        }
        Task.detached(priority: .utility) {
            let gathered = Facts.gather(tree: tree, running: apps, fullAccess: fullAccess, reusing: earlier)
            await MainActor.run {
                self.factsRunning = false
                self.facts = gathered
                self.rebuildInsights()
                if self.factsWanted, let current = self.tree {
                    self.factsWanted = false
                    self.gatherFacts(for: current, afresh: true)
                }
            }
        }
    }
}
