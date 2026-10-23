import Foundation

public enum InsertionMode: String, Codable, Sendable {
    case paste
    case keys
}

public struct Placeholder: Codable, Equatable, Sendable {
    public var id: String
    public var options: [String]

    public init(id: String, options: [String]) {
        self.id = id
        self.options = options
    }
}

public enum Part: Equatable, Sendable {
    case text(String)
    case placeholder(Placeholder)
}

// Hand-written so the on-disk shape is the flat form the spec documents --
// `{"text": "I love "}` and `{"placeholder": {"id": "city", "options": [...]}}` --
// which keeps combos.json hand-editable and Beeftext-importable. Declaring the
// conformance here (and not on the enum) prevents `Codable` synthesis, whose
// nested `{"text": {"_0": ...}}` wrapper would otherwise take over.
extension Part: Codable {
    private enum CodingKeys: String, CodingKey {
        case text
        case placeholder
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(value, forKey: .text)
        case .placeholder(let value):
            try container.encode(value, forKey: .placeholder)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // If a hand-edited object carries both keys, `text` wins -- deterministic, and
        // placeholder is only read when text is absent.
        if container.contains(.text) {
            self = .text(try container.decode(String.self, forKey: .text))
        } else if container.contains(.placeholder) {
            self = .placeholder(try container.decode(Placeholder.self, forKey: .placeholder))
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Part must be a JSON object with exactly one key: \"text\" or \"placeholder\""
                )
            )
        }
    }
}

public struct Combo: Codable, Equatable, Sendable {
    public var id: UUID
    public var trigger: String
    public var label: String
    public var enabled: Bool
    public var parts: [Part]
    public var insertion: InsertionMode

    public init(
        id: UUID,
        trigger: String,
        label: String,
        enabled: Bool,
        parts: [Part],
        insertion: InsertionMode
    ) {
        self.id = id
        self.trigger = trigger
        self.label = label
        self.enabled = enabled
        self.parts = parts
        self.insertion = insertion
    }
}

public struct CombosFile: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var combos: [Combo]

    public init(formatVersion: Int, combos: [Combo]) {
        self.formatVersion = formatVersion
        self.combos = combos
    }
}
