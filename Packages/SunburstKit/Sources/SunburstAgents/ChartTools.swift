import Foundation
import SunburstKit

/// Tools any app that shows a `SunburstChart` can give agents: look at what's on the chart, find things in its tree and
/// look inside them, a picture of it, zoom into a node and back out, and light nodes up. Add `tools` to the app's own in its `AgentHost`, and answer their calls with
/// `answer(_:chart:)`:
///
/// ```swift
/// let host = AgentHost(name: "FolderMap", version: "1.0", instructions: "…", folder: folder,
///                      tools: SunburstAgentTools.tools + myTools)
/// let door = AgentDoor.open(host) { call in
///     switch call.tool {
///     case "reveal": return try reveal(call)
///     default: return try SunburstAgentTools.answer(call, chart: chart)
///     }
/// }
/// ```
///
/// Agents name nodes by the numbers `chart_summary`, `chart_find` and `chart_children` give. A number is checked with the
/// tree's `hasNode(_:)` before the tree is asked anything about it, since asking about a node it doesn't have isn't safe.
/// The tools that move the chart or light it are `selects` tools, so an agent the user allowed only to look can't call
/// them.
public enum SunburstAgentTools {
    /// The most `chart_summary`, `chart_find` and `chart_children` list, and the most nodes `chart_highlight` takes.
    public static let most = 500
    /// The largest picture, in pixels across or down.
    public static let largestPicture = 1600

    /// The chart's tools, to add to an `AgentHost`'s.
    public static let tools: [AgentTool] = [
        AgentTool(name: "chart_summary",
                  description: "What the chart shows now: the node in the middle, and the biggest pieces on the ring, biggest first, each with its node number, name, size, share of the middle, ring (0 is the innermost), the node it is inside, and where it is in degrees clockwise from 12 o'clock. Pieces that gather what is too small to draw alone are marked. The other chart tools take these node numbers.",
                  properties: ["limit": ["type": "integer", "minimum": 1, "maximum": most, "description": "How many pieces to list. 60 unless given."]]),
        AgentTool(name: "chart_find",
                  description: "Find nodes by name anywhere in the tree, not only on the ring, without moving the chart. Biggest first, each with its node number, name, size, path (the names from the top down to it), whether anything is inside it, and whether it has a piece on the ring now. Case and accents are ignored.",
                  properties: ["name": ["type": "string", "minLength": 1, "description": "Part of the name to look for."],
                               "limit": ["type": "integer", "minimum": 1, "maximum": most, "description": "How many to list. 20 unless given."]],
                  required: ["name"]),
        AgentTool(name: "chart_children",
                  description: "What is inside a node, biggest first, without moving the chart: each one's node number, name, size, share of the node, whether anything is inside it, and whether it has a piece on the ring now. The node in the middle unless given.",
                  properties: ["node": ["type": "integer", "minimum": 0, "description": "A node number from chart_summary, chart_find or chart_children."],
                               "limit": ["type": "integer", "minimum": 1, "maximum": most, "description": "How many to list. 60 unless given."]]),
        AgentTool(name: "chart_picture",
                  description: "A picture of the chart as it is now, as a PNG: the ring, without names. chart_summary says what each piece is.",
                  properties: ["width": ["type": "integer", "minimum": 64, "maximum": largestPicture, "description": "Pixels across. 800 unless given."],
                               "height": ["type": "integer", "minimum": 64, "maximum": largestPicture, "description": "Pixels down. 800 unless given."]]),
        AgentTool(name: "chart_zoom_in",
                  description: "Zoom the chart into a node, so it fills the ring with what is inside it around it. Any node with something inside it, on the ring or not.",
                  properties: ["node": ["type": "integer", "minimum": 0, "description": "A node number from chart_summary, chart_find or chart_children."]],
                  required: ["node"], selects: true),
        AgentTool(name: "chart_zoom_out",
                  description: "Zoom the chart out one level, or all the way back to the whole tree.",
                  properties: ["to_root": ["type": "boolean", "description": "All the way out. One level unless true."]],
                  selects: true),
        AgentTool(name: "chart_highlight",
                  description: "Light nodes on the chart, and the way out to them, so the user sees them; everything else steps back. In place of what was lit before. A node too small for a piece of its own lights the piece that holds it. A node outside the one in the middle can't be lit until the chart is zoomed out to it. Zooming turns it off.",
                  properties: ["nodes": ["type": "array", "items": ["type": "integer", "minimum": 0], "minItems": 1, "maxItems": most,
                                         "description": "Node numbers from chart_summary, chart_find or chart_children."]],
                  required: ["nodes"], selects: true),
        AgentTool(name: "chart_clear_highlight",
                  description: "Turn off what chart_highlight lit.",
                  selects: true),
    ]

