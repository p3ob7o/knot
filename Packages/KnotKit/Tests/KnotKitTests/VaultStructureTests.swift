import XCTest
@testable import KnotKit

final class VaultStructureTests: XCTestCase {
    private var vaultURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        vaultURL = FileManager.default.temporaryDirectory
            .appending(path: "KnotStructureTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vaultURL)
        try super.tearDownWithError()
    }

    func test_normalizeFolderPath_preservesRootAsEmpty() {
        XCTAssertEqual(VaultStructure.normalizeFolderPath(""), "")
        XCTAssertEqual(VaultStructure.normalizeFolderPath("  /Daily/Notes/  "), "Daily/Notes")
        XCTAssertEqual(VaultStructure.normalizeFolderPath("Inbox//Projects"), "Inbox/Projects")
    }

    func test_folders_includesRootAndNestedFolders() throws {
        try createDirectory("Inbox/Projects")
        try createDirectory("Daily")
        try createDirectory(".obsidian/plugins")
        try "body".write(
            to: vaultURL.appending(path: "loose.md"),
            atomically: true,
            encoding: .utf8
        )

        let folders = VaultStructure.folders(in: vaultURL)

        XCTAssertEqual(folders.first?.path, "")
        XCTAssertTrue(folders.contains(VaultFolder(path: "Inbox")))
        XCTAssertTrue(folders.contains(VaultFolder(path: "Inbox/Projects")))
        XCTAssertTrue(folders.contains(VaultFolder(path: "Daily")))
        XCTAssertFalse(folders.contains(VaultFolder(path: ".obsidian")))
        XCTAssertFalse(folders.contains(VaultFolder(path: ".obsidian/plugins")))
    }

    func test_childFolders_listsOnlyImmediateChildren() throws {
        try createDirectory("Inbox/Projects")
        try createDirectory("Inbox/Areas")
        try createDirectory("Daily")

        let rootChildren = VaultStructure.childFolders(in: vaultURL, parentPath: "")
        let inboxChildren = VaultStructure.childFolders(in: vaultURL, parentPath: "Inbox")

        XCTAssertEqual(rootChildren.map(\.path), ["Daily", "Inbox"])
        XCTAssertEqual(inboxChildren.map(\.path), ["Inbox/Areas", "Inbox/Projects"])
    }

    func test_dailyNoteURL_usesRootDailyFolder() {
        var settings = AppSettings()
        settings.dailyFolder = ""
        let date = makeDate(2026, 4, 25, 14, 32)

        let url = VaultStructure.dailyNoteURL(in: vaultURL, settings: settings, date: date)

        XCTAssertEqual(url.path, vaultURL.appending(path: "2026-04-25.md").path)
    }

    func test_markdownHeadings_readsValidHeadings() throws {
        let noteURL = vaultURL.appending(path: "2026-04-25.md")
        try """
        # Morning

        text
        ## Quick notes
        ### Later
        ####
        not a heading
        """.write(to: noteURL, atomically: true, encoding: .utf8)

        let headings = VaultStructure.markdownHeadings(in: noteURL)

        XCTAssertEqual(headings, [
            MarkdownHeading(level: 1, title: "Morning", raw: "# Morning"),
            MarkdownHeading(level: 2, title: "Quick notes", raw: "## Quick notes"),
            MarkdownHeading(level: 3, title: "Later", raw: "### Later")
        ])
    }

    func test_dailyNoteHeadings_readsUsingSettings() throws {
        var settings = AppSettings()
        settings.dailyFolder = "Daily"
        let date = makeDate(2026, 4, 25, 14, 32)
        try createDirectory("Daily")
        try """
        # Journal
        ## Captures
        """.write(
            to: vaultURL.appending(path: "Daily/2026-04-25.md"),
            atomically: true,
            encoding: .utf8
        )

        let headings = VaultStructure.dailyNoteHeadings(
            in: vaultURL,
            settings: settings,
            date: date
        )

        XCTAssertEqual(headings.map(\.raw), ["# Journal", "## Captures"])
    }

    private func createDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(
            at: vaultURL.appending(path: path, directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        c.timeZone = .current
        return Calendar(identifier: .gregorian).date(from: c)!
    }
}
