import XCTest
@testable import KnotKit

final class DailyDocumentRewriteTests: XCTestCase {
    func test_T01_invalidUTF8IsRejectedWithoutChangingInput() {
        let original = Data([0x23, 0x20, 0x41, 0x0A, 0xFF, 0xFE])
        XCTAssertThrowsError(try DailyDocument(data: original)) { error in
            XCTAssertEqual(error as? DailyDocumentError, .invalidUTF8)
        }
        XCTAssertEqual(original, Data([0x23, 0x20, 0x41, 0x0A, 0xFF, 0xFE]))
    }

    func test_T08_fencedQuotedAndListHeadingsAreNotDiscovered() throws {
        let source = """
        ---
        title: "# frontmatter"
        ---
        ~~~md
        ## Example
        ~~~
        > ## Quote
        - ## List
        # Real
        body
        ## Child
        """
        let document = try DailyDocument(data: Data(source.utf8))
        XCTAssertEqual(document.headings.map(\.selector.title), ["Real", "Child"])
        XCTAssertEqual(document.headings[1].selector.ancestorPath, ["Real"])
    }

    func test_T08_setextDuplicateAndEmojiOffsetsInsertAtSelectedSection() throws {
        let source = "😀 intro\r\n\r\nQuick notes\r\n-----------\r\none\r\n\r\nQuick notes\r\n-----------\r\ntwo\r\n"
        let document = try DailyDocument(data: Data(source.utf8))
        XCTAssertEqual(document.headings.count, 2)
        XCTAssertEqual(document.headings.map(\.selector.occurrence), [0, 1], String(describing: document.headings))

        let selected = document.headings[1].selector
        let output = try document.inserting("- captured", target: .heading(selected, missing: .ask))
        let string = try XCTUnwrap(String(data: output, encoding: .utf8))
        XCTAssertTrue(string.contains("two\r\n- captured\r\n"), string.debugDescription)
        XCTAssertTrue(string.hasPrefix("😀 intro\r\n"))
        XCTAssertFalse(string.contains("one\r\n- captured"))
    }

    func test_T08_missingHeadingAskFailsAndCreateAddsHeading() throws {
        let document = try DailyDocument(data: Data("# Existing\nbody\n".utf8))
        let selector = try HeadingSelector(title: "Quick notes", level: 2)
        XCTAssertThrowsError(try document.inserting("- x", target: .heading(selector, missing: .ask)))

        let output = try document.inserting("- x", target: .heading(selector, missing: .createAtEnd))
        let string = try XCTUnwrap(String(data: output, encoding: .utf8))
        XCTAssertTrue(string.contains("## Quick notes\n\n- x\n"))
    }

    func test_T08_endOfNotePreservesBOMAndCRLF() throws {
        let source = Data([0xEF, 0xBB, 0xBF]) + Data("# Day\r\ntext\r\n".utf8)
        let document = try DailyDocument(data: source)
        let output = try document.inserting("- tail", target: .endOfNote)
        XCTAssertTrue(output.starts(with: [0xEF, 0xBB, 0xBF]))
        XCTAssertEqual(String(data: output.dropFirst(3), encoding: .utf8), "# Day\r\ntext\r\n- tail\r\n\r\n")
    }

    func test_T08_unmodifiedBytesRemainIdenticalAroundInsertion() throws {
        let prefix = "---\nkey: value  \n---\n# Day\n\tindented\n## Quick notes\nexisting  "
        let suffix = "\n\n# Later\n~~~\n## literal\n~~~\n"
        let source = prefix + suffix
        let document = try DailyDocument(data: Data(source.utf8))
        let selected = try XCTUnwrap(document.headings.first { $0.selector.title == "Quick notes" })
        let output = try document.inserting("- new", target: .heading(selected.selector, missing: .ask))
        let result = try XCTUnwrap(String(data: output, encoding: .utf8))
        XCTAssertTrue(result.hasPrefix(prefix + "\n- new\n"))
        XCTAssertTrue(result.hasSuffix(suffix))
    }
}
