import XCTest
@testable import UnfoldEngine

final class CombosFileTests: XCTestCase {
    func testCombosFileRoundTripsThroughJSON() throws {
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
                        .placeholder(.init(
                            id: "city",
                            options: ["Shanghai", "Tokyo"]
                        )),
                        .text(" restaurant"),
                    ],
                    insertion: .paste
                )
            ]
        )

        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(CombosFile.self, from: data)

        XCTAssertEqual(decoded, file)
    }
}
