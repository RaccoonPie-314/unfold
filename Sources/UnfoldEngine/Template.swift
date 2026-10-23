import Foundation

public enum TemplateError: Error, Equatable, CustomStringConvertible {
    case unclosedPlaceholder(String)
    case emptyPlaceholderName
    case invalidPlaceholderName(String)
    case duplicatePlaceholderName(String)
    case optionContainsComma(String)
    case emptyTextPart

    public var description: String {
        switch self {
        case .unclosedPlaceholder(let body):
            return "placeholder `{{\(body)` has no closing `}}`"
        case .emptyPlaceholderName:
            return "placeholder name is empty"
        case .invalidPlaceholderName(let name):
            return "placeholder name `\(name)` may not contain braces or a colon"
        case .duplicatePlaceholderName(let name):
            return "placeholder name `\(name)` is used more than once in this combo"
        case .optionContainsComma(let option):
            return "option `\(option)` contains a comma, which the plain-text form cannot round-trip"
        case .emptyTextPart:
            return "a text part may not be empty; the plain-text form drops it"
        }
    }
}

public enum Template {
    /// Refuses the parts `serialize` cannot write and read back identically, so a hand-edited or
    /// Beeftext-imported combo is reported instead of being silently rewritten on its first save.
    ///
    /// `serialize` interpolates an id and its options without escaping, so an id carrying a `:` or a
    /// brace and an option carrying a comma both come back as something else, and an empty text part
    /// vanishes entirely -- `parse` never produces one. A part that survives the plain-text form is
    /// accepted here; that is the same rule the spec states for the editor.
    public static func validate(_ parts: [Part]) throws {
        for part in parts {
            switch part {
            case .text(let value):
                if value.isEmpty { throw TemplateError.emptyTextPart }
            case .placeholder(let placeholder):
                try validateName(placeholder.id)
                for option in placeholder.options where option.contains(",") {
                    throw TemplateError.optionContainsComma(option)
                }
            }
        }
    }

    public static func parse(_ text: String) throws -> [Part] {
        let characters = Array(text)
        var parts: [Part] = []
        var literal = ""
        var seenNames = Set<String>()
        var index = 0

        func flushLiteral() {
            if !literal.isEmpty {
                parts.append(.text(literal))
                literal = ""
            }
        }

        while index < characters.count {
            // Two escape rules, and they are disjoint rather than ordered: the first needs a
            // backslash followed by a backslash, the second a backslash followed by two braces, so
            // no position can match both and swapping them changes nothing. `\\{{` reads as one
            // literal backslash plus a placeholder because the first rule takes the pair, not
            // because it is tested first.
            if characters[index] == "\\", index + 1 < characters.count, characters[index + 1] == "\\" {
                literal.append("\\")
                index += 2
                continue
            }

            if characters[index] == "\\",
               index + 2 < characters.count,
               characters[index + 1] == "{",
               characters[index + 2] == "{" {
                literal += "{{"
                index += 3
                continue
            }

            if characters[index] == "{", index + 1 < characters.count, characters[index + 1] == "{" {
                var close = index + 2
                while close < characters.count {
                    if characters[close] == "}", characters[close - 1] == "}" { break }
                    close += 1
                }
                guard close < characters.count else {
                    throw TemplateError.unclosedPlaceholder(String(characters[(index + 2)...]))
                }

                let body = String(characters[(index + 2)..<(close - 1)])
                flushLiteral()
                let placeholder = try makePlaceholder(body)
                if !seenNames.insert(placeholder.id).inserted {
                    throw TemplateError.duplicatePlaceholderName(placeholder.id)
                }
                parts.append(.placeholder(placeholder))
                index = close + 1
                continue
            }

            literal.append(characters[index])
            index += 1
        }

        flushLiteral()
        return parts
    }

    public static func serialize(_ parts: [Part]) -> String {
        var output = ""
        for part in parts {
            switch part {
            case .text(let value):
                // The mirror of parse's two escape rules, in the same order: every
                // backslash is doubled first, then `{{` is escaped, so a text part
                // ending in a backslash cannot eat the placeholder that follows it.
                output += value
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "{{", with: "\\{{")
            case .placeholder(let placeholder):
                if placeholder.options.isEmpty {
                    output += "{{\(placeholder.id)}}"
                } else {
                    output += "{{\(placeholder.id):\(placeholder.options.joined(separator: ","))}}"
                }
            }
        }
        return output
    }

    private static func makePlaceholder(_ body: String) throws -> Placeholder {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { throw TemplateError.emptyPlaceholderName }

        guard let colon = trimmed.firstIndex(of: ":") else {
            try validateName(trimmed)
            return Placeholder(id: trimmed, options: [])
        }

        let name = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { throw TemplateError.emptyPlaceholderName }
        try validateName(name)

        // An option may not contain a comma: the separator and the value share a
        // character set, so this is a documented v1 limit, not an oversight.
        let rawOptions = String(trimmed[trimmed.index(after: colon)...])
        let options = rawOptions
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Placeholder(id: name, options: options)
    }

    private static func validateName(_ name: String) throws {
        if name.contains(where: { $0 == "{" || $0 == "}" || $0 == ":" }) {
            throw TemplateError.invalidPlaceholderName(name)
        }
    }
}
