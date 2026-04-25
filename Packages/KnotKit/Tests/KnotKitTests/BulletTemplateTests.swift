import XCTest
@testable import KnotKit

final class BulletTemplateTests: XCTestCase {

    private let date: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 4; c.day = 5; c.hour = 14; c.minute = 32
        c.timeZone = .current
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    func test_defaultTemplate() {
        let result = BulletTemplate.render(
            template: "- {{HH:mm}} {{content}}",
            content: "a thought",
            date: date
        )
        XCTAssertEqual(result, "- 14:32 a thought")
    }

    func test_supportsArbitraryMomentTokens() {
        let result = BulletTemplate.render(
            template: "- [[{{YYYY-MM-DD}}]] {{HH:mm}} {{content}}",
            content: "linked",
            date: date
        )
        XCTAssertEqual(result, "- [[2026-04-05]] 14:32 linked")
    }

    func test_contentLiteralPassedThrough() {
        let result = BulletTemplate.render(
            template: "- {{content}}",
            content: "with {{braces}} inside",
            date: date
        )
        XCTAssertEqual(result, "- with {{braces}} inside")
    }

    func test_noPlaceholdersRemainsUnchanged() {
        let result = BulletTemplate.render(
            template: "- static text",
            content: "ignored",
            date: date
        )
        XCTAssertEqual(result, "- static text")
    }

    func test_unmatchedOpenBraceLeftAsLiteral() {
        let result = BulletTemplate.render(
            template: "- {{content broken",
            content: "x",
            date: date
        )
        XCTAssertEqual(result, "- {{content broken")
    }
}
