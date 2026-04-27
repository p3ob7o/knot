import Foundation
import os

/// The daily-note configuration discovered inside an Obsidian vault.
public struct ImportedDailyConfig: Equatable, Sendable {
    /// Folder relative to the vault root. Empty string means vault root.
    public let folder: String
    /// Moment.js pattern (without `.md`).
    public let filenameFormat: String
    public let source: Source

    public enum Source: String, Equatable, Sendable, Codable {
        case periodicNotes
        case coreDailyNotes
    }

    public init(folder: String, filenameFormat: String, source: Source) {
        self.folder = folder
        self.filenameFormat = filenameFormat
        self.source = source
    }
}

/// Reads the active daily-note configuration out of an Obsidian vault.
///
/// Resolution chain:
/// 1. Periodic Notes (community plugin) when listed in
///    `.obsidian/community-plugins.json` and its `data.json` has
///    `daily.enabled == true` with a non-empty `daily.format`.
/// 2. Core Daily Notes plugin when `.obsidian/daily-notes.json` parses.
///    A missing or empty `format` falls back to `"YYYY-MM-DD"`.
/// 3. `nil` otherwise — the caller keeps its defaults.
///
/// All file I/O goes through `NSFileCoordinator`. Every failure mode
/// (missing file, malformed JSON, permission denial) collapses to `nil`.
public enum ObsidianConfigImporter {

    private static let logger = Logger(
        subsystem: "com.twf.knot",
        category: "ObsidianConfigImporter"
    )
    private static let defaultFormat = "YYYY-MM-DD"

    public static func read(vaultURL: URL) -> ImportedDailyConfig? {
        let didStart = vaultURL.startAccessingSecurityScopedResource()
        defer {
            if didStart { vaultURL.stopAccessingSecurityScopedResource() }
        }

        if let periodic = readPeriodicNotes(vaultURL: vaultURL) {
            return periodic
        }
        return readCoreDailyNotes(vaultURL: vaultURL)
    }

    // MARK: - Periodic Notes

    private struct PeriodicNotesFile: Decodable {
        let daily: Daily?
        struct Daily: Decodable {
            let enabled: Bool?
            let folder: String?
            let format: String?
        }
    }

    private static func readPeriodicNotes(vaultURL: URL) -> ImportedDailyConfig? {
        let pluginsURL = vaultURL.appending(path: ".obsidian/community-plugins.json")
        guard let pluginsData = readData(at: pluginsURL),
              let plugins = try? JSONDecoder().decode([String].self, from: pluginsData),
              plugins.contains("periodic-notes") else {
            return nil
        }

        let dataURL = vaultURL.appending(
            path: ".obsidian/plugins/periodic-notes/data.json"
        )
        guard let dataData = readData(at: dataURL) else { return nil }

        do {
            let parsed = try JSONDecoder().decode(PeriodicNotesFile.self, from: dataData)
            guard let daily = parsed.daily,
                  daily.enabled == true,
                  let format = daily.format,
                  !format.isEmpty else {
                return nil
            }
            return ImportedDailyConfig(
                folder: daily.folder ?? "",
                filenameFormat: format,
                source: .periodicNotes
            )
        } catch {
            logger.debug(
                "Periodic Notes data.json present but unparseable: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    // MARK: - Core Daily Notes

    private struct CoreDailyNotesFile: Decodable {
        let folder: String?
        let format: String?
    }

    private static func readCoreDailyNotes(vaultURL: URL) -> ImportedDailyConfig? {
        let url = vaultURL.appending(path: ".obsidian/daily-notes.json")
        guard let data = readData(at: url) else { return nil }

        do {
            let parsed = try JSONDecoder().decode(CoreDailyNotesFile.self, from: data)
            let resolvedFormat: String
            if let format = parsed.format, !format.isEmpty {
                resolvedFormat = format
            } else {
                resolvedFormat = defaultFormat
            }
            return ImportedDailyConfig(
                folder: parsed.folder ?? "",
                filenameFormat: resolvedFormat,
                source: .coreDailyNotes
            )
        } catch {
            logger.debug(
                "daily-notes.json present but unparseable: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    // MARK: - File coordination

    /// Reads `url` through `NSFileCoordinator`. Returns nil if the file
    /// is missing, coordination fails, or the read errors out.
    private static func readData(at url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var coordError: NSError?
        var result: Data?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            readingItemAt: url,
            options: [],
            error: &coordError
        ) { coordURL in
            result = try? Data(contentsOf: coordURL)
        }
        if coordError != nil { return nil }
        return result
    }
}
