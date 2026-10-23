import Foundation

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case formatVersionTooNew(found: Int, supported: Int)

    public var description: String {
        switch self {
        case .unreadable(let reason):
            return "combos file could not be decoded: \(reason)"
        case .formatVersionTooNew(let found, let supported):
            return "combos file declares format \(found) but this build supports \(supported)"
        }
    }
}

public struct Store {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func defaultURL(
        appIdentifier: String = "io.github.raccoonpie314.unfold",
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent(appIdentifier)
            .appendingPathComponent("combos.json")
    }

    /// A missing file is a normal first run, not an error. A file that exists but cannot
    /// be decoded throws, and is never overwritten from here.
    public func load(fileManager: FileManager = .default) throws -> CombosFile {
        guard fileManager.fileExists(atPath: url.path) else {
            return CombosFile(formatVersion: CombosFile.currentFormatVersion, combos: [])
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.unreadable(error.localizedDescription)
        }

        let decoded: CombosFile
        do {
            decoded = try JSONDecoder().decode(CombosFile.self, from: data)
        } catch {
            throw StoreError.unreadable(String(describing: error))
        }

        guard decoded.formatVersion <= CombosFile.currentFormatVersion else {
            throw StoreError.formatVersionTooNew(
                found: decoded.formatVersion,
                supported: CombosFile.currentFormatVersion
            )
        }
        return decoded
    }

    public func save(_ file: CombosFile, fileManager: FileManager = .default) throws {
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: url, options: .atomic)
    }
}
