import Foundation

/// Reading the map for an agent. Everything in this type only looks: nothing changes the map, the plan or the disk. The
/// three tools that select and show are carried out by the model, in `AgentAPI`.
///
/// A file or folder is named by its path as you'd write it (`~/Movies`, or the same in full). A group Headroom makes up, such as
/// macOS's own parts, has no path, so it gets a reference that holds for this scan only.
enum AgentLook {
    static let tools: [AgentTool] = [
        AgentTool(name: "overview",
                  description: "The disk Headroom is showing and the other disks it could show: size, free space, how far the scan has got, and how much is selected for removal."),
        AgentTool(name: "check",
                  description: "What Headroom knows about paths you found, before you select them: whether each is on its map, its size, what removing it would really free (a hardlinked or cloned file frees nothing while its other copies stay, and they are named), what kind of thing it is, whether it is protected, and whether it is already selected.",
                  properties: ["paths": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": mostChecked, "description": "Absolute paths."]],
                  required: ["paths"]),
        AgentTool(name: "list_suggestions",
                  description: "What Headroom itself suggests removing, as the user sees it in Free Up: each with an id, a size, how safe it is to remove and where it is. Select one with select_suggestions.",
                  properties: ["group": ["type": "string", "description": "Only this group, by its title, with every path. Without it, every group, a few paths each."]]),
        AgentTool(name: "list_duplicates",
                  description: "Duplicates, hard links, clones and symlinks Headroom has found, with what removing the extra copies would free. Headroom only reads these when its Copies view has been opened.",
                  properties: ["limit": ["type": "integer", "minimum": 1, "maximum": most, "description": "How many groups to return. 30 unless given."]]),
        AgentTool(name: "get_plan",
                  description: "What is selected for removal in Headroom right now, who selected it, how much it frees, and what Headroom's checks say about each item."),
        AgentTool(name: "select",
                  description: "Select files and folders for removal in Headroom, so the user sees them on the map and in Free Up under your name. Nothing is removed: the user reviews the selection and cleans in Headroom. Find the paths with your own tools first. The answer says what each really frees, and names the other copies of anything hardlinked or cloned. Protected places are refused.",
                  properties: ["paths": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": mostSelected, "description": "Absolute paths."],
                               "reason": ["type": "string", "description": "One short line the user sees beside these in Headroom: why they can go."]],
                  required: ["paths", "reason"], selects: true),
        AgentTool(name: "select_suggestions",
                  description: "Select Headroom's own suggestions by id, as a tick in Free Up does: an app goes with its data, a cache with what belongs to it, the Trash is emptied.",
                  properties: ["ids": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": mostSelected, "description": "Ids from list_suggestions."]],
                  required: ["ids"], selects: true),
        AgentTool(name: "deselect",
                  description: "Take back what an agent selected, by path or by suggestion id. What the user selected themselves stays selected.",
                  properties: ["paths": ["type": "array", "items": ["type": "string"], "maxItems": mostSelected, "description": "Absolute paths."],
                               "ids": ["type": "array", "items": ["type": "string"], "maxItems": mostSelected, "description": "Suggestion ids."]],
                  selects: true),
        AgentTool(name: "show",
                  description: "Bring Headroom's window forward so the user can look: on Free Up, Backup or the map, inside a folder when one is given.",
                  properties: ["path": ["type": "string", "description": "A folder to show. A file is shown in its folder."],
                               "view": ["type": "string", "enum": ["free_up", "backup", "map"], "description": "free_up unless given."]],
                  selects: true),
        AgentTool(name: "switch_disk",
                  description: "Have Headroom show another disk, by its name or path from overview. It reads that disk, which takes a moment: overview says when it is read.",
                  properties: ["disk": ["type": "string", "description": "The disk's name or path."]],
                  required: ["disk"], selects: true),
        AgentTool(name: "get_backup",
                  description: "Backup's list: big files the user moves to another drive, leaving a note in place of each. Returns the drive and whether it's connected, the selected files, what Move would do now or why it can't, and the files already moved.",
                  properties: ["limit": ["type": "integer", "minimum": 1, "maximum": most, "description": "How many selected and moved files to list. 50 unless given."]]),
        AgentTool(name: "select_for_backup",
                  description: "Select files of 10 MB or more for Backup. When the user clicks Move, each is copied and verified, a note takes its place, and the original goes to the Trash. Folders aren't accepted. A file selected here is taken off Free Up's list. Nothing moves until the user clicks Move.",
                  properties: ["paths": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": mostSelected, "description": "Absolute paths of files."],
                               "reason": ["type": "string", "description": "One short line the user sees beside these: why they can live on the drive."]],
                  required: ["paths", "reason"], selects: true),
        AgentTool(name: "deselect_for_backup",
                  description: "Take files off Backup's list that an agent selected. What the user selected stays.",
                  properties: ["paths": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": mostSelected, "description": "Absolute paths."]],
                  required: ["paths"], selects: true),
        AgentTool(name: "set_backup_drive",
                  description: "Set the drive Backup moves files to, by name or path from overview, and optionally a folder on it. Not the disk Headroom is showing, and not a read-only drive.",
                  properties: ["drive": ["type": "string", "description": "The drive's name or path."],
                               "folder": ["type": "string", "description": "A folder on the drive, from its top. The top of the drive unless given."]],
                  required: ["drive"], selects: true),
        AgentTool(name: "verify_moved",
                  description: "Read moved files on their drive again and compare each with the hash its note keeps. Only reads. Without paths, every moved file whose drive is connected.",
                  properties: ["paths": ["type": "array", "items": ["type": "string"], "maxItems": mostSelected, "description": "Where the files were on the Mac, as get_backup lists them."]],
                  selects: true),
        AgentTool(name: "wait_for_backup",
                  description: "Wait until the user moves or copies Backup's files, or a verify ends, then report each file. Returns unfinished after the timeout; call again to keep waiting.",
                  properties: ["timeout_seconds": ["type": "integer", "minimum": 1, "maximum": longestWait, "description": "How long to wait. 600 unless given."]]),
        AgentTool(name: "wait_for_clean",
                  description: "Wait until the user has cleaned in Headroom, then say what went to the Trash, how much that frees and what could not go. Call it after show, when the selection is ready for the user. It returns unfinished after the time given, and can be called again.",
                  properties: ["timeout_seconds": ["type": "integer", "minimum": 1, "maximum": longestWait, "description": "How long to wait. 600 unless given."]]),
    ]

    /// As many paths as one call selects or deselects, and as many as one call asks about.
    static let mostSelected = 200
    static let mostChecked = 50
    /// The longest one call waits for a clean, in seconds.
    static let longestWait = 3600

    /// The most of anything one answer holds.
    static let most = 500
    /// As many paths as are listed for one suggestion or one group of copies. The rest are counted.
    static let mostPaths = 20

    // MARK: References

    /// What an agent calls this node: its path as you'd write it, or a reference for a group that has no path.
    static func reference(_ node: UInt32, in tree: DiskTree) -> String {
        if let path = tree.path(node) { return PathMath.visible(path) }
        return "node:\(node)@\(tree.scanID.uuidString.prefix(8))"
    }

    /// The node an agent means, or why there isn't one.
    static func node(_ reference: String, in tree: DiskTree) throws -> UInt32 {
        if reference.hasPrefix("node:") {
            let parts = reference.dropFirst(5).split(separator: "@")
            guard parts.count == 2, let index = UInt32(parts[0]), Int(index) < tree.count else { throw AgentFailure("No such reference: \(reference)") }
            guard parts[1] == tree.scanID.uuidString.prefix(8) else {
                throw AgentFailure("That reference is from an earlier scan. List the folder again for the current one.")
            }
            return index
        }
        let path = written(reference)
        // As written, or where it really is: `/tmp` is a link to `/private/tmp`, and the map has the real place.
        guard let found = tree.find(path: path) ?? tree.find(visible: path) ?? real(path).flatMap({ tree.find(path: $0) ?? tree.find(visible: $0) }),
              !tree.nodes[Int(found)].has(NodeFlag.gone) else {
            throw AgentFailure("Not on the map: \(reference). It may be too small to be listed by itself, not there, or not read yet.")
        }
        return found
    }

    /// A path as an agent wrote it, in full and without a slash at the end.
    static func written(_ reference: String) -> String {
        var path = reference
        if path == "~" || path.hasPrefix("~/") { path = NSHomeDirectory() + path.dropFirst() }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Where a path really is, with the links on the way to it followed. The last part is left as it is: a link that's
    /// selected is the link, not what it points to. Nil when the folder it's in isn't there.
    static func real(_ path: String) -> String? {
        let folder = (path as NSString).deletingLastPathComponent, name = (path as NSString).lastPathComponent
        guard !name.isEmpty, let resolved = realpath(folder, nil) else { return nil }
        defer { free(resolved) }
        let parent = String(cString: resolved)
        return parent == "/" ? "/" + name : parent + "/" + name
    }

    // MARK: One entry

    static let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func type(of node: UInt32, in tree: DiskTree) -> String {
        let n = tree.nodes[Int(node)]
        if n.has(NodeFlag.free) { return "free space" }
        if n.has(NodeFlag.hidden) { return "space the scan can't account for" }
        if n.has(NodeFlag.synthetic) { return "group" }
        return n.has(NodeFlag.directory) ? "folder" : "file"
    }

    /// A file or folder as one line of an answer.
    static func entry(_ node: UInt32, in tree: DiskTree) -> [String: Any] {
        let n = tree.nodes[Int(node)]
        let bytes = tree.totals[Int(node)]
        var out: [String: Any] = [
            "name": tree.name(node),
            "path": reference(node, in: tree),
            "type": type(of: node, in: tree),
            "size": bytes,
            "size_text": formatBytes(bytes),
        ]
        if n.has(NodeFlag.directory) || n.has(NodeFlag.synthetic) {
            let files = tree.totalFiles[Int(node)]
            if files > 0 { out["files"] = files }
        } else {
            out["kind"] = (Kind(rawValue: n.kind) ?? .other).title
        }
        let newest = tree.newest[Int(node)]
        if newest > 0 { out["changed"] = dates.string(from: Date(timeIntervalSince1970: TimeInterval(newest))) }
        if n.has(NodeFlag.denied) || n.has(NodeFlag.locked) { out["unreadable"] = true }
        if n.has(NodeFlag.incomplete) || n.has(NodeFlag.unread) { out["still_being_read"] = true }
        if n.has(NodeFlag.alias) { out["counted_elsewhere"] = true }
        return out
    }

    // MARK: Asking

    static func limit(_ arguments: [String: Any], _ key: String = "limit") -> Int {
        min(max(integer(arguments[key]) ?? 30, 1), most)
    }

    /// A whole number, however the agent's JSON wrote it.
    static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// What removing one thing would really give back, and where the other copies of what's hardlinked or cloned are.
    /// `others` is everything else that's going: a file frees its bytes once all its paths go, so what this one adds is
    /// what goes with it less what goes without it. The last copy to be selected is the one that frees the file.
    static func gain(of node: UInt32, with others: [UInt32] = [], except excluded: [UInt32] = [], in tree: DiskTree) -> [String: Any] {
        let rest = others.filter { $0 != node }
        let with = Accounting.effect(of: [node] + rest, except: excluded, in: tree).total
        let without = rest.isEmpty ? 0 : Accounting.effect(of: rest, except: excluded, in: tree).total
        let frees = with &- min(with, without)
        // What it adds up to, with the links and clones in it that are counted somewhere else.
        let onPaper = tree.totals[Int(node)] &+ max(tree.aliasTotals[Int(node)], tree.nodes[Int(node)].aliasBytes)
        var out: [String: Any] = ["frees": frees, "frees_text": formatBytes(frees)]
        guard onPaper > frees, onPaper - frees >= 1_000_000 else { return out }
        let shared = onPaper - frees
        let copies = Accounting.otherCopies(of: [node], in: tree)
        var sharing: [String: Any] = ["size": shared, "size_text": formatBytes(shared),
                                      "note": "Hardlinked or cloned: this much is only freed when the other copies go too."]
        if !copies.folders.isEmpty { sharing.merge(places(copies.folders, in: tree)) { a, _ in a } }
        out["shared_with_other_copies"] = sharing
        return out
    }

    /// Which program has files open in a path, as Headroom's own check before a clean sees it. Something in use is held
    /// back when the user cleans, until it's closed or they say clean anyway.
    static func inUse(_ path: String, open: OpenFiles?) -> String? {
        guard let users = open?.users(of: path) else { return nil }
        let who = users.others == 0 ? users.first.process : "\(users.first.process) and \(users.others) more"
        return who + (users.runFromHere ? " is running from here" : " has files open here")
            + ". Headroom holds it back when the user cleans, until it's closed or they choose Clean anyway."
    }

    /// What Headroom knows about one path an agent found.
    static func check(_ reference: String, in tree: DiskTree, rules: RuleBook, plan: PlanList, planned: [UInt32] = [], excluded: [UInt32] = [],
                      open: OpenFiles? = nil) -> [String: Any] {
        if let moved = MovedNote.read(at: MovedNote.notePath(for: written(reference))) ?? MovedNote.read(at: written(reference)) {
            // Only a note is here: the file is on a drive.
            return ["path": moved.originalPath, "exists": false, "moved_to": moved.driveName, "size": moved.size, "size_text": formatBytes(moved.size)]
        }
        guard let node = try? node(reference, in: tree) else {
            // Not on the map: newer than the last scan, too small to be listed, or not there at all.
            let path = PathMath.visible(real(written(reference)) ?? written(reference))
            var info = stat()
            guard lstat(path, &info) == 0 else { return ["path": path, "exists": false] }
            var out: [String: Any] = ["path": path, "exists": true, "on_the_map": false, "headroom_would_remove_it": Safety.canTrash(path), "selected_for_removal": plan.covers(path)]
            if let busy = inUse(path, open: open) { out["in_use"] = busy }
            return out
        }
        var out = item(node, in: tree, rules: rules)
        out["on_the_map"] = true
        if let path = tree.path(node) {
            out["selected_for_removal"] = plan.covers(PathMath.visible(path))
            if let busy = inUse(PathMath.visible(path), open: open) { out["in_use"] = busy }
            out.merge(gain(of: node, with: planned, except: excluded, in: tree)) { a, _ in a }
        }
        return out
    }

    static func item(_ node: UInt32, in tree: DiskTree, rules: RuleBook) -> [String: Any] {
        let n = tree.nodes[Int(node)]
        var out = entry(node, in: tree)
        if node != 0 { out["inside"] = Self.reference(n.parent, in: tree) }
        if n.has(NodeFlag.directory) || n.has(NodeFlag.synthetic) {
            let kinds = tree.kindBytes(node).enumerated().filter { $0.element > 0 }.sorted { $0.element > $1.element }
            out["holds"] = kinds.prefix(6).map { ["kind": (Kind(rawValue: UInt8($0.offset)) ?? .other).title, "size": $0.element, "size_text": formatBytes($0.element)] as [String: Any] }
        }
        let rule = rules.rule(n.rule)
        if rule.tier != .none, !rule.title.isEmpty {
            out["known_as"] = ["what": rule.title, "about": rule.detail, "removing_it": rule.tier.title + ". " + rule.tier.promise] as [String: Any]
        }
        if let path = tree.path(node) { out["headroom_would_remove_it"] = Safety.canTrash(path) }
        return out
    }

    /// Where a set of nodes is, as many as an answer has room for, and how many more there are.
    static func places(_ nodes: [UInt32], more extra: [String] = [], atMost: Int = mostPaths, in tree: DiskTree) -> [String: Any] {
        let all = nodes.filter { Int($0) < tree.count }.map { reference($0, in: tree) } + extra.map(PathMath.visible)
        var out: [String: Any] = ["paths": Array(all.prefix(atMost))]
        if all.count > atMost { out["more_paths"] = all.count - atMost }
        return out
    }

    /// One suggestion, as Free Up shows it.
    static func suggestion(_ row: WinRow, inFull: Bool = true, in tree: DiskTree) -> [String: Any] {
        var out: [String: Any] = [
            "id": row.id,
            "title": row.title,
            "size": row.gain,
            "size_text": formatBytes(row.gain),
            "removing_it": row.tier.title + ". " + row.tier.promise,
            "recommended": row.isRecommended,
        ]
        if !row.subtitle.isEmpty { out["subtitle"] = row.subtitle }
        if inFull, !row.detail.isEmpty { out["about"] = row.detail }
        if let inUse = row.inUse { out["in_use"] = inUse }
        if row.askFirst { out["ask_the_user_first"] = true }
        if let command = row.command { out["better_done_with"] = command }
        if !row.isPlannable { out["how"] = how(row.action) }
        out.merge(places(row.nodes, more: row.extraPaths, atMost: inFull ? mostPaths : 3, in: tree)) { a, _ in a }
        return out
    }

    private static func how(_ action: WinAction) -> String {
        switch action {
        case .trash, .uninstall, .emptyTrash: "Headroom can remove it."
        case .restart: "A restart clears it."
        case .softwareUpdate: "Installing the waiting update clears it."
        case .openApp: "Only its own app can manage it safely."
        case .command: "Better done with its own tool."
        case .info: "macOS looks after it."
        }
    }

    /// Every group with a few paths each, or one group, named by its title, in full.
    static func suggestions(_ all: Suggestions, group wanted: String? = nil, in tree: DiskTree) throws -> [String: Any] {
        let inFull = wanted != nil
        func group(_ section: Section) -> [String: Any] {
            var out: [String: Any] = ["title": section.title, "suggestions": section.rows.map { suggestion($0, inFull: inFull, in: tree) }]
            if inFull { out["about"] = section.detail }
            if let note = section.note { out["note"] = note }
            if section.isShortlist { out["a_list_to_pick_from_not_a_suggestion"] = true }
            if !section.kids.isEmpty { out["groups"] = section.kids.map(group) }
            let bytes = section.allRows.reduce(UInt64(0)) { $0 &+ $1.gain }
            out["size"] = bytes
            out["size_text"] = formatBytes(bytes)
            return out
        }
        if let wanted {
            func find(_ sections: [Section]) -> Section? {
                for one in sections {
                    if one.title.caseInsensitiveCompare(wanted) == .orderedSame { return one }
                    if let inside = find(one.kids) { return inside }
                }
                return nil
            }
            guard let one = find(all.sections) else { throw AgentFailure("No such group: \(wanted). One of: " + all.sections.map(\.title).joined(separator: ", ")) }
            return group(one)
        }
        let recommended = all.rows.filter(\.isRecommended).reduce(UInt64(0)) { $0 &+ $1.gain }
        return [
            "groups": all.sections.map(group),
            "not_for_headroom_to_remove": all.others.map { suggestion($0, inFull: false, in: tree) },
            "recommended_size": recommended,
            "recommended_size_text": formatBytes(recommended),
        ]
    }

    static func duplicates(_ copies: CopiesMap?, reading: Bool, arguments: [String: Any], in tree: DiskTree) -> [String: Any] {
        guard let copies, copies.scanID == tree.scanID else {
            return ["state": reading ? "being read" : "not read yet: Headroom reads copies when its Copies view is opened"]
        }
        let groups = copies.groups.prefix(limit(arguments)).map { group -> [String: Any] in
            var out: [String: Any] = ["kind": group.kind.title, "title": group.title, "size": group.size, "size_text": formatBytes(group.size)]
            if group.back > 0 {
                out["removing_extras_frees"] = group.back
                out["removing_extras_frees_text"] = formatBytes(group.back)
            }
            if let target = group.target { out["points_to"] = target }
            out.merge(places(group.nodes, in: tree)) { a, _ in a }
            return out
        }
        return [
            "state": copies.duplicatesDone && !reading ? "read" : "being read",
            "groups": groups,
            "groups_in_all": copies.groups.count,
            "removing_every_extra_copy_frees": copies.back,
            "removing_every_extra_copy_frees_text": formatBytes(copies.back),
        ]
    }

    static func plan(_ list: PlanList, numbers: PlanNumbers, checks: [String: ItemCheck], isChecking: Bool, isCleaning: Bool) -> [String: Any] {
        let items = list.items.map { item -> [String: Any] in
            var out: [String: Any] = [
                "id": item.id,
                "title": item.title,
                "paths": item.paths.prefix(mostPaths).map(PathMath.visible),
                "selected": dates.string(from: item.addedAt),
                "step": step(item.step),
            ]
            if item.paths.count > mostPaths { out["more_paths"] = item.paths.count - mostPaths }
            if !item.note.isEmpty { out["note"] = item.note }
            out["selected_by"] = item.agent ?? "the user"
            if !item.excluded.isEmpty { out["except"] = item.excluded.prefix(mostPaths).map(PathMath.visible) }
            if let bytes = numbers.byItem[item.id] {
                out["frees"] = bytes
                out["frees_text"] = formatBytes(bytes)
            }
            if let check = checks[item.id] {
                out["can_go"] = check.canGo
                if !check.problems.isEmpty { out["checks"] = check.problems.map(\.text) }
            } else {
                out["checked"] = false
            }
            return out
        }
        // What the Clean button would take now: what's held back, by an open app or a file in use, waits for the user.
        let ready = list.items.filter { checks[$0.id]?.canGo ?? true }
        let readyBytes = ready.reduce(UInt64(0)) { $0 &+ (numbers.byItem[$1.id] ?? $1.lastKnownBytes) }
        var out: [String: Any] = [
            "items": items,
            "frees": numbers.total,
            "frees_text": formatBytes(numbers.total),
            "clean_now_frees": readyBytes,
            "clean_now_frees_text": formatBytes(readyBytes),
            "being_checked": isChecking,
            "being_cleaned": isCleaning,
        ]
        if ready.count < list.count {
            out["held_back"] = "\(list.count - ready.count) of \(list.count) items wait for the user: Clean takes \(formatBytes(readyBytes)) now. They go when what holds them is closed, or when the user clicks Clean anyway."
        }
        return out
    }

    /// What a clean did, once it's over.
    static func cleaned(_ after: AfterClean, free: UInt64?) -> [String: Any] {
        // What this clean moved. Emptying the Trash can give back more: what was in it before goes too, when you say so.
        let moved = after.things.reduce(UInt64(0)) { $0 &+ $1.bytes }
        var out: [String: Any] = [
            "finished": true,
            "moved_to_trash": after.things.count,
            "size": moved,
            "size_text": formatBytes(moved),
            "items": after.things.prefix(mostPaths).map { ["title": $0.title, "was_at": PathMath.visible($0.original), "size": $0.bytes] as [String: Any] },
        ]
        if after.things.count > mostPaths { out["more_items"] = after.things.count - mostPaths }
        if after.bytes != moved {
            out["emptying_the_trash_frees"] = after.bytes
            out["emptying_the_trash_frees_text"] = formatBytes(after.bytes)
        }
        if after.failed > 0 { out["could_not_go"] = after.failed }
        if after.heldBack > 0 { out["held_back_by_checks"] = after.heldBack }
        switch after.state {
        case .waiting: out["state"] = "In the Trash. The space comes back when the user empties the Trash, and until then they can undo."
        case .emptying: out["state"] = "The Trash is being emptied."
        case .done(let got): out["state"] = "The Trash was emptied: \(formatBytes(got)) came back."
        }
        if let free {
            out["free_now"] = free
            out["free_now_text"] = formatBytes(free)
        }
        return out
    }

    private static func step(_ step: PlanStep) -> String {
        switch step {
        case .trash: "Move to Trash"
        case .uninstall: "Uninstall"
        case .move(let folder): "Move to \(PathMath.visible(folder))"
        case .emptyTrash: "Empty Trash"
        }
    }
}

/// Answers an agent's requests from what the app has on screen.
@MainActor
struct AgentAPI {
    let model: AppModel

    /// The answer to one request, ready to be written as JSON.
    func answer(_ tool: String, _ arguments: [String: Any], by agent: String = "An agent") async throws -> [String: Any] {
        guard AgentLook.tools.contains(where: { $0.name == tool }) else { throw AgentFailure("No such tool: \(tool)") }
        switch tool {
        case "overview": return overview()
        case "get_backup": return AgentBackup.state(model, limit: AgentLook.limit(arguments))
        case "wait_for_backup": return await AgentBackup.wait(model, seconds: AgentLook.integer(arguments["timeout_seconds"]))
        case "set_backup_drive": return try AgentBackup.setDrive(model, arguments)
        case "select_for_backup":
            guard let reason = arguments["reason"] as? String, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentFailure("Say why, in one short line: the user sees it beside what you select.")
            }
            return AgentBackup.picked(model.selectForBackup(try list(arguments, "paths"), agent: agent, reason: reason), model: model, selecting: true)
        case "deselect_for_backup":
            return AgentBackup.picked(model.deselectForBackup(try list(arguments, "paths"), byAgent: true), model: model, selecting: false)
        case "verify_moved": return try AgentBackup.verify(model, arguments)
        case "switch_disk": return try switchDisk(arguments)
        case "wait_for_clean": return await waitForClean(arguments)
        default: break
        }
        // The real map, never a picture drawn for looking at.
        guard let tree = model.workTree else { throw AgentFailure("Headroom has no map yet. It is still starting or scanning; try again shortly.") }
        switch tool {
        case "check":
            let paths = try list(arguments, "paths", atMost: AgentLook.mostChecked)
            let planned = model.planPlaces.nodes.values.flatMap { $0 }
            let open = await Task.detached { OpenFiles.snapshot() }.value
            return ["paths": paths.map { AgentLook.check($0, in: tree, rules: model.rules, plan: model.plan, planned: planned, excluded: model.planPlaces.excluded, open: open) }]
        case "select":
            guard let reason = arguments["reason"] as? String, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentFailure("Say why, in one short line: the user sees it beside what you select.")
            }
            let picks = model.select(try list(arguments, "paths"), by: agent, reason: reason)
            let open = await Task.detached { OpenFiles.snapshot() }.value
            return selected(picks, open: open, in: tree)
        case "select_suggestions":
            let results = model.selectSuggestions(try list(arguments, "ids"), by: agent)
            return ["selected": results.filter { $0.outcome == .selected }.count,
                    "results": results.map { ["id": $0.id, "result": $0.outcome.text] },
                    "next": "Nothing is removed yet. The user reviews this in Headroom and cleans there."]
        case "deselect":
            let paths = (arguments["paths"] as? [String]) ?? [], ids = (arguments["ids"] as? [String]) ?? []
            guard !paths.isEmpty || !ids.isEmpty, paths.count + ids.count <= AgentLook.mostSelected else { throw AgentFailure("Give paths or ids, at most \(AgentLook.mostSelected) in one call.") }
            let results = model.deselect(paths: paths, ids: ids)
            return ["deselected": results.filter { $0.outcome == .deselected }.count, "results": results.map { ["path": $0.path, "result": $0.outcome.text] }]
        case "show":
            let asked = arguments["view"] as? String
            let view: Lens = asked == "map" ? .map : (asked == "backup" ? .backup : .freeUp)
            return ["shown": try model.show(arguments["path"] as? String, view: view)]
        case "list_suggestions": return try AgentLook.suggestions(model.suggestions, group: arguments["group"] as? String, in: tree)
        case "list_duplicates": return AgentLook.duplicates(model.copies, reading: model.copiesReading, arguments: arguments, in: tree)
        default:
            await model.checkForAgent()
            return AgentLook.plan(model.plan, numbers: model.planNumbers, checks: model.checks, isChecking: model.isChecking, isCleaning: model.isCleaning)
        }
    }

    private func list(_ arguments: [String: Any], _ key: String, atMost: Int = AgentLook.mostSelected) throws -> [String] {
        guard let values = arguments[key] as? [String], !values.isEmpty else { throw AgentFailure("\(key) is a list of at least one.") }
        guard values.count <= atMost else { throw AgentFailure("At most \(atMost) in one call.") }
        return values
    }

    /// What became of each path, and for what was selected, what it really frees with everything else that's selected.
    private func selected(_ picks: [AgentPick], open: OpenFiles, in tree: DiskTree) -> [String: Any] {
        let planned = model.planPlaces.nodes.values.flatMap { $0 }
        var shared = 0
        let results = picks.map { pick -> [String: Any] in
            var out: [String: Any] = ["path": pick.path, "result": pick.outcome.text]
            if let note = pick.note { out["note"] = note }
            if pick.outcome == .selected, let busy = AgentLook.inUse(pick.path, open: open) { out["in_use"] = busy }
            guard pick.outcome == .selected, let node = pick.node else { return out }
            // Working out what one thing frees reads every link on the disk, so it's done for the first of a long list.
            shared += 1
            guard shared <= 40 else { return out }
            out.merge(AgentLook.gain(of: node, with: planned, except: model.planPlaces.excluded, in: tree)) { a, _ in a }
            return out
        }
        var out: [String: Any] = [
            "selected": picks.filter { $0.outcome == .selected }.count,
            "results": results,
            "selected_in_all": model.plan.count,
            "next": "Nothing is removed yet. The user reviews this in Headroom and cleans there: call show to bring it forward, then wait_for_clean.",
        ]
        if picks.contains(where: { $0.outcome == .selected && $0.node == nil }) {
            out["reading_again"] = "Some of these are newer than Headroom's map. They are selected, and Headroom is reading the disk again so they show."
        }
        return out
    }

    private func overview() -> [String: Any] {
        let disks = model.volumes.map { volume -> [String: Any] in
            ["name": volume.name, "path": volume.mountPath, "size": volume.capacity, "size_text": formatBytes(volume.capacity),
             "free": volume.free, "free_text": formatBytes(volume.free), "shown": volume.mountPath == model.volume?.mountPath]
        }
        guard let tree = model.tree else {
            return ["disks": disks, "scan": ["state": model.isScanning ? "scanning, no map yet" : "no map yet"]]
        }
        let free = tree.totals[Int(tree.free)]
        var scan: [String: Any] = [
            "state": model.isScanning ? "scanning" : (tree.isPartial ? "partly read" : "read"),
            "files": tree.totalFiles[0],
        ]
        if !tree.isPartial { scan["finished"] = AgentLook.dates.string(from: tree.finishedAt) }
        return [
            "disk": [
                "name": tree.volumeName,
                "path": model.volume?.mountPath ?? tree.rootPath,
                "size": tree.capacityBytes,
                "size_text": formatBytes(tree.capacityBytes),
                "free": free,
                "free_text": formatBytes(free),
            ] as [String: Any],
            "disks": disks,
            "scan": scan,
            "full_disk_access": model.hasFullAccess,
            "selected_for_removal": ["items": model.plan.count, "frees": model.planNumbers.total, "frees_text": formatBytes(model.planNumbers.total)] as [String: Any],
            "being_cleaned": model.isCleaning,
        ]
    }

    private func switchDisk(_ arguments: [String: Any]) throws -> [String: Any] {
        guard let wanted = arguments["disk"] as? String else { throw AgentFailure("Name the disk, or give its path.") }
        let path = AgentLook.written(wanted)
        guard let disk = model.volumes.first(where: { $0.mountPath == path || $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else {
            throw AgentFailure("No such disk: \(wanted). Connected: " + model.volumes.map(\.name).joined(separator: ", "))
        }
        guard !model.isCleaning else { throw AgentFailure("Headroom is cleaning. Try again when it's done.") }
        guard disk.mountPath != model.volume?.mountPath else { return ["shown": "Headroom is already showing \(disk.name)."] }
        model.switchVolume(disk)
        return ["shown": "Headroom is reading \(disk.name). overview says when it is read."]
    }

    /// Waits for a clean to finish, looking a few times a second, and says what it did.
    private func waitForClean(_ arguments: [String: Any]) async -> [String: Any] {
        let seconds = min(max(AgentLook.integer(arguments["timeout_seconds"]) ?? 600, 1), AgentLook.longestWait)
        let before = model.afterClean?.things
        var sawCleaning = model.cleanProgress != nil
        let giveUp = Date().addingTimeInterval(TimeInterval(seconds))
        while Date() < giveUp {
            if model.cleanProgress != nil { sawCleaning = true }
            if model.cleanProgress == nil, !model.isPuttingBack, sawCleaning || model.afterClean?.things != before, let done = model.afterClean {
                return AgentLook.cleaned(done, free: model.tree.map { $0.totals[Int($0.free)] })
            }
            // A clean that moved nothing leaves nothing to report but that it ran.
            if sawCleaning, model.cleanProgress == nil, model.afterClean == nil {
                return ["finished": true, "moved_to_trash": 0, "note": "The clean ran and nothing went to the Trash. get_plan says what Headroom's checks held back."]
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return ["finished": false, "note": "The user hasn't cleaned yet. Call wait_for_clean again to keep waiting."]
    }
}
