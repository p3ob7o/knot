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
        let folder = vault.appending(path: settings.dailyFolder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let filenameFormatter = DateFormatter()
        filenameFormatter.locale = Locale(identifier: "en_US_POSIX")
        filenameFormatter.timeZone = .current
        filenameFormatter.dateFormat = settings.dailyFilenameFormat
        let filename = filenameFormatter.string(from: note.createdAt) + ".md"
        let fileURL = folder.appending(path: filename)

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = .current
        timeFormatter.dateFormat = "HH:mm"
        let bullet = settings.dailyBulletFormat
            .replacingOccurrences(of: "{{HH:mm}}", with: timeFormatter.string(from: note.createdAt))
            .replacingOccurrences(of: "{{content}}", with: note.content)

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
