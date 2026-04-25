import XCTest
@testable import KnotKit

final class MomentFormatTests: XCTestCase {

    private let date = makeDate(2026, 4, 5, 14, 32, 7) // Sun, April 5 2026 14:32:07
    private let utc = TimeZone(identifier: "UTC")!

    func test_basicYearMonthDay() {
        XCTAssertEqual(format("YYYY-MM-DD", date), "2026-04-05")
        XCTAssertEqual(format("YY-M-D", date), "26-4-5")
    }

    func test_daysOfWeekAndMonth() {
        XCTAssertEqual(format("dddd", date), "Sunday")
        XCTAssertEqual(format("ddd", date), "Sun")
        XCTAssertEqual(format("MMMM", date), "April")
        XCTAssertEqual(format("MMM", date), "Apr")
    }

    func test_hours() {
        XCTAssertEqual(format("HH:mm:ss", date), "14:32:07")
        XCTAssertEqual(format("h:mm A", date), "2:32 PM")
        XCTAssertEqual(format("h:mm a", date), "2:32 pm")
    }

    func test_literalEscape() {
        XCTAssertEqual(format("[Year:] YYYY", date), "Year: 2026")
        // Wikilink-style usage common in Obsidian setups:
        XCTAssertEqual(format("[[]YYYY-MM-DD[]]", date), "[2026-04-05]")
    }

    func test_pathTemplateProducesSlashes() {
        XCTAssertEqual(format("YYYY/MM/YYYY-MM-DD", date), "2026/04/2026-04-05")
    }

    func test_unknownTokensTreatedAsLiteral() {
        // `B`, `n`, `&` aren't Moment tokens; should render literally.
        XCTAssertEqual(format("B&n", date), "B&n")
    }

    func test_dayOfYearAndWeek() {
        // April 5 2026 is the 95th day of the year. Week-of-year is locale-
        // dependent; we just assert it's a sensible 1-2 digit number.
        XCTAssertEqual(format("DDD", date), "95")
        XCTAssertEqual(format("DDDD", date), "095")
        let week = format("ww", date)
        XCTAssertTrue(week.count == 2 && Int(week) != nil, "got \(week)")
    }

    func test_isoWeekday() {
        // Sunday = 7 in ISO.
        XCTAssertEqual(format("E", date), "7")
        // Monday = 1 in ISO.
        let monday = Self.makeDate(2026, 4, 6, 9, 0, 0)
        XCTAssertEqual(format("E", monday), "1")
    }

    func test_quarter() {
        XCTAssertEqual(format("Q", date), "2")
    }

    func test_unixEpoch() {
        // Anchor with UTC to avoid drift from local timezone.
        let epoch = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(MomentFormat.string(from: epoch, format: "X", timeZone: utc), "0")
        XCTAssertEqual(MomentFormat.string(from: epoch, format: "x", timeZone: utc), "0")
    }

    func test_offsetTokens() {
        // UTC formatted as +00:00 / +0000.
        XCTAssertEqual(MomentFormat.string(from: date, format: "Z", timeZone: utc), "+00:00")
        XCTAssertEqual(MomentFormat.string(from: date, format: "ZZ", timeZone: utc), "+0000")
    }

    func test_ordinals() {
        let s = format("MMMM Do, YYYY", date)
        XCTAssertEqual(s, "April 5th, 2026")
    }

    func test_meridiemMidnightAndNoon() {
        let midnight = Self.makeDate(2026, 4, 5, 0, 0, 0)
        let noon = Self.makeDate(2026, 4, 5, 12, 0, 0)
        XCTAssertEqual(format("h:mm A", midnight), "12:00 AM")
        XCTAssertEqual(format("h:mm A", noon), "12:00 PM")
        XCTAssertEqual(format("HH:mm", midnight), "00:00")
        XCTAssertEqual(format("kk:mm", midnight), "24:00")
    }

    // MARK: - Helpers

    private func format(_ fmt: String, _ d: Date) -> String {
        MomentFormat.string(from: d, format: fmt, timeZone: .current)
    }

    static func makeDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ sec: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min; c.second = sec
        c.timeZone = .current
        return Calendar(identifier: .gregorian).date(from: c)!
    }
}

private func makeDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ sec: Int) -> Date {
    MomentFormatTests.makeDate(y, m, d, h, min, sec)
}
