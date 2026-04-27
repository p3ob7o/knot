import XCTest
@testable import KnotKit

/// Each test writes a small `.obsidian/` tree into a temp directory, then
/// calls `ObsidianConfigImporter.read(vaultURL:)` on the parent and asserts
/// the returned value. Reads happen via NSFileCoordinator inside the
/// importer; the temp directory is freely accessible so no security scope
/// is required.
final class ObsidianConfigImporterTests: XCTestCase {

    private var vaultURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        vaultURL = FileManager.default.temporaryDirectory
            .appending(path: "KnotKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vaultURL)
        try super.tearDownWithError()
    }

    // MARK: - Periodic Notes

    func test_periodicNotes_enabledWithDailyFormat_returnsPeriodic() throws {
        try writeCommunityPlugins(["periodic-notes"])
        try writePeriodicNotesData(daily: [
            "enabled": true,
            "folder": "Journal",
            "format": "YYYY-MM-DD dddd"
        ])

        let result = ObsidianConfigImporter.read(vaultURL: vaultURL)

        XCTAssertEqual(result, ImportedDailyConfig(
            folder: "Journal",
            filenameFormat: "YYYY-MM-DD dddd",
            source: .periodicNotes
        ))
    }

    func test_periodicNotes_dailyDisabled_fallsThroughToCore() throws {
        try writeCommunityPlugins(["periodic-notes"])
        try writePeriodicNotesData(daily: [
            "enabled": false,
            "folder": "Journal",
            "format": "YYYY-MM-DD dddd"
        ])
        try writeCoreDailyNotes(["folder": "Daily", "format": "YYYY-MM-DD"])

        let result = ObsidianConfigImporter.read(vaultURL: vaultURL)

        XCTAssertEqual(result?.source, .coreDailyNotes)
        XCTAssertEqual(result?.folder, "Daily")
        XCTAssertEqual(result?.filenameFormat, "YYYY-MM-DD")
    }

    func test_periodicNotes_dailyFormatEmpty_fallsThroughToCore() throws {
        try writeCommunityPlugins(["periodic-notes"])
        try writePeriodicNotesData(daily: [
            "enabled": true,
            "folder": "Journal",
            "format": ""
        ])
        try writeCoreDailyNotes(["folder": "Diary", "format": "YYYY-MM-DD"])

        let result = ObsidianConfigImporter.read(vaultURL: vaultURL)

        XCTAssertEqual(result?.source, .coreDailyNotes)
        XCTAssertEqual(result?.folder, "Diary")
    }

    func test_periodicNotes_dailyFormatMissing_fallsThroughToCore() throws {
        try writeCommunityPlugins(["periodic-notes"])
        try writePeriodicNotesData(daily: [
            "enabled": true,
            "folder": "Journal"
        ])
        try writeCoreDailyNotes(["folder": "Diary", "format": "YYYY-MM-DD"])

        let result = ObsidianConfigImporter.read(vaultURL: vaultURL)

        XCTAssertEqual(result?.source, .coreDailyNotes)
    }

    func test_periodicNotes_listedButDataJsonMissing_fallsThroughToCore() throws {
        try writeCommunityPlugins(["periodic-notes"])
        try writeCoreDailyNotes(["folder": "Daily", "format": "YYYY-MM-DD"])

        let result = ObsidianConfigImporter.read(vaultURL: vaultURL)

        XCTAssertEqual(result?.source, .coreDailyNotes)
    }

    func test_periodicNotes_dataJsonMalformed_fallsThroughToCore() throws {
        try writeCommunityPlugins(["periodic-notes"])
        try writePeriodicNotesRawData("not json {")
        try writeCoreDailyNotes(["folder": "Daily", "format": "YYYY-MM-DD"])

        let result = ObsidianConfigImporter.read(vaultURL: vaultURL)

        XCTAssertEqual(result?.source, .coreDailyNotes)
    }

    func test_periodicNotes_emptyFolder_preservedAsEmpty() throws {
        try writeCommunityPlugins(["periodic-notes"])
        try writePeriodicNotesData(daily: [
            "enabled": true,
            "folder": "",
            "format": "YYYY-MM-DD"
        ])

        let result = ObsidianConfigImporter.read(vaultURL: vaultURL)

        XCTAssertEqual(result?.source, .periodicNotes)
        XCTAssertEqual(result?.folder, "")
        XCTAssertEqual(result?.filenameFormat, "YYYY-MM-DD")
    }

