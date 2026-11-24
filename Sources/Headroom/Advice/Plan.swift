import Foundation

/// What happens to something when you press Clean.
enum PlanStep: Codable, Equatable {
    case trash
    /// An app and the files that belong to it. Everything goes to the Trash, so it can come back.
    case uninstall
    /// Copied into this folder and checked. Only then does the original go to the Trash.
    case move(folder: String)
    /// Already in the Trash. It goes when you empty it.
    case emptyTrash
}

/// One line in the list of planned actions. It's kept by path, so it survives a new scan and a restart.
struct PlanItem: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    /// What was known when you planned it.
    var note: String
    var tierRaw: UInt8
    /// Always as you'd write them: `/Users/…`, never `/System/Volumes/Data/Users/…`.
    var paths: [String]
    /// Things inside those paths that you took back.
    var excluded: [String] = []
    var step: PlanStep = .trash
    var addedAt = Date()
    var byHand = false
    var bundleID: String? = nil
    var lastKnownBytes: UInt64 = 0
    /// You saw that it changed after it was planned, and still want it gone.
    var acceptedChange: Date? = nil
    /// When you saw that something was using it, and still wanted it gone. That holds for a short while: by the next time, it
    /// may be something else using it, and you'd want to know.
    var acceptedInUseAt: Date? = nil
    static let acceptingInUseLasts: TimeInterval = 10 * 60
    var acceptsInUse: Bool { acceptedInUseAt.map { Date().timeIntervalSince($0) < Self.acceptingInUseLasts } ?? false }
    /// Which disk this was on, so that a different disk with the same name can't be mistaken for it.
    var diskID: String? = nil
    /// The agent that selected it, when one did. What you select yourself has none.
    var agent: String? = nil

    var tier: Tier { Tier(rawValue: tierRaw) ?? .yourCall }
    var isEmptyTrash: Bool { step == .emptyTrash }
    var isMove: Bool { if case .move = step { return true } else { return false } }
}

/// How a planned thing's id is made, in one place. The ids are in the plan that's saved between launches, so what they
/// look like never changes: only who gets to spell them out.
extension PlanItem {
    /// Emptying the Trash.
    static let trashID = "trash"
    /// Something ticked on the ring or in a list of files, not through a suggestion.
    static func id(pickedByHand path: String) -> String { "path:" + path }
    /// Something sent straight to the Trash from a menu.
    static func id(sent path: String) -> String { "sent:" + path }
    /// The other copy of a suggestion's files, planned with it.
    static func otherCopyID(of id: String) -> String { id + ":other-copy" }
    /// A suggestion's data, such as an app's, planned with it.
    static func dataID(of id: String) -> String { id + ":also" }

    var isPickedByHand: Bool { id.hasPrefix("path:") }
    var isOtherCopy: Bool { id.hasSuffix(":other-copy") }
}

/// Paths compare as text, and a folder covers what's inside it.
enum PathMath {
    @inline(__always) static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }

    /// Where the startup disk really keeps everything that isn't macOS itself. The map knows its folders by their place
    /// here. Everything else (the plan, other apps, what's shown) writes them without it.
    static let dataVolume = "/System/Volumes/Data"

    /// The path as you'd write it, without the data volume's prefix that macOS keeps out of sight.
    static func visible(_ path: String) -> String {
        path.hasPrefix(dataVolume + "/") ? String(path.dropFirst(dataVolume.count)) : path
    }

    /// The path as the system spells it, every link followed: /tmp/x is /private/tmp/x. As it is when it isn't there.
    static func canonical(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return path }
        defer { free(real) }
        return String(cString: real)
    }

    /// The top of the disk a path is on.
    static func mount(of path: String) -> String {
        guard path.hasPrefix("/Volumes/") else { return "/" }
        let parts = path.split(separator: "/", maxSplits: 2)
        return parts.count >= 2 ? "/\(parts[0])/\(parts[1])" : "/"
    }
}

/// The planned actions. Nothing here touches a disk. This is only the list, and the rules for keeping it tidy:
/// a folder takes in whatever was already planned inside it, taking something back from a planned folder leaves the rest
/// of that folder planned, and something with a destination of its own always keeps it.
struct PlanList: Codable, Equatable {
    var items: [PlanItem] = [] { didSet { places = Places() } }
    /// Suggestions you've said to keep. They stay out of the list until you say otherwise.
    var kept: [KeptThing] = []

    /// Where each item is in `items`, by its id: every row on screen asks, on every redraw. Worked out the first time it's
    /// asked for after the list changes. A changed list gets a new one, so copies of the list never share a wrong one.
    private final class Places: @unchecked Sendable {
        private let lock = NSLock()
        private var byID: [String: Int]?

        func place(of id: String, in items: [PlanItem]) -> Int? {
            lock.lock()
            defer { lock.unlock() }
            if byID == nil {
                var made = [String: Int](minimumCapacity: items.count)
                for (at, item) in items.enumerated() where made[item.id] == nil { made[item.id] = at }
                byID = made
            }
            return byID?[id]
        }
    }

    private var places = Places()