    /// The answer to a call to one of `tools`. A call to any other tool is an `AgentFailure`.
    @MainActor
    public static func answer<Tree: SunburstTree>(_ call: AgentCall, chart: SunburstChart<Tree>) throws -> AgentReply {
        switch call.tool {
        case "chart_summary":
            let limit = min(max(integer(call.arguments["limit"]) ?? 60, 1), most)
            return .text(try summary(chart.summary(limit: limit)))
        case "chart_find":
            guard let text = (call.arguments["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw AgentFailure("name is the text to look for.")
            }
            let limit = min(max(integer(call.arguments["limit"]) ?? 20, 1), most)
            let (found, all) = find(text, in: chart, limit: limit)
            var out: [String: Any] = ["matches": found.map { node in
                var entry = describe(node, in: chart)
                entry["path"] = path(to: node, in: chart)
                return entry
            }, "more": all - found.count]
            if all == 0 { out["note"] = "No name has \"\(text)\" in it." }
            return .json(out)
        case "chart_children":
            var node = chart.focus
            if let given = call.arguments["node"], !(given is NSNull) {
                guard let number = Self.node(given) else { throw AgentFailure("node is a node number.") }
                node = number
            }
            guard knows(node, chart) else { throw unknown([node]) }
            let limit = min(max(integer(call.arguments["limit"]) ?? 60, 1), most)
            let tree = chart.tree
            var listed: [UInt32] = [], all = 0
            var child = tree.firstChild(of: node)
            while child != 0 {
                if listed.count < limit { listed.append(child) }
                all += 1
                child = tree.nextSibling(of: child)
            }
            let whole = Double(max(tree.size(of: node), 1))
            var out = describe(node, in: chart)
            out["children"] = listed.map { child in
                var entry = describe(child, in: chart)
                entry["share"] = (Double(tree.size(of: child)) / whole * 10_000).rounded() / 10_000
                return entry
            }
            out["more"] = all - listed.count
            return .json(out)
        case "chart_picture":
            func side(_ key: String) -> Int { min(max(integer(call.arguments[key]) ?? 800, 64), largestPicture) }
            // Without the dither the PNG is about half the size, and an agent has no use for it.
            guard let image = chart.picture(width: side("width"), height: side("height"), dithered: false) else {
                throw AgentFailure("There's no picture: this Mac has no GPU to draw one with.")
            }
            guard let reply = AgentReply.image(image) else { throw AgentFailure("The picture couldn't be written as a PNG.") }
            return reply
        case "chart_zoom_in":
            guard let node = node(call.arguments["node"]) else { throw AgentFailure("node is a node number.") }
            guard knows(node, chart) else { throw unknown([node]) }
            guard chart.tree.firstChild(of: node) != 0 else { throw AgentFailure("\(chart.name(node)) has nothing inside it to zoom into.") }
            let before = chart.focus
            chart.zoom(into: node)
            var out = middle(of: chart)
            if chart.focus == before { out["note"] = "Already in the middle." }
            return .json(out)
        case "chart_zoom_out":
            let before = chart.focus
            if call.arguments["to_root"] as? Bool == true { chart.zoomToRoot() } else { chart.zoomOut() }
            var out = middle(of: chart)
            if before == 0 { out["note"] = "Already showing the whole tree." }
            return .json(out)
        case "chart_highlight":
            guard let list = call.arguments["nodes"] as? [Any], !list.isEmpty, list.count <= most else {
                throw AgentFailure("nodes is a list of 1 to \(most) node numbers.")
            }
            var lit: [UInt32] = [], away: [UInt32] = [], unknown: [UInt32] = []
            for value in list {
                guard let node = node(value) else { throw AgentFailure("nodes is a list of node numbers.") }
                if chart.engine.layout.piece(of: node) != nil {
                    lit.append(node)
                } else if !knows(node, chart) {
                    unknown.append(node)
                } else if isInside(node, chart.focus, chart.tree) {
                    lit.append(node)
                } else {
                    away.append(node)
                }
            }
            guard !lit.isEmpty else {
                if away.isEmpty { throw Self.unknown(unknown) }
                throw AgentFailure("Not in view now: \(Self.list(away)). They're outside \(chart.name(chart.focus)); zoom out to light them.")
            }
            chart.highlight(lit)
            var out: [String: Any] = ["lit": lit.count]
            if !away.isEmpty { out["not_in_view"] = away }
            if !unknown.isEmpty { out["unknown"] = unknown }
            return .json(out)
        case "chart_clear_highlight":
            chart.clearHighlight()
            return .json(["lit": 0])
        default:
            throw AgentFailure("No such tool: \(call.tool)")
        }
    }

    // MARK: Reading what an agent gave

    /// A whole number, however the agent's JSON wrote it.
    static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, number.doubleValue == number.doubleValue.rounded(.towardZero) {
            return Int(exactly: number.doubleValue)
        }
        if let text = value as? String { return Int(text) }
        return nil
    }

