import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One thing an agent can ask the app for: its name, what it's for, and what it takes, as the JSON Schema an agent reads.
///
/// The schema's values are JSON: strings, numbers, booleans, and arrays and dictionaries of them.
public struct AgentTool: @unchecked Sendable {
    /// What agents call it by, such as `chart_summary`.
    public var name: String
    /// What it does, in a sentence or two the agent reads to decide when to call it.
    public var description: String
    /// What it takes, by name: each a JSON Schema, such as `["type": "string", "description": "A folder."]`.
    public var properties: [String: [String: Any]]
    /// The properties a call must give.
    public var required: [String]
    /// It changes what's shown or selected, so an agent allowed only to look can't call it.
    public var selects: Bool

    public init(name: String, description: String, properties: [String: [String: Any]] = [:], required: [String] = [],
                selects: Bool = false) {
        self.name = name
        self.description = description
        self.properties = properties
        self.required = required
        self.selects = selects
    }

    /// What it takes, as one JSON Schema object.
    public var schema: [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
}

/// One call an agent made: the tool, what it gave, and who it is.
public struct AgentCall: @unchecked Sendable {
    /// The tool's name. It's always one of the app's tools: a call to anything else is turned away before it gets here.
    public var tool: String
    /// What the agent gave, as JSON, by the names in the tool's `properties`. It isn't checked against the schema: an
    /// agent can send anything, so read each value as what it may be.
    public var arguments: [String: Any]
    /// Who called: the name it gave, and the program the system says it is.
    public var agent: AgentIdentity

    public init(tool: String, arguments: [String: Any] = [:], agent: AgentIdentity) {
        self.tool = tool
        self.arguments = arguments
        self.agent = agent
    }
}

/// The answer to a tool call: JSON, text or an image, or several of them.
public struct AgentReply: @unchecked Sendable {
    /// One part of an answer.
    public enum Part {
        /// A JSON object or array, sent as one line of JSON text with no layout.
        case json(Any)
        case text(String)
        /// An image file's bytes, such as a PNG, and its type, such as `image/png`.
        case image(Data, mimeType: String)
    }

    /// What the answer is made of, in order: an agent gets each as its own piece of content.
    public var parts: [Part]

    public init(_ parts: [Part]) {
        self.parts = parts
    }

    /// A JSON object or array, sent as one line of JSON text.
    public static func json(_ object: Any) -> AgentReply { AgentReply([.json(object)]) }
    /// An answer in words.
    public static func text(_ text: String) -> AgentReply { AgentReply([.text(text)]) }
    /// A PNG file's bytes.
    public static func png(_ data: Data) -> AgentReply { AgentReply([.image(data, mimeType: "image/png")]) }

    /// An image, sent as a PNG. Nil if it can't be written as one.
    public static func image(_ image: CGImage) -> AgentReply? {
        let data = NSMutableData()
        guard let file = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(file, image, nil)
        guard CGImageDestinationFinalize(file) else { return nil }
        return .png(data as Data)
    }

    /// The parts as MCP content, or nil when a JSON part can't be written as JSON.
    func content() -> [[String: Any]]? {
        var out: [[String: Any]] = []
        for part in parts {
            switch part {
            case .json(let object):
                guard let text = AgentJSON.text(object) else { return nil }
                out.append(["type": "text", "text": text])
            case .text(let text):
                out.append(["type": "text", "text": text])
            case .image(let data, let type):
                out.append(["type": "image", "data": data.base64EncodedString(), "mimeType": type])
            }
        }
        return out
    }
}

/// Why a call couldn't be answered, in words the agent can act on. Throw it from the app's answer: the agent reads the
/// message as the call's answer, marked as an error.
public struct AgentFailure: Error, Equatable, Sendable {
    /// What the agent is told, in words it can act on.
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// JSON, one message a line, as agents send and read it.
@_spi(Diagnostics) public enum AgentJSON {
    /// One line of JSON, or nil for something JSON can't hold.
    public static func line(_ object: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// What a tool's JSON answer is handed over as: the same JSON as text, with no layout. An agent pays for every space.
    public static func text(_ object: Any) -> String? {
        line(object).map { String(decoding: $0, as: UTF8.self) }
    }
}
