import XCTest
@testable import UnfoldEngine

final class TemplateTests: XCTestCase {
    func testPlainTextBecomesOneTextPart() throws {
        XCTAssertEqual(try Template.parse("See you soon"), [.text("See you soon")])
    }

    func testPlaceholderWithoutOptions() throws {
        XCTAssertEqual(
            try Template.parse("Hi {{name}},"),
            [.text("Hi "), .placeholder(.init(id: "name", options: [])), .text(",")]
        )
    }

    func testPlaceholderWithColonSeparatedOptions() throws {
        XCTAssertEqual(
            try Template.parse("I love {{city:Shanghai,Tokyo}} restaurant"),
            [
                .text("I love "),
                .placeholder(.init(id: "city", options: ["Shanghai", "Tokyo"])),
                .text(" restaurant"),
            ]
        )
    }

    func testAdjacentPlaceholdersProduceNoEmptyTextPart() throws {
        XCTAssertEqual(
            try Template.parse("{{a}}{{b}}"),
            [.placeholder(.init(id: "a", options: [])), .placeholder(.init(id: "b", options: []))]
        )
    }

    func testEscapedBracesStayLiteralText() throws {
        XCTAssertEqual(
            try Template.parse(#"\{{a}} and {{b}}"#),
            [.text("{{a}} and "), .placeholder(.init(id: "b", options: []))]
        )
    }

    func testUnclosedPlaceholderThrows() {
        XCTAssertThrowsError(try Template.parse("Hello {{name")) { error in
            XCTAssertEqual(error as? TemplateError, .unclosedPlaceholder("name"))
        }
    }

    func testEmptyPlaceholderNameThrows() {
        XCTAssertThrowsError(try Template.parse("a {{}} b")) { error in
            XCTAssertEqual(error as? TemplateError, .emptyPlaceholderName)
        }
    }

    func testDuplicatePlaceholderNameThrows() {
        XCTAssertThrowsError(try Template.parse("{{x}} then {{x}}")) { error in
            XCTAssertEqual(error as? TemplateError, .duplicatePlaceholderName("x"))
        }
    }

    func testPlaceholderNameContainingBraceThrows() {
        XCTAssertThrowsError(try Template.parse("{{a}b}}")) { error in
            XCTAssertEqual(error as? TemplateError, .invalidPlaceholderName("a}b"))
        }
    }

    func testSerializeRoundTripsUnchanged() throws {
        let source = "I love {{city:Shanghai,Tokyo}} restaurant"
        XCTAssertEqual(try Template.serialize(Template.parse(source)), source)
    }

    func testSerializeEscapesLiteralBraces() throws {
        let parts: [Part] = [.text("use {{braces}} here")]
        XCTAssertEqual(Template.serialize(parts), #"use \{{braces}} here"#)
    }

    func testBackslashBeforePlaceholderSurvivesRoundTrip() throws {
        let parts: [Part] = [.text(#"C:\"#), .placeholder(.init(id: "x", options: []))]
        XCTAssertEqual(Template.serialize(parts), #"C:\\{{x}}"#)
        XCTAssertEqual(try Template.parse(Template.serialize(parts)), parts)
    }
}