    static func node(_ value: Any?) -> UInt32? {
        integer(value).flatMap { UInt32(exactly: $0) }
    }

    private static func list(_ nodes: [UInt32]) -> String {
        nodes.prefix(10).map(String.init).joined(separator: ", ") + (nodes.count > 10 ? " and \(nodes.count - 10) more" : "")
    }

    private static func unknown(_ nodes: [UInt32]) -> AgentFailure {
        AgentFailure("The tree has no node \(list(nodes)). chart_summary, chart_find and chart_children give node numbers.")
    }

    /// Whether the chart's tree has the node: the focus or a node with a piece is known at once, and the tree is asked about
    /// the rest.
    @MainActor
    private static func knows<Tree: SunburstTree>(_ node: UInt32, _ chart: SunburstChart<Tree>) -> Bool {
        node == chart.focus || chart.engine.layout.piece(of: node) != nil || chart.tree.hasNode(node)
    }

    /// Whether a node the tree has is inside `folder`, or is it.
    private static func isInside<Tree: SunburstTree>(_ node: UInt32, _ folder: UInt32, _ tree: Tree) -> Bool {
        var at = node
        while at != 0 {
            if at == folder { return true }
            at = tree.parent(of: at)
        }
        return folder == 0
    }

    // MARK: Answers

    @MainActor
    private static func middle<Tree: SunburstTree>(of chart: SunburstChart<Tree>) -> [String: Any] {
        ["focus": chart.focus, "name": chart.name(chart.focus), "size": chart.tree.size(of: chart.focus), "size_text": text(of: chart.focus, in: chart)]
    }

    /// What the chart writes for a node: its value text, or its size.
    @MainActor
    private static func text<Tree: SunburstTree>(of node: UInt32, in chart: SunburstChart<Tree>) -> String {
        chart.valueText?(node) ?? chart.sizeText(chart.tree.size(of: node))
    }

