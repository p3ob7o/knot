import XCTest
@testable import KnotKit

/// Integration tests that exercise `Vault.write` against a temp folder.
/// These don't use security-scoped resources (the temp directory is freely
/// writable on the host), but they verify the end-to-end shape of the file
/// the apps will produce.
final class VaultIntegrationTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "KnotKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    func test_dailyAppend_createsFileAndAppendsBullet() throws {
        let settings = AppSettings()
        let vault = Vault(url: tempRoot, settings: settings)
        let date = makeDate(2026, 4, 25, 14, 32)
        let note = Note(content: "first thought", mode: .daily, createdAt: date)

        let url = try vault.write(note: note)
        let contents = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(url.path.contains("Daily/2026-04-25.md"))
        XCTAssertEqual(contents, "## Quick notes\n\n- 14:32 first thought\n")

        // Second write into the same file should append under the heading.
        let date2 = makeDate(2026, 4, 25, 16, 0)
        let note2 = Note(content: "second thought", mode: .daily, createdAt: date2)
        _ = try vault.write(note: note2)
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(after, "## Quick notes\n\n- 14:32 first thought\n- 16:00 second thought\n")
    }

    func test_inboxWrite_createsNewFile() throws {
        let settings = AppSettings()
        let vault = Vault(url: tempRoot, settings: settings)
        let date = makeDate(2026, 4, 25, 14, 32)
        let note = Note(
            content: "Project planning notes\n\nWith multiple lines",
            mode: .inbox,
            createdAt: date
        )

        let url = try vault.write(note: note)
        let contents = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(url.lastPathComponent, "2026-04-25 1432 - project-planning-notes.md")
        XCTAssertTrue(url.path.contains("Inbox/"))
        XCTAssertEqual(contents, "Project planning notes\n\nWith multiple lines")
    }

    func test_inboxCollision_appendsCounter() throws {
        let settings = AppSettings()
        let vault = Vault(url: tempRoot, settings: settings)
        let date = makeDate(2026, 4, 25, 14, 32)
        let note = Note(content: "same title", mode: .inbox, createdAt: date)
        let note2 = Note(content: "same title", mode: .inbox, createdAt: date)

        let first = try vault.write(note: note)
        let second = try vault.write(note: note2)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, "2026-04-25 1432 - same-title.md")
        XCTAssertEqual(second.lastPathComponent, "2026-04-25 1432 - same-title (1).md")
    }

    func test_emptyContent_throws() throws {
        let settings = AppSettings()
        let vault = Vault(url: tempRoot, settings: settings)
        let note = Note(content: "   \n  ", mode: .daily, createdAt: Date())
        XCTAssertThrowsError(try vault.write(note: note))
    }

    // MARK: - Helpers

    private func makeDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        c.timeZone = .current
        return Calendar(identifier: .gregorian).date(from: c)!
    }
}