    private enum CodingKeys: String, CodingKey { case items, kept }

    static func == (a: PlanList, b: PlanList) -> Bool { a.items == b.items && a.kept == b.kept }

    struct KeptThing: Codable, Equatable, Identifiable {
        var id: String
        var title: String
    }

    var isEmpty: Bool { items.isEmpty }
    /// How many things will happen, counted the way you'd count them.
    var count: Int { items.count }

    func isKept(_ id: String) -> Bool { kept.contains { $0.id == id } }

    /// Whether this path will go when you clean: it's planned, or it's inside something planned, and wasn't taken back.
    func covers(_ path: String) -> Bool {
        for item in items where item.paths.contains(where: { PathMath.isInside(path, $0) }) {
            if !item.excluded.contains(where: { PathMath.isInside(path, $0) }) { return true }
        }
        return false
    }

    /// Adds to the plan.
    mutating func add(_ new: PlanItem) {
        var paths: [String] = []
        var excluded = new.excluded
        for path in new.paths {
            // Asking for this again brings back what had been taken back, unless the new item says otherwise.
            for at in items.indices {
                items[at].excluded.removeAll { PathMath.isInside($0, path) && !new.excluded.contains($0) }
            }
            if new.step != .trash {
                // It goes somewhere of its own, so it has to leave whatever else had it.
                for at in items.indices
                where items[at].id != new.id && items[at].paths.contains(where: { PathMath.isInside(path, $0) || PathMath.isInside($0, path) }) {
                    items[at].paths.removeAll { PathMath.isInside($0, path) }
                    if items[at].paths.contains(where: { PathMath.isInside(path, $0) }), !items[at].excluded.contains(path) {
                        items[at].excluded.append(path)
                    }
                }
                paths.append(path)
                continue
            }
            if items.contains(where: { item in
                item.paths.contains { PathMath.isInside(path, $0) } && !item.excluded.contains { PathMath.isInside(path, $0) }
            }) {
                continue
            }
            paths.append(path)
            for at in items.indices where items[at].id != new.id {
                let inside = items[at].paths.filter { $0 != path && PathMath.isInside($0, path) }
                guard !inside.isEmpty else { continue }
                if items[at].step == .trash {
                    // Plain things planned inside it are part of it now.
                    items[at].paths.removeAll { inside.contains($0) }
                } else {
                    // Something with a destination of its own isn't swallowed by the folder around it.
                    excluded += inside
                }
            }
        }
        items.removeAll { $0.paths.isEmpty }
        guard !paths.isEmpty else { return }
        if let at = items.firstIndex(where: { $0.id == new.id }) {
            items[at].paths += paths.filter { !items[at].paths.contains($0) }
            items[at].excluded += excluded.filter { !items[at].excluded.contains($0) }
        } else {
            var item = new
            item.paths = paths
            item.excluded = excluded
            items.append(item)
        }
    }

    /// Takes one path out of the plan. If a planned folder holds it, the rest of the folder stays planned.
    mutating func takeBack(_ path: String) {
        for at in items.indices {
            items[at].paths.removeAll { PathMath.isInside($0, path) }
            if items[at].paths.contains(where: { PathMath.isInside(path, $0) }),
                !items[at].excluded.contains(where: { PathMath.isInside(path, $0) })
            {
                items[at].excluded.append(path)
            }
        }
        items.removeAll { $0.paths.isEmpty }
    }

    /// Something taken back from a planned folder comes back with it. False when it wasn't taken back from any.
    /// Whether something was taken back from a planned folder at this path. Only reads, so asking changes nothing.
    func excludes(_ path: String) -> Bool { items.contains { $0.excluded.contains(path) } }

    /// Puts back what was taken back at this path. Ask `excludes` first: this always counts as a change to the plan.
    mutating func restoreExcluded(_ path: String) {
        for at in items.indices { items[at].excluded.removeAll { $0 == path } }
    }

    /// Takes a thing out, and what only makes sense with it: its data, or the other copy of its files.
    mutating func remove(_ id: String) {
        items.removeAll { $0.id == id || $0.id == PlanItem.dataID(of: id) || $0.id == PlanItem.otherCopyID(of: id) }
    }

    /// Takes it out of the plan and stops suggesting it.
    mutating func keep(_ id: String, title: String) {
        remove(id)
        if !isKept(id) { kept.append(KeptThing(id: id, title: title)) }
    }

    mutating func stopKeeping(_ id: String) {
        kept.removeAll { $0.id == id }
    }

    func item(_ id: String) -> PlanItem? { places.place(of: id, in: items).map { items[$0] } }

    /// Every path that goes, for an item with some things taken back: the folder is opened up, so what stays, stays.
    static func effectivePaths(of item: PlanItem, list: (String) -> [String]) -> [String] {
        var out: [String] = []
        func walk(_ path: String) {
            if item.excluded.contains(where: { PathMath.isInside(path, $0) }) { return }
            guard item.excluded.contains(where: { PathMath.isInside($0, path) }) else {
                out.append(path)
                return
            }
            for child in list(path) { walk(path + "/" + child) }
        }
        for path in item.paths { walk(path) }
        return out
    }

