import XCTest
@testable import KnotKit

final class LegacySettingsMigrationTests: XCTestCase {
    func test_T22_fieldMigrationBacksUpRawBytesAndRepairsOnlyInvalidFields() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let raw = Data(#"{"dailyFolder":"Journal","inboxFolder":"../outside","dailyFilenameFormat":"yyyy-MM-dd","routingMaxChars":900}"#.utf8)
        let migrator = LegacySettingsMigrator(applicationSupportDirectory: fixture.url)
        let first = try migrator.migrate(rawData: raw)
        XCTAssertEqual(try Data(contentsOf: first.backupURL), raw)
        XCTAssertEqual(first.settings.dailyFolder.string, "Journal")
        XCTAssertEqual(first.settings.inboxFolder.string, "Inbox")
        XCTAssertEqual(first.settings.dailyFilenameFormat, "YYYY-MM-DD")
        XCTAssertEqual(first.settings.routingMaxChars, 900)
        XCTAssertEqual(first.repairedFields, ["inboxFolder"])
        let second = try migrator.migrate(rawData: raw)
        XCTAssertEqual(second, first)
    }

    func test_T22_malformedRootPreservesBackupAndUsesSafeDefaults() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let raw = Data("not-json".utf8)
        let report = try LegacySettingsMigrator(applicationSupportDirectory: fixture.url).migrate(rawData: raw)
        XCTAssertEqual(try Data(contentsOf: report.backupURL), raw)
        XCTAssertEqual(report.settings, try ValidatedSettings())
        XCTAssertEqual(report.repairedFields, ["root"])
    }
}
