import XCTest
@testable import KnotKit

final class RewriteDomainTests: XCTestCase {
    func test_T02_rejectsTraversalAbsoluteAndAmbiguousPaths() throws {
        for path in ["../Outside", "Inbox/../Outside", "/tmp/note", "C:/note", "Inbox\\note", "Inbox//note"] {
            XCTAssertThrowsError(try VaultRelativePath(path, kind: .file), path)
        }
        XCTAssertEqual(try VaultRelativePath("", kind: .folder), .root)
        XCTAssertEqual(try VaultRelativePath("Projects/Ideas", kind: .folder).components, ["Projects", "Ideas"])
    }

    func test_T09_rejectsUnknownDateTokensAndSupportsISOWeekYear() throws {
        XCTAssertThrowsError(try CompiledDatePattern("yyyy-MM-dd"))
        XCTAssertThrowsError(try CompiledDatePattern("YYYY-[unfinished"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2021, month: 1, day: 1)))
        let format = try CompiledDatePattern("GGGG-[W]WW-E")
        XCTAssertEqual(format.render(date: date, timeZone: calendar.timeZone), "2020-W53-5")
    }

    func test_T09_bulletRequiresContentAndIndentsEveryLineBreak() throws {
        XCTAssertThrowsError(try CompiledBulletTemplate("- {{HH:mm}}"))
        let format = try CompiledBulletTemplate("- {{content}}")
        let rendered = format.render(
            content: "one\rtwo\r\nthree\u{2028}four",
            date: Date(timeIntervalSince1970: 0),
            locale: Locale(identifier: "en_US"),
            timeZone: try XCTUnwrap(TimeZone(identifier: "UTC"))
        )
        XCTAssertEqual(rendered, "- one\n  two\n  three\n  four")
    }

    func test_T09_validatedSettingsRejectsUnsafeAndContentDroppingValues() throws {
        XCTAssertThrowsError(try ValidatedSettings(dailyFolder: "../Daily"))
        XCTAssertThrowsError(try ValidatedSettings(dailyBulletFormat: "- {{HH:mm}}"))
        XCTAssertThrowsError(try ValidatedSettings(routingMaxChars: 0))
        XCTAssertNoThrow(try ValidatedSettings(dailyFolder: "", inboxFolder: ""))
    }

    func test_T19_routingRecognizesAllLineBreaksAndCountsGraphemes() {
        let policy = RoutingPolicy(maxCharsForDaily: 2, requireSingleLineForDaily: true)
        for value in ["a\nb", "a\rb", "a\r\nb", "a\u{2028}b", "a\u{2029}b"] {
            XCTAssertEqual(policy.decide(for: value), .inbox, value.debugDescription)
        }
        XCTAssertEqual(policy.decide(for: "👨‍👩‍👧‍👦a"), .daily)
        XCTAssertEqual(policy.decide(for: "👨‍👩‍👧‍👦ab"), .inbox)
    }

    func test_T09_titleFilenamePreservesReadableUnicodeAndBoundsUTF8() throws {
        let input = String(repeating: "界", count: 100)
        let stem = try SafeFilename.stem(from: input)
        XCTAssertTrue(stem.hasPrefix("界"))
        XCTAssertLessThanOrEqual(stem.utf8.count, 180)
        XCTAssertFalse(stem.hasSuffix("."))
    }

    func test_captureDocumentPreservesExactNonblankMarkdown() throws {
        let markdown = "  code  \r\nnext  "
        let document = try CaptureDocument(markdown: markdown)
        XCTAssertEqual(document.markdown, markdown)
        XCTAssertThrowsError(try CaptureDocument(markdown: " \t\r\n "))
    }
}
