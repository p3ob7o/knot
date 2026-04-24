import Foundation

/// Errors raised while writing to the vault.
public enum VaultError: Error, LocalizedError {
    case noVaultConfigured
    case accessDenied
    case coordinationFailed
    case emptyContent

    public var errorDescription: String? {
        switch self {
        case .noVaultConfigured:
            return "No vault folder is configured. Pick one in Settings."
        case .accessDenied:
            return "Could not access the vault folder. Re-pick it in Settings."
        case .coordinationFailed:
            return "File coordination failed."
        case .emptyContent:
            return "The note is empty."
        }
    }
}

/// High-level handle to the vault folder. Manages security-scoped resource
/// access automatically when writing.
public final class Vault: @unchecked Sendable {
    public let url: URL
    public let settings: AppSettings

    public init(url: URL, settings: AppSettings) {
        self.url = url
        self.settings = settings
    }

    /// Routes `note` to either the daily file or a new inbox file and returns
    /// the URL of the file that was created or modified.
    @discardableResult
    public func write(note: Note) throws -> URL {
        let trimmed = note.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw VaultError.emptyContent }

        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }

        // Use the trimmed content for the actual write so we don't carry
        // surrounding whitespace into the file.
        let cleaned = Note(
            id: note.id,
            content: trimmed,
            mode: note.mode,
            createdAt: note.createdAt
        )

        switch cleaned.mode {
        case .daily:
            return try DailyAppender(vault: url, settings: settings).append(cleaned)
        case .inbox:
            return try InboxWriter(vault: url, settings: settings).write(cleaned)
        }
    }
}