    /// A node the tree has, as `chart_find` and `chart_children` list it.
    @MainActor
    private static func describe<Tree: SunburstTree>(_ node: UInt32, in chart: SunburstChart<Tree>) -> [String: Any] {
        ["node": node, "name": chart.name(node), "size": chart.tree.size(of: node), "size_text": text(of: node, in: chart),
         "has_inside": chart.tree.firstChild(of: node) != 0, "on_the_ring": chart.engine.layout.piece(of: node) != nil]
    }

    /// The names from the top of the tree down to a node, its own last.
    @MainActor
    private static func path<Tree: SunburstTree>(to node: UInt32, in chart: SunburstChart<Tree>) -> [String] {
        var names: [String] = []
        var at = node
        while true {
            names.append(chart.name(at))
            if at == 0 { break }
            at = chart.tree.parent(of: at)
        }
        return names.reversed()
    }

    /// The biggest nodes whose names have `text` in them, ignoring case and accents, biggest first and at most `limit`, and how
    /// many there are in all. The whole tree is searched, from the root down, so only nodes it has are asked about.
    @MainActor
    static func find<Tree: SunburstTree>(_ text: String, in chart: SunburstChart<Tree>, limit: Int) -> (nodes: [UInt32], all: Int) {
        let tree = chart.tree
        let wanted = NamePart(text)
        var best: [(node: UInt32, size: UInt64)] = []
        var all = 0
        var stack: [UInt32] = [0]
        while let node = stack.popLast() {
            if wanted.isIn(chart.name(node)) {
                all += 1
                let size = tree.size(of: node)
                if best.count < limit || size > best[best.count - 1].size {
                    // After everything as big, so what was found first stays first.
                    var low = 0, high = best.count
                    while low < high {
                        let mid = (low + high) / 2
                        if best[mid].size >= size { low = mid + 1 } else { high = mid }
                    }
                    best.insert((node, size), at: low)
                    if best.count > limit { best.removeLast() }
                }
            }
            var child = tree.firstChild(of: node)
            while child != 0 {
                stack.append(child)
                child = tree.nextSibling(of: child)
            }
        }
        return (best.map(\.node), all)
    }

    /// The summary as one line of JSON, with names as agents write them and no more digits than help.
    static func summary(_ summary: SunburstSummary) throws -> String {
        var short = summary
        for at in short.pieces.indices {
            short.pieces[at].share = (short.pieces[at].share * 10_000).rounded() / 10_000
            short.pieces[at].from = (short.pieces[at].from * 10).rounded() / 10
            short.pieces[at].to = (short.pieces[at].to * 10).rounded() / 10
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(short) else { throw AgentFailure("The summary couldn't be written as JSON.") }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Part of a name to look for, ignoring case and accents. Most names are plain ASCII, and those are compared byte by byte,
/// which over a whole disk's tree is many times faster than comparing as text.
struct NamePart {
    let text: String
    /// The text in lower case, if it's all ASCII.
    private let ascii: [UInt8]?

    init(_ text: String) {
        self.text = text
        let bytes = Array(text.utf8)
        ascii = bytes.allSatisfy { $0 < 0x80 } ? bytes.map(Self.lower) : nil
    }

    func isIn(_ name: String) -> Bool {
        if let ascii {
            var name = name
            let quick = name.withUTF8 { bytes -> Bool? in
                // A name with accents may still match a plain part ("Café" has "cafe"), so it's compared as text.
                guard !bytes.contains(where: { $0 >= 0x80 }) else { return nil }
                guard bytes.count >= ascii.count else { return false }
                if ascii.isEmpty { return true }
                for start in 0...(bytes.count - ascii.count) where Self.lower(bytes[start]) == ascii[0] {
                    var at = 1
                    while at < ascii.count, Self.lower(bytes[start + at]) == ascii[at] { at += 1 }
                    if at == ascii.count { return true }
                }
                return false
            }
            if let quick { return quick }
        }
        return name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    @inline(__always)
    private static func lower(_ byte: UInt8) -> UInt8 { byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte }
}
