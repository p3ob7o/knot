import Foundation

public struct AttachmentWriteRequest: Sendable, Equatable {
    public let filename: String
    public let data: Data
    public let noteURL: URL

    public init(filename: String, data: Data, noteURL: URL) {
        self.filename = filename
        self.data = data
        self.noteURL = noteURL
    }
}

public struct AttachmentWriteResult: Sendable, Equatable {
    public let fileURL: URL
    public let vaultRelativePath: String
    public let markdownEmbed: String

    public init(fileURL: URL, vaultRelativePath: String, markdownEmbed: String) {
        self.fileURL = fileURL
        self.vaultRelativePath = vaultRelativePath
        self.markdownEmbed = markdownEmbed
    }
}

public struct AttachmentWriter: Sendable {
    public let vault: URL
    public let settings: AppSettings

    public init(vault: URL, settings: AppSettings) {
        self.vault = vault
        self.settings = settings
    }

    @discardableResult
    public func write(_ request: AttachmentWriteRequest) throws -> AttachmentWriteResult {
        let folderURL = try attachmentFolderURL(for: request.noteURL)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let safeName = sanitizedFilename(request.filename)
        var fileURL = folderURL.appending(path: filename(base: safeName, counter: 0))
        var counter = 1
        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = folderURL.appending(path: filename(base: safeName, counter: counter))
            counter += 1
        }

        var coordError: NSError?
        var thrown: Error?
        var wroteURL: URL?

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: fileURL,
            options: .forReplacing,
            error: &coordError
        ) { url in
            do {
                try request.data.write(to: url, options: [.atomic])
                wroteURL = url
            } catch {
                thrown = error
            }
        }

        if let coordError { throw coordError }
        if let thrown { throw thrown }
        guard let wroteURL else { throw VaultError.coordinationFailed }
        guard let relative = vaultRelativePath(for: wroteURL) else {
            throw VaultError.accessDenied
        }

        return AttachmentWriteResult(
            fileURL: wroteURL,
            vaultRelativePath: relative,
            markdownEmbed: "![[\(relative)]]"
        )
    }

    private func attachmentFolderURL(for noteURL: URL) throws -> URL {
        let raw = settings.attachmentFolderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let folderURL: URL

        if raw.isEmpty || raw == "/" {
            folderURL = vault
        } else if raw == "." || raw == "./" {
            folderURL = noteURL.deletingLastPathComponent()
        } else if raw.hasPrefix("./") {
            let relative = String(raw.dropFirst(2))
            folderURL = VaultStructure.folderURL(
                in: noteURL.deletingLastPathComponent(),
                path: relative
            )
        } else if raw.hasPrefix("/") {
            folderURL = VaultStructure.folderURL(in: vault, path: String(raw.dropFirst()))
        } else {
            folderURL = VaultStructure.folderURL(in: vault, path: raw)
        }

        guard isInsideVault(folderURL) else {
            throw VaultError.accessDenied
        }
        return folderURL
    }

    private func sanitizedFilename(_ filename: String) -> String {
        let leaf = filename
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init) ?? "Attachment"

        let invalid = CharacterSet(charactersIn: ":?*\"<>|\0")
        let cleanedScalars = leaf.unicodeScalars.map { scalar -> UnicodeScalar in
            if invalid.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
                return "-"
            }
            return scalar
        }
        let cleaned = String(String.UnicodeScalarView(cleanedScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.isEmpty ? "Attachment" : cleaned
    }

    private func filename(base safeName: String, counter: Int) -> String {
        guard counter > 0 else { return safeName }
        let url = URL(fileURLWithPath: safeName)
        let ext = url.pathExtension
        let stem = ext.isEmpty ? safeName : String(safeName.dropLast(ext.count + 1))
        if ext.isEmpty {
            return "\(stem) (\(counter))"
        }
        return "\(stem) (\(counter)).\(ext)"
    }

    private func vaultRelativePath(for url: URL) -> String? {
        let vaultComponents = vault.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        guard urlComponents.count >= vaultComponents.count,
              urlComponents.prefix(vaultComponents.count) == vaultComponents[...] else {
            return nil
        }
        return urlComponents
            .dropFirst(vaultComponents.count)
            .joined(separator: "/")
    }

    private func isInsideVault(_ url: URL) -> Bool {
        let vaultComponents = vault.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        return urlComponents.count >= vaultComponents.count &&
            urlComponents.prefix(vaultComponents.count) == vaultComponents[...]
    }
}
