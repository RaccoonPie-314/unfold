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

public enum Part: Codable, Equatable, Sendable {
    case text(String)
    case placeholder(Placeholder)
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
