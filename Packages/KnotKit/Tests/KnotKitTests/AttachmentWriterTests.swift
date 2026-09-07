import XCTest
@testable import KnotKit

final class AttachmentWriterTests: XCTestCase {

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

    func test_writeAttachmentToVaultRootWhenSettingIsEmpty() throws {
        let noteURL = vaultURL.appending(path: "Inbox/2026-06-07.md")
        let writer = AttachmentWriter(vault: vaultURL, settings: AppSettings())

        let result = try writer.write(AttachmentWriteRequest(
            filename: "Sketch.png",
            data: Data("png".utf8),
            noteURL: noteURL
        ))

        XCTAssertEqual(result.vaultRelativePath, "Sketch.png")
        XCTAssertEqual(result.markdownEmbed, "![[Sketch.png]]")
        XCTAssertEqual(try Data(contentsOf: result.fileURL), Data("png".utf8))
    }

    func test_writeAttachmentToConfiguredVaultFolder() throws {
        var settings = AppSettings()
        settings.attachmentFolderPath = "Media/Images"
        let writer = AttachmentWriter(vault: vaultURL, settings: settings)
        let noteURL = vaultURL.appending(path: "Inbox/2026-06-07.md")

        let result = try writer.write(AttachmentWriteRequest(
            filename: "diagram.png",
            data: Data("image".utf8),
            noteURL: noteURL
        ))

        XCTAssertEqual(result.vaultRelativePath, "Media/Images/diagram.png")
        XCTAssertEqual(result.markdownEmbed, "![[Media/Images/diagram.png]]")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.fileURL.path))
    }

    func test_writeAttachmentNextToNoteForDotSetting() throws {
        var settings = AppSettings()
        settings.attachmentFolderPath = "."
        let writer = AttachmentWriter(vault: vaultURL, settings: settings)
        let noteURL = vaultURL.appending(path: "Inbox/Projects/Project.md")

        let result = try writer.write(AttachmentWriteRequest(
            filename: "photo.png",
            data: Data("image".utf8),
            noteURL: noteURL
        ))

        XCTAssertEqual(result.vaultRelativePath, "Inbox/Projects/photo.png")
    }

    func test_writeAttachmentToSubfolderUnderNoteFolder() throws {
        var settings = AppSettings()
        settings.attachmentFolderPath = "./assets"
        let writer = AttachmentWriter(vault: vaultURL, settings: settings)
        let noteURL = vaultURL.appending(path: "Inbox/Projects/Project.md")

        let result = try writer.write(AttachmentWriteRequest(
            filename: "photo.png",
            data: Data("image".utf8),
            noteURL: noteURL
        ))

        XCTAssertEqual(result.vaultRelativePath, "Inbox/Projects/assets/photo.png")
    }

    func test_writeAttachmentResolvesFilenameCollisions() throws {
        var settings = AppSettings()
        settings.attachmentFolderPath = "Media"
        let writer = AttachmentWriter(vault: vaultURL, settings: settings)
        let noteURL = vaultURL.appending(path: "Inbox/Note.md")

        _ = try writer.write(AttachmentWriteRequest(
            filename: "diagram.png",
            data: Data("first".utf8),
            noteURL: noteURL
        ))
        let second = try writer.write(AttachmentWriteRequest(
            filename: "diagram.png",
            data: Data("second".utf8),
            noteURL: noteURL
        ))

        XCTAssertEqual(second.vaultRelativePath, "Media/diagram (1).png")
        XCTAssertEqual(try Data(contentsOf: second.fileURL), Data("second".utf8))
    }

    func test_writeAttachmentSanitizesUnsafeFilename() throws {
        var settings = AppSettings()
        settings.attachmentFolderPath = "Media"
        let writer = AttachmentWriter(vault: vaultURL, settings: settings)
        let noteURL = vaultURL.appending(path: "Inbox/Note.md")

        let result = try writer.write(AttachmentWriteRequest(
            filename: "../bad:name?.png",
            data: Data("image".utf8),
            noteURL: noteURL
        ))

        XCTAssertEqual(result.vaultRelativePath, "Media/bad-name-.png")
    }
}
