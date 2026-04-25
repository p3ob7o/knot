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
        let formattedBase = MomentFormat.string(
            from: note.createdAt,
            format: settings.inboxFilenameFormat
        )

        // If the note opens with a short H1, swap the formatted leaf for
        // that title and strip the heading line from the body. Any
        // subfolders the format produced (`YYYY/MM/...`) are preserved.
        let baseName: String
        let bodyToWrite: String
        if let extracted = TitleExtractor.extract(from: note.content) {
            baseName = composeBase(subfolders: subfolderPath(of: formattedBase), leaf: extracted.filename)
            bodyToWrite = extracted.strippedBody
        } else {
            baseName = formattedBase
            bodyToWrite = note.content
        }

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
                try bodyToWrite.write(to: url, atomically: true, encoding: .utf8)
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

    /// Returns the leading slash-separated subfolders produced by the
    /// configured Inbox filename format, e.g. `"2026/04"` for a format of
    /// `YYYY/MM/YYYY-MM-DD HHmm`. Empty when the format has no `/`.
    private func subfolderPath(of formatted: String) -> String {
        let parts = formatted.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard parts.count > 1 else { return "" }
        return parts.dropLast().joined(separator: "/")
    }

    private func composeBase(subfolders: String, leaf: String) -> String {
        if subfolders.isEmpty { return leaf }
        return subfolders + "/" + leaf
    }

    private func filename(base: String, counter: Int) -> String {
        let safeBase = base.isEmpty ? "Untitled" : base
        let suffix = counter == 0 ? "" : " (\(counter))"
        return safeBase + suffix + ".md"
    }
}
