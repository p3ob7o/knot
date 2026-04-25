import Foundation

/// Creates a new file in the inbox folder for a longer note. Filename is
/// the Moment-formatted string from `inboxFilenameFormat` plus `.md`.
/// Collisions are resolved by appending ` (N)` before the extension.
public struct InboxWriter: Sendable {
    public let vault: URL
    public let settings: AppSettings

    public init(vault: URL, settings: AppSettings) {
        self.vault = vault
        self.settings = settings
    }

    @discardableResult
    public func write(_ note: Note) throws -> URL {
        let inboxRoot = vault.appending(path: settings.inboxFolder, directoryHint: .isDirectory)

        // The Moment-formatted filename may contain `/` to nest into
        // subfolders; we resolve the full URL first, then create whatever
        // intermediate directories the format demands.
        let baseName = MomentFormat.string(
            from: note.createdAt,
            format: settings.inboxFilenameFormat
        )

        var fileURL = inboxRoot.appending(path: filename(base: baseName, counter: 0))
        var counter = 1
        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = inboxRoot.appending(path: filename(base: baseName, counter: counter))
            counter += 1
        }
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

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

    private func filename(base: String, counter: Int) -> String {
        let safeBase = base.isEmpty ? "Untitled" : base
        let suffix = counter == 0 ? "" : " (\(counter))"
        return safeBase + suffix + ".md"
    }
}
