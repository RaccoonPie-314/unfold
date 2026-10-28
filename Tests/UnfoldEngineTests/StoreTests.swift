import XCTest
@testable import UnfoldEngine

final class StoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unfold-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(in subpath: String? = nil) -> Store {
        let url = subpath.map { directory.appendingPathComponent($0) } ?? directory.appendingPathComponent("combos.json")
        return Store(url: url)
    }

    func testMissingFileLoadsAsAnEmptyLibrary() throws {
        let loaded = try store().load()
        XCTAssertEqual(loaded, CombosFile(formatVersion: CombosFile.currentFormatVersion, combos: []))
    }

    func testSaveThenLoadRoundTrips() throws {
        let file = CombosFile(
            formatVersion: CombosFile.currentFormatVersion,
            combos: [
                Combo(
                    id: UUID(uuidString: "6C9C0A1E-2D2B-4E37-9A6B-5C1F0D8E3A11")!,
                    trigger: "addr",
                    label: "Home address",
                    enabled: true,
                    parts: [
                        .text("I love "),
                        .placeholder(.init(id: "city", options: ["Shanghai", "Tokyo"])),
                        .text(" restaurant"),
                    ],
                    insertion: .paste
                )
            ]
        )

        try store().save(file)
        XCTAssertEqual(try store().load(), file)
    }

    func testSavedFileIsPrettyPrintedSoUsersCanDiffIt() throws {
        try store().save(CombosFile(formatVersion: 1, combos: [makeCombo("add")]))
        let text = try String(contentsOf: directory.appendingPathComponent("combos.json"), encoding: .utf8)

        XCTAssertTrue(text.contains("\n"), "a single-line file is not diffable")
        XCTAssertTrue(text.contains("\"trigger\""))
    }

    func testSaveCreatesTheApplicationSupportSubdirectory() throws {
        let nested = store(in: "Unfold/combos.json")
        try nested.save(CombosFile(formatVersion: 1, combos: []))

        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.url.path))
    }

    func testCorruptFileThrowsWithoutDeletingIt() throws {
        let url = directory.appendingPathComponent("combos.json")
        try Data("this is not json".utf8).write(to: url)

        XCTAssertThrowsError(try store().load()) { error in
            guard case StoreError.unreadable = error else {
                return XCTFail("expected unreadable, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the user's file must survive a failed load")
    }

    func testFutureFormatVersionIsRefused() throws {
        try store().save(CombosFile(formatVersion: 99, combos: []))

        XCTAssertThrowsError(try store().load()) { error in
            XCTAssertEqual(
                error as? StoreError,
                .formatVersionTooNew(found: 99, supported: CombosFile.currentFormatVersion)
            )
        }
    }

    // A version below 1 is not an old file this build can read; it is a hand-edit that got as far
    // as a number the writer never assigned. Only the upper bound was checked, so `0` and `-5` used
    // to load as a normal library.
    func testFormatVersionBelowOneIsRefused() throws {
        for version in [0, -5] {
            let url = directory.appendingPathComponent("combos-version-\(version).json")
            try Data(#"{"formatVersion":\#(version),"combos":[]}"#.utf8).write(to: url)

            XCTAssertThrowsError(try Store(url: url).load(), "version \(version)") { error in
                XCTAssertEqual(
                    error as? StoreError,
                    .unsupportedFormatVersion(found: version, supported: CombosFile.currentFormatVersion)
                )
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the user's file must survive")
        }
    }

    func testVersionOneStillLoads() throws {
        let url = directory.appendingPathComponent("combos-version-1.json")
        try Data(#"{"formatVersion":1,"combos":[]}"#.utf8).write(to: url)
        XCTAssertEqual(try Store(url: url).load(), CombosFile(formatVersion: 1, combos: []))
    }

    // The spec's Storage section promises a file a person can edit and import from Beeftext. Those
    // snippets can hold parts `serialize` cannot write back unchanged, so a save has to refuse them
    // loudly instead of rewriting the user's combo on its first round trip.
    func testSaveRefusesPartsThePlainTextFormWouldSilentlyRewrite() throws {
        let lossy = Combo(
            id: UUID(uuidString: "6C9C0A1E-2D2B-4E37-9A6B-5C1F0D8E3A11")!,
            trigger: "addr",
            label: "Hand-edited",
            enabled: true,
            parts: [.placeholder(.init(id: "city", options: ["Shanghai,Tokyo"]))],
            insertion: .paste
        )

        XCTAssertThrowsError(try store().save(CombosFile(formatVersion: 1, combos: [lossy]))) { error in
            XCTAssertEqual(error as? TemplateError, .optionContainsComma("Shanghai,Tokyo"))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("combos.json").path),
            "a refused save must not leave a rewritten library behind"
        )
    }

    // The + button hands the library a combo with no replacement yet, and `[]` is the only way to say
    // that: `.text("")` is refused by `testSaveRefusesPartsThePlainTextFormWouldSilentlyRewrite`'s
    // rule, and a refused save there stops the whole file from writing -- including later deletions.
    func testSaveAcceptsAComboWithNoReplacementYet() throws {
        let fresh = Combo(
            id: UUID(uuidString: "6C9C0A1E-2D2B-4E37-9A6B-5C1F0D8E3A11")!,
            trigger: "new",
            label: "",
            enabled: true,
            parts: [],
            insertion: .paste
        )

        try store().save(CombosFile(formatVersion: 1, combos: [fresh]))

        let loaded = try store().load()
        XCTAssertEqual(loaded.combos, [fresh])
        XCTAssertEqual(Template.serialize(loaded.combos[0].parts), "")
    }

    func testDefaultURLPointsAtTheDocumentedPath() {
        let url = Store.defaultURL()
        XCTAssertTrue(url.path.hasSuffix("io.github.raccoonpie314.unfold/combos.json"), url.path)
    }

    // The plan's contract promises an atomic write and sorted keys, but none of its seven
    // cases observes either. Sorted keys are a byte-order fact; atomicity is pinned by the one
    // guarantee users care about -- a save that cannot complete must leave the old library intact.
    // A temp-file-plus-rename needs write permission on the *directory*, so a read-only
    // directory makes it fail loudly. An in-place rewrite would happily clobber the file.
    func testSaveThatCannotCompleteLeavesTheExistingLibraryIntact() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores directory permissions, so this cannot pin atomicity")

        let url = directory.appendingPathComponent("combos.json")
        let store = Store(url: url)
        let original = CombosFile(formatVersion: 1, combos: [makeCombo("one")])
        try store.save(original)

        let fileManager = FileManager.default
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }

        XCTAssertThrowsError(try store.save(CombosFile(formatVersion: 1, combos: [makeCombo("two")])))

        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertTrue(fileManager.fileExists(atPath: url.path), "a failed save must not delete the library")
        XCTAssertEqual(try store.load(), original, "a failed save must not truncate or clobber the library")
    }

    func testSaveSortsKeysSoRewritesDoNotProduceSpuriousDiffs() throws {
        let url = directory.appendingPathComponent("combos.json")
        let file = CombosFile(formatVersion: 1, combos: [makeCombo("add")])
        try Store(url: url).save(file)
        let text = try String(contentsOf: url, encoding: .utf8)

        let combos = text.range(of: "\"combos\"")!.lowerBound
        let formatVersion = text.range(of: "\"formatVersion\"")!.lowerBound
        XCTAssertLessThan(combos, formatVersion, ".sortedKeys puts `combos` before `formatVersion`")

        try Store(url: url).save(file)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
    }

    // The spec's Storage section promises this exact hand-editable JSON; synthesized
    // `Codable` for `Part` would instead nest the payload as {"text":{"_0":...}} and this
    // snippet would fail to decode. Copying the spec block verbatim pins that promise.
    func testTheSpecDocumentedSnippetDecodesIntoCombosFile() throws {
        let specSnippet = """
            {
              "formatVersion": 1,
              "combos": [
                {
                  "id": "6C9C0A1E-2D2B-4E37-9A6B-5C1F0D8E3A11",
                  "trigger": "addr",
                  "label": "Home address",
                  "enabled": true,
                  "parts": [
                    { "text": "I love " },
                    { "placeholder": { "id": "city", "options": ["Shanghai", "Tokyo"] } },
                    { "text": " restaurant" }
                  ],
                  "insertion": "paste"
                }
              ]
            }
            """

        let decoded = try JSONDecoder().decode(CombosFile.self, from: Data(specSnippet.utf8))

        XCTAssertEqual(decoded, CombosFile(
            formatVersion: 1,
            combos: [
                Combo(
                    id: UUID(uuidString: "6C9C0A1E-2D2B-4E37-9A6B-5C1F0D8E3A11")!,
                    trigger: "addr",
                    label: "Home address",
                    enabled: true,
                    parts: [
                        .text("I love "),
                        .placeholder(.init(id: "city", options: ["Shanghai", "Tokyo"])),
                        .text(" restaurant"),
                    ],
                    insertion: .paste
                )
            ]
        ))
    }

    func testSavedFileUsesTheFlatSpecShapeWithNoSynthesizedWrapper() throws {
        let file = CombosFile(
            formatVersion: CombosFile.currentFormatVersion,
            combos: [
                Combo(
                    id: UUID(uuidString: "6C9C0A1E-2D2B-4E37-9A6B-5C1F0D8E3A11")!,
                    trigger: "addr",
                    label: "Home address",
                    enabled: true,
                    parts: [
                        .text("I love "),
                        .placeholder(.init(id: "city", options: ["Shanghai", "Tokyo"])),
                        .text(" restaurant"),
                    ],
                    insertion: .paste
                )
            ]
        )

        try store().save(file)
        let text = try String(contentsOf: directory.appendingPathComponent("combos.json"), encoding: .utf8)

        XCTAssertFalse(text.contains("_0"), "the file must not carry the synthesized nested wrapper")

        // Assert the flat shape structurally: each part object has exactly one key --
        // "text" holding a string, or "placeholder" holding {id, options} directly.
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            "the saved file must be a JSON object"
        )
        let combos = try XCTUnwrap(root["combos"] as? [[String: Any]])
        let parts = try XCTUnwrap(combos[0]["parts"] as? [[String: Any]])

        XCTAssertEqual(Set(parts[0].keys), ["text"])
        XCTAssertEqual(parts[0]["text"] as? String, "I love ")
        XCTAssertEqual(Set(parts[1].keys), ["placeholder"])
        let placeholder = try XCTUnwrap(parts[1]["placeholder"] as? [String: Any])
        XCTAssertEqual(placeholder["id"] as? String, "city")
        XCTAssertEqual(placeholder["options"] as? [String], ["Shanghai", "Tokyo"])
        XCTAssertEqual(Set(parts[2].keys), ["text"])
        XCTAssertEqual(parts[2]["text"] as? String, " restaurant")
    }
}
