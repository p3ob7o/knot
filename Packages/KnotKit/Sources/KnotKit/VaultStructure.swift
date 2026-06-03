import Foundation

/// A folder inside an Obsidian vault. The vault root is represented by an
/// empty relative path.
public struct VaultFolder: Equatable, Sendable, Identifiable {
    public let path: String

    public var id: String { path }
    public var displayName: String { path.isEmpty ? "Vault root" : path }

    public init(path: String) {
        self.path = path
    }
}

/// A markdown heading discovered inside a note.
public struct MarkdownHeading: Equatable, Sendable, Identifiable {
    public let level: Int
    public let title: String
    public let raw: String

    public var id: String { raw }

    public init(level: Int, title: String, raw: String) {
        self.level = level
        self.title = title
        self.raw = raw
    }
}

/// Lightweight vault inspection helpers used by onboarding. The write paths
/// still live in `DailyAppender` and `InboxWriter`; this type only discovers
/// existing folders and headings.
public enum VaultStructure {
    /// Normalizes user-entered vault-relative folder paths. An empty result
    /// means the vault root.
    public static func normalizeFolderPath(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
        return parts.joined(separator: "/")
    }

    /// Resolves a vault-relative folder path, preserving the vault root for an
    /// empty path.
    public static func folderURL(in vaultURL: URL, path: String) -> URL {
        let normalized = normalizeFolderPath(path)
        guard !normalized.isEmpty else { return vaultURL }
        return vaultURL.appending(path: normalized, directoryHint: .isDirectory)
    }

    /// Lists folders in the vault for UI autocomplete. Hidden folders such as
    /// `.obsidian` are skipped; the root is always returned first.
    public static func folders(in vaultURL: URL, limit: Int = 500) -> [VaultFolder] {
        let didStart = vaultURL.startAccessingSecurityScopedResource()
        defer {
            if didStart { vaultURL.stopAccessingSecurityScopedResource() }
        }

        var discovered: [VaultFolder] = [VaultFolder(path: "")]
        guard limit > 1,
              let enumerator = FileManager.default.enumerator(
                at: vaultURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return discovered
        }

        for case let url as URL in enumerator {
            guard discovered.count < limit else { break }

            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                enumerator.skipDescendants()
                continue
            }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
            guard values?.isDirectory == true,
                  values?.isHidden != true,
                  let relative = relativePath(from: url, to: vaultURL),
                  !relative.isEmpty else {
                continue
            }

            discovered.append(VaultFolder(path: relative))
        }

        let sorted = discovered.dropFirst().sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        return [discovered[0]] + sorted
    }

    /// Lists only the immediate child folders of `parentPath`, avoiding a
    /// recursive scan of large or cloud-backed vaults.
    public static func childFolders(in vaultURL: URL, parentPath: String) -> [VaultFolder] {
        let didStart = vaultURL.startAccessingSecurityScopedResource()
        defer {
            if didStart { vaultURL.stopAccessingSecurityScopedResource() }
        }

        let parentURL = folderURL(in: vaultURL, path: parentPath)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        let parent = normalizeFolderPath(parentPath)
        return contents.compactMap { url -> VaultFolder? in
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { return nil }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
            guard values?.isDirectory == true,
                  values?.isHidden != true else {
                return nil
            }
            let path = parent.isEmpty ? name : parent + "/" + name
            return VaultFolder(path: path)
        }.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    /// Builds the URL for a daily note using the same folder and filename
    /// settings that `DailyAppender` uses when writing.
    public static func dailyNoteURL(
        in vaultURL: URL,
        settings: AppSettings,
        date: Date = Date()
    ) -> URL {
        let dailyRoot = folderURL(in: vaultURL, path: settings.dailyFolder)
        let relativePath = MomentFormat.string(
            from: date,
            format: settings.dailyFilenameFormat
        ) + ".md"
        return dailyRoot.appending(path: relativePath)
    }

    /// Reads markdown headings from a note. Missing or unreadable files simply
    /// return no headings so onboarding can skip the header step.
    public static func markdownHeadings(in noteURL: URL) -> [MarkdownHeading] {
        guard FileManager.default.fileExists(atPath: noteURL.path),
              let contents = readString(at: noteURL) else {
            return []
        }

        return contents.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let level = HeadingSplicer.headingLevel(of: trimmed) else {
                return nil
            }
            let title = trimmed
                .dropFirst(level)
                .trimmingCharacters(in: .whitespaces)
            return MarkdownHeading(level: level, title: title, raw: trimmed)
        }
    }

    /// Reads headings from the daily note while holding access to the vault
    /// root bookmark.
    public static func dailyNoteHeadings(
        in vaultURL: URL,
        settings: AppSettings,
        date: Date = Date()
    ) -> [MarkdownHeading] {
        let didStart = vaultURL.startAccessingSecurityScopedResource()
        defer {
            if didStart { vaultURL.stopAccessingSecurityScopedResource() }
        }
        let noteURL = dailyNoteURL(in: vaultURL, settings: settings, date: date)
        return markdownHeadings(in: noteURL)
    }

    // MARK: - Helpers

    private static func relativePath(from descendant: URL, to ancestor: URL) -> String? {
        let ancestorComponents = ancestor.standardizedFileURL.pathComponents
        let descendantComponents = descendant.standardizedFileURL.pathComponents
        guard descendantComponents.count > ancestorComponents.count,
              descendantComponents.prefix(ancestorComponents.count) == ancestorComponents[...] else {
            return nil
        }
        return descendantComponents
            .dropFirst(ancestorComponents.count)
            .joined(separator: "/")
    }

    private static func readString(at url: URL) -> String? {
        var coordError: NSError?
        var contents: String?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { coordURL in
            contents = try? String(contentsOf: coordURL, encoding: .utf8)
        }
        if coordError != nil { return nil }
        return contents
    }
}
