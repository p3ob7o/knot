import XCTest
@testable import KnotKit

final class TitleExtractorTests: XCTestCase {

    // MARK: - Detection rules

    func test_detectsSingleWordTitle() {
        let result = TitleExtractor.extract(from: "# Idea")
        XCTAssertEqual(result?.filename, "Idea")
        XCTAssertEqual(result?.strippedBody, "")
    }

    func test_detectsSevenWordTitle() {
        let result = TitleExtractor.extract(from: "# one two three four five six seven\nbody")
        XCTAssertEqual(result?.filename, "one two three four five six seven")
        XCTAssertEqual(result?.strippedBody, "body")
    }

    func test_rejectsEightWordTitle() {
        let result = TitleExtractor.extract(from: "# one two three four five six seven eight\nbody")
        XCTAssertNil(result)
    }

    func test_rejectsHTwo() {
        XCTAssertNil(TitleExtractor.extract(from: "## Heading\nbody"))
    }

    func test_rejectsHashWithoutSpace() {
        XCTAssertNil(TitleExtractor.extract(from: "#Idea\nbody"))
    }

    func test_rejectsLeadingWhitespace() {
        XCTAssertNil(TitleExtractor.extract(from: "  # Idea\nbody"))
    }

    func test_rejectsBareHashSpace() {
        XCTAssertNil(TitleExtractor.extract(from: "# \nbody"))
    }

    func test_rejectsEmptyContent() {
        XCTAssertNil(TitleExtractor.extract(from: ""))
    }

    func test_returnsNilWhenFirstLineIsBody() {
        XCTAssertNil(TitleExtractor.extract(from: "Just a regular note"))
    }

    // MARK: - Body stripping

    func test_stripsHeadingAndFollowingBlankLines() {
        let result = TitleExtractor.extract(from: "# Title\n\n\nbody line")
        XCTAssertEqual(result?.filename, "Title")
        XCTAssertEqual(result?.strippedBody, "body line")
    }

    func test_preservesBodyAfterCRLF() {
        let result = TitleExtractor.extract(from: "# Title\r\nbody")
        XCTAssertEqual(result?.filename, "Title")
        XCTAssertEqual(result?.strippedBody, "body")
    }

    func test_emptyBodyAfterTitle() {
        let result = TitleExtractor.extract(from: "# Title\n")
        XCTAssertEqual(result?.filename, "Title")
        XCTAssertEqual(result?.strippedBody, "")
    }

    // MARK: - Sanitization

    func test_replacesIllegalCharactersWithHyphen() {
        let result = TitleExtractor.extract(from: "# foo/bar:baz")
        XCTAssertEqual(result?.filename, "foo-bar-baz")
    }

    func test_collapsesRunsOfHyphens() {
        let result = TitleExtractor.extract(from: "# a//b")
        XCTAssertEqual(result?.filename, "a-b")
    }

    func test_trimsTrailingDotsAndSpaces() {
        let result = TitleExtractor.extract(from: "# Hello world... ")
        XCTAssertEqual(result?.filename, "Hello world")
    }

    func test_keepsUnicodeAndPreservesCase() {
        let result = TitleExtractor.extract(from: "# Café Résumé")
        XCTAssertEqual(result?.filename, "Café Résumé")
    }

    func test_returnsNilWhenSanitizationEmptiesTitle() {
        // All characters are filesystem-illegal; result would be empty.
        XCTAssertNil(TitleExtractor.extract(from: "# ///"))
    }
}
