import Foundation

/// Creates a new file in the inbox folder for a longer note. Filename is
/// `<datePrefix> - <slug>.md`; collisions are resolved by appending a counter.
public struct InboxWriter: Sendable {
    public let vault: URL
    public let settings: AppSettings

    public init(vault: URL, settings: AppSettings) {
        self.vault = vault
        self.settings = settings
    }

    @discardableResult
    public func write(_ note: Note) throws -> URL {
        let folder = vault.appending(path: settings.inboxFolder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = settings.inboxFilenameFormat
        let prefix = formatter.string(from: note.createdAt)
        let slug = Slug.from(note.content)

        var fileURL = folder.appending(path: filename(prefix: prefix, slug: slug, counter: 0))
        var counter = 1
        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = folder.appending(path: filename(prefix: prefix, slug: slug, counter: counter))
            counter += 1
        }

        var coordError: NSError?
        var thrown: Error?
        var resultURL: URL?

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: fileURL,
            options: .forReplacing,
            error: &coordError
        ) { url in
            do {
                try note.content.write(to: url, atomically: true, encoding: .utf8)
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

    private func filename(prefix: String, slug: String, counter: Int) -> String {
        let base = slug.isEmpty ? prefix : "\(prefix) - \(slug)"
        let suffix = counter == 0 ? "" : " (\(counter))"
        return base + suffix + ".md"
    }
}