    /// Where something ends up in a move. A folder that's been opened up keeps its shape, with its own name on top.
    static func moveDestination(of path: String, item: PlanItem, folder: String) -> String {
        guard let root = item.paths.first(where: { PathMath.isInside(path, $0) }), root != path else { return folder }
        let name = (root as NSString).lastPathComponent
        let inner = (String(path.dropFirst(root.count + 1)) as NSString).deletingLastPathComponent
        return folder + "/" + name + (inner.isEmpty ? "" : "/" + inner)
    }
}

/// Where everything planned is on one map. The plan keeps paths, and the map numbers its folders, so this is worked out
/// from the two together and thrown away whole when the map is another one: nothing in it can be left over from a map
/// that numbered things differently.
struct PlanPlaces {
    /// The nodes of each planned item, by its id.
    private(set) var nodes: [String: [UInt32]] = [:]
    /// What was taken back out of planned folders.
    private(set) var excluded: [UInt32] = []
    /// Planned files too small to be on the map, by item: a screenshot, say. They count, and show as ticked, by their paths.
    private(set) var loose: [String: [String]] = [:]
    /// Everything planned, and everything taken back, to ask "is this inside one of them?".
    private(set) var set: NodeSet?
    private(set) var back: NodeSet?
    /// Paths already looked up, and the ones that aren't on the map: every tick looks the whole plan up again.
    private var nodeOfPath: [String: UInt32] = [:]
    private var notOnMap: Set<String> = []

    /// The node at a path as the plan writes it.
    mutating func node(at path: String, in tree: DiskTree) -> UInt32? {
        if let known = nodeOfPath[path] { return known }
        if notOnMap.contains(path) { return nil }
        guard let found = tree.find(visible: path) else {
            notOnMap.insert(path)
            return nil
        }
        nodeOfPath[path] = found
        return found
    }

    /// A node whose path is already known, so it needn't be looked up.
    mutating func remember(_ node: UInt32, at path: String) {
        nodeOfPath[path] = node
        notOnMap.remove(path)
    }

    mutating func resolve(_ items: [PlanItem], in tree: DiskTree) {
        nodes = [:]
        loose = [:]
        excluded = []
        var all: [UInt32] = []
        for item in items {
            var found: [UInt32] = []
            var small: [String] = []
            for path in item.paths {
                if let node = node(at: path, in: tree) {
                    found.append(node)
                } else if !item.excluded.contains(path), node(at: (path as NSString).deletingLastPathComponent, in: tree) != nil {
                    // A file in a folder that's on this map, though the file itself is too small to be.
                    small.append(path)
                }
            }
            nodes[item.id] = found
            all += found
            excluded += item.excluded.compactMap { node(at: $0, in: tree) }
            if !small.isEmpty { loose[item.id] = small }
        }
        set = all.isEmpty ? nil : NodeSet(all, in: tree)
        back = excluded.isEmpty ? nil : NodeSet(excluded, in: tree)
    }
}

/// Something that went to the Trash, and where it is now, so it can come back or be deleted for good.
struct CleanedThing: Codable, Equatable {
    var itemID: String
    var title: String
    var original: String
    var inTrash: String
    var bytes: UInt64
    /// Which file this is, so something else that later has the same name in the Trash can't be mistaken for it.
    var identity: String? = nil
    /// A copy replaced by a hard link to this path, the copy that stayed. Putting it back takes that link away first.
    var linkedTo: String? = nil
    /// The note left where a file moved to a drive was. Putting the file back takes the note away: the drive keeps its copy.
    var note: String? = nil
}

/// What's kept on disk between launches.
struct PlanFile: Codable {
    var list = PlanList()
    var cleaned: [CleanedThing] = []
    /// What you'd planned, so a clean you've undone can be fixed and run again.
    var lastItems: [PlanItem] = []
    /// What was already in the Trash when you said that can go too. Anything thrown away after that stays.
    var oldTrashItems: [String]? = nil
    var oldTrashBytes: UInt64 = 0
}

/// Everything the app writes down for next time goes through here: one at a time and in order, so an older version of a
/// file can never land on top of a newer one.
enum Saves {
    static let queue = DispatchQueue(label: "saves", qos: .utility)

    static func write<T: Encodable & Sendable>(_ value: T, to file: URL) {
        queue.async {
            if let data = try? JSONEncoder().encode(value) { try? data.write(to: file, options: .atomic) }
        }
    }
}

enum PlanStore {
    private static var url: URL { AppData.folder.appendingPathComponent("plan.json") }

    static func load() -> PlanFile {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(PlanFile.self, from: data) else { return PlanFile() }
        return file
    }

    static func save(_ file: PlanFile) {
        // Encoded here, as it is now: the list goes on changing.
        guard let data = try? JSONEncoder().encode(file) else { return }
        let target = url
        Saves.queue.async { try? data.write(to: target, options: .atomic) }
    }
}

/// How much of a suggestion is in the plan.
enum TickState: Equatable {
    case none, some, all
}