    // MARK: - Core Daily Notes

    func test_coreDailyNotes_present_returnsCore() throws {
        try writeCoreDailyNotes(["folder": "Daily", "format": "YYYY-MM-DD"])

        let result = ObsidianConfigImporter.read(vaultURL: vaultURL)

        XCTAssertEqual(result, ImportedDailyConfig(
            folder: "Daily",
            filenameFormat: "YYYY-MM-DD",
            source: .coreDailyNotes
        ))
    }

    func test_coreDailyNotes_emptyFormat_fallsBackToDefault() throws {
        try writeCoreDailyNotes(["folder": "Daily", "format": ""])

        let result = ObsidianConfigImporter.read(vaultURL: vaultURL)

        XCTAssertEqual(result?.source, .coreDailyNotes)
        XCTAssertEqual(result?.folder, "Daily")
        XCTAssertEqual(result?.filenameFormat, "YYYY-MM-DD")
    }

    func test_coreDailyNotes_missingFormat_fallsBackToDefault() throws {
        try writeCoreDailyNotes(["folder": "Daily"])

        let result = ObsidianConfigImporter.read(vaultURL: vaultURL)

        XCTAssertEqual(result?.source, .coreDailyNotes)
        XCTAssertEqual(result?.filenameFormat, "YYYY-MM-DD")
    }

    func test_coreDailyNotes_missingFolder_returnsEmptyString() throws {
        try writeCoreDailyNotes(["format": "YYYY-MM-DD"])

        let result = ObsidianConfigImporter.read(vaultURL: vaultURL)

        XCTAssertEqual(result?.source, .coreDailyNotes)
        XCTAssertEqual(result?.folder, "")
    }

    func test_coreDailyNotes_emptyFolder_preservedAsEmpty() throws {
        try writeCoreDailyNotes(["folder": "", "format": "YYYY-MM-DD"])

        let result = ObsidianConfigImporter.read(vaultURL: vaultURL)

        XCTAssertEqual(result?.folder, "")
    }

    func test_coreDailyNotes_malformedJson_returnsNil() throws {
        try writeCoreDailyNotesRaw("{ this is not json")

        let result = ObsidianConfigImporter.read(vaultURL: vaultURL)

        XCTAssertNil(result)
    }

    // MARK: - Default

    func test_noObsidianDirectory_returnsNil() {
        let result = ObsidianConfigImporter.read(vaultURL: vaultURL)
        XCTAssertNil(result)
    }

    func test_obsidianDirectoryButNoRecognizedConfig_returnsNil() throws {
        try FileManager.default.createDirectory(
            at: vaultURL.appending(path: ".obsidian", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        let result = ObsidianConfigImporter.read(vaultURL: vaultURL)

        XCTAssertNil(result)
    }

    // MARK: - Helpers

    private func writeCommunityPlugins(_ ids: [String]) throws {
        let dir = vaultURL.appending(path: ".obsidian", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ids, options: [])
        try data.write(to: dir.appending(path: "community-plugins.json"))
    }

    private func writePeriodicNotesData(daily: [String: Any]) throws {
        let dir = vaultURL.appending(
            path: ".obsidian/plugins/periodic-notes",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let payload: [String: Any] = ["daily": daily]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        try data.write(to: dir.appending(path: "data.json"))
    }

    private func writePeriodicNotesRawData(_ raw: String) throws {
        let dir = vaultURL.appending(
            path: ".obsidian/plugins/periodic-notes",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try raw.write(
            to: dir.appending(path: "data.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeCoreDailyNotes(_ payload: [String: Any]) throws {
        let dir = vaultURL.appending(path: ".obsidian", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        try data.write(to: dir.appending(path: "daily-notes.json"))
    }

    private func writeCoreDailyNotesRaw(_ raw: String) throws {
        let dir = vaultURL.appending(path: ".obsidian", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try raw.write(
            to: dir.appending(path: "daily-notes.json"),
            atomically: true,
            encoding: .utf8
        )
    }
}
