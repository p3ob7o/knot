import Foundation

/// Appends a new bullet to today's daily note under the configured heading.
/// Reads, modifies, and writes the file inside a single `NSFileCoordinator`
/// block so concurrent presenters (Obsidian, Obsidian Sync) coordinate
/// correctly.
public struct DailyAppender: Sendable {
    public let vault: URL
    public let settings: AppSettings

    public init(vault: URL, settings: AppSettings) {
        self.vault = vault
        self.settings = settings
    }

    /// Appends `note.content` to the appropriate daily file and returns the
    /// resolved file URL.
    @discardableResult
    public func append(_ note: Note) throws -> URL {
        let dailyRoot = vault.appending(path: settings.dailyFolder, directoryHint: .isDirectory)

        // The filename pattern may itself contain `/` (e.g. `YYYY/MM/YYYY-MM-DD`)
        // which means we need to make sure the file's parent directory exists,
        // not just `dailyFolder`.
        let relativePath = MomentFormat.string(
            from: note.createdAt,
            format: settings.dailyFilenameFormat
        ) + ".md"
        let fileURL = dailyRoot.appending(path: relativePath)
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let bullet = BulletTemplate.render(
            template: settings.dailyBulletFormat,
            content: note.content,
            date: note.createdAt
        )

        var coordError: NSError?
        var resultURL: URL?
        var thrown: Error?

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: fileURL,
            options: [],
            error: &coordError
        ) { url in
            do {
                let existing: String
                if FileManager.default.fileExists(atPath: url.path) {
                    existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                } else {
                    existing = ""
                }
                let splicer = HeadingSplicer(heading: settings.dailyHeading)
                let updated = splicer.append(bullet: bullet, to: existing)
                try updated.write(to: url, atomically: true, encoding: .utf8)
                resultURL = url
            } catch {
                thrown = error
            }
        }

        if let coordError { throw coordError }
        if let thrown { throw thrown }
        guard let resultURL else {
            throw VaultError.coordinationFailed
        }
        return resultURL
    }
}
