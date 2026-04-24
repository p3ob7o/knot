import XCTest
@testable import KnotKit

final class SlugTests: XCTestCase {

    func test_basicLowercase() {
        XCTAssertEqual(Slug.from("Hello World"), "hello-world")
    }

    func test_stripsPunctuation() {
        XCTAssertEqual(Slug.from("Hello, world! How are you?"), "hello-world-how-are-you")
    }

    func test_collapsesMultipleSpaces() {
        XCTAssertEqual(Slug.from("foo    bar     baz"), "foo-bar-baz")
    }

    func test_usesFirstNonEmptyLine() {
        let text = """


        First useful line
        Second line
        """
        XCTAssertEqual(Slug.from(text), "first-useful-line")
    }

    func test_truncatesToMaxLength() {
        let text = String(repeating: "abc ", count: 50) // very long
        let slug = Slug.from(text, maxLength: 20)
        XCTAssertLessThanOrEqual(slug.count, 20)
        XCTAssertFalse(slug.hasSuffix("-"))
    }

    func test_emptyOrPunctuationOnly_returnsEmpty() {
        XCTAssertEqual(Slug.from(""), "")
        XCTAssertEqual(Slug.from("!!!"), "")
        XCTAssertEqual(Slug.from("\n\n\n"), "")
    }

    func test_unicodeStrippedAggressively() {
        // v0 keeps the slug ASCII-only for filesystem safety.
        XCTAssertEqual(Slug.from("café résumé"), "caf-r-sum")
    }
}
