import Foundation
import SunburstKit

/// Tools any app that shows a `SunburstChart` can give agents: look at what's on the chart, a picture of it, zoom into a
/// node and back out, and light nodes up. Add `tools` to the app's own in its `AgentHost`, and answer their calls with
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
/// Agents name nodes by the numbers `chart_summary` gives. Only nodes with a piece on the ring now are taken: the package
/// can't tell a node number the tree doesn't have from one it does, and asking the tree about one it doesn't have isn't
/// safe. The tools that move the chart or light it are `selects` tools, so an agent the user allowed only to look can't
/// call them.
public enum SunburstAgentTools {
    /// The most pieces `chart_summary` lists, and the most nodes `chart_highlight` takes.
    public static let most = 500
    /// The largest picture, in pixels across or down.
    public static let largestPicture = 1600

    /// The chart's tools, to add to an `AgentHost`'s.
    public static let tools: [AgentTool] = [
        AgentTool(name: "chart_summary",
                  description: "What the chart shows now: the node in the middle, and the biggest pieces on the ring, biggest first, each with its node number, name, size, share of the middle, ring (0 is the innermost), the node it is inside, and where it is in degrees clockwise from 12 o'clock. Pieces that gather what is too small to draw alone are marked. The other chart tools take these node numbers.",
                  properties: ["limit": ["type": "integer", "minimum": 1, "maximum": most, "description": "How many pieces to list. 60 unless given."]]),
        AgentTool(name: "chart_picture",
                  description: "A picture of the chart as it is now, as a PNG: the ring, without names. chart_summary says what each piece is.",
                  properties: ["width": ["type": "integer", "minimum": 64, "maximum": largestPicture, "description": "Pixels across. 800 unless given."],
                               "height": ["type": "integer", "minimum": 64, "maximum": largestPicture, "description": "Pixels down. 800 unless given."]]),
        AgentTool(name: "chart_zoom_in",
                  description: "Zoom the chart into a node, so it fills the ring with what is inside it around it. The node must be on the ring now and have something inside it.",
                  properties: ["node": ["type": "integer", "minimum": 0, "description": "A node number from chart_summary."]],
                  required: ["node"], selects: true),
        AgentTool(name: "chart_zoom_out",
                  description: "Zoom the chart out one level, or all the way back to the whole tree.",
                  properties: ["to_root": ["type": "boolean", "description": "All the way out. One level unless true."]],
                  selects: true),
        AgentTool(name: "chart_highlight",
                  description: "Light nodes on the chart, and the way out to them, so the user sees them; everything else steps back. In place of what was lit before. Each node must be on the ring now. Zooming turns it off.",
                  properties: ["nodes": ["type": "array", "items": ["type": "integer", "minimum": 0], "minItems": 1, "maxItems": most,
                                         "description": "Node numbers from chart_summary."]],
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
        case "chart_picture":
            func side(_ key: String) -> Int { min(max(integer(call.arguments[key]) ?? 800, 64), largestPicture) }
            // Without the dither the PNG is about half the size, and an agent has no use for it.
            guard let image = chart.picture(width: side("width"), height: side("height"), dithered: false) else {
                throw AgentFailure("There's no picture: this Mac has no GPU to draw one with.")
            }
            guard let reply = AgentReply.image(image) else { throw AgentFailure("The picture couldn't be written as a PNG.") }
            return reply
        case "chart_zoom_in":
            guard let node = node(call.arguments["node"]) else { throw AgentFailure("node is a node number from chart_summary.") }
            guard node == chart.focus || chart.engine.layout.piece(of: node) != nil else { throw notOnTheRing([node]) }
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
                throw AgentFailure("nodes is a list of 1 to \(most) node numbers from chart_summary.")
            }
            let layout = chart.engine.layout
            var lit: [UInt32] = [], missing: [UInt32] = []
            for value in list {
                guard let node = node(value) else { throw AgentFailure("nodes is a list of node numbers from chart_summary.") }
                if layout.piece(of: node) != nil { lit.append(node) } else { missing.append(node) }
            }
            guard !lit.isEmpty else { throw notOnTheRing(missing) }
            chart.highlight(lit)
            var out: [String: Any] = ["lit": lit.count]
            if !missing.isEmpty { out["not_on_the_ring"] = missing }
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

    private static func notOnTheRing(_ nodes: [UInt32]) -> AgentFailure {
        let list = nodes.prefix(10).map(String.init).joined(separator: ", ")
        return AgentFailure("Not on the ring now: \(list). chart_summary lists what is; zoom out to reach what's outside the middle.")
    }

    // MARK: Answers

    @MainActor
    private static func middle<Tree: SunburstTree>(of chart: SunburstChart<Tree>) -> [String: Any] {
        let size = chart.tree.size(of: chart.focus)
        return ["focus": chart.focus, "name": chart.name(chart.focus), "size": size, "size_text": chart.sizeText(size)]
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
