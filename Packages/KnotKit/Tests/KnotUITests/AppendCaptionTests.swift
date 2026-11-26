import Foundation
@testable import KnotUI
import Testing

@Test func appendCaptionUsesTheRegionalClockWithoutTheDayPeriod() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let afternoon = try #require(
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 21, minute: 38)))
    #expect(appendCaptionTime(afternoon, calendar: calendar, locale: Locale(identifier: "en_US")) == "9:38")
    #expect(appendCaptionTime(afternoon, calendar: calendar, locale: Locale(identifier: "en_GB")) == "21:38")
}
