import Foundation

public extension ValidatedSettings {
    func applying(imported: ImportedVaultConfiguration) throws -> (ValidatedSettings, ConfigDiff) {
        var entries: [ConfigDiffEntry] = []
        var dailyFolder = dailyFolder.string
        var dailyFormat = dailyFilenameFormat
        var attachment = attachmentFolderPath

        if let daily = imported.daily, daily.automaticAdoptionAllowed {
            do {
                _ = try VaultRelativePath(daily.folder, kind: .folder)
                _ = try CompiledDatePattern(daily.filenameFormat)
                entries.append(.init(field: .dailyFolder, source: daily.source.rawValue, oldValue: dailyFolder, proposedValue: daily.folder))
                entries.append(.init(field: .dailyFilenameFormat, source: daily.source.rawValue, oldValue: dailyFormat, proposedValue: daily.filenameFormat))
                dailyFolder = daily.folder
                dailyFormat = daily.filenameFormat
            } catch {
                throw ConfigurationError.invalidImport(field: .dailyFilenameFormat, reason: String(describing: error))
            }
        }
        if let importedAttachment = imported.attachment {
            do {
                _ = try AttachmentDestination(obsidianValue: importedAttachment.value)
                entries.append(.init(field: .attachmentFolderPath, source: "obsidian.app", oldValue: attachment, proposedValue: importedAttachment.value))
                attachment = importedAttachment.value
            } catch {
                throw ConfigurationError.invalidImport(field: .attachmentFolderPath, reason: String(describing: error))
            }
        }

        let value = try ValidatedSettings(
            dailyFolder: dailyFolder,
            inboxFolder: inboxFolder.string,
            dailyFilenameFormat: dailyFormat,
            inboxFilenameFormat: inboxFilenameFormat,
            dailyTarget: dailyTarget,
            dailyBulletFormat: dailyBulletFormat,
            routingMaxChars: routingMaxChars,
            routingRequiresSingleLine: routingRequiresSingleLine,
            attachmentFolderPath: attachment
        )
        return (value, ConfigDiff(vaultID: nil, baseRevision: .zero, entries: entries))
    }

    func undoing(_ diff: ConfigDiff) throws -> ValidatedSettings {
        var dailyFolder = dailyFolder.string
        var dailyFormat = dailyFilenameFormat
        var attachment = attachmentFolderPath
        for entry in diff.entries {
            switch entry.field {
            case .dailyFolder where dailyFolder == entry.proposedValue:
                dailyFolder = entry.oldValue
            case .dailyFilenameFormat where dailyFormat == entry.proposedValue:
                dailyFormat = entry.oldValue
            case .attachmentFolderPath where attachment == entry.proposedValue:
                attachment = entry.oldValue
            default:
                continue
            }
        }
        return try ValidatedSettings(
            dailyFolder: dailyFolder,
            inboxFolder: inboxFolder.string,
            dailyFilenameFormat: dailyFormat,
            inboxFilenameFormat: inboxFilenameFormat,
            dailyTarget: dailyTarget,
            dailyBulletFormat: dailyBulletFormat,
            routingMaxChars: routingMaxChars,
            routingRequiresSingleLine: routingRequiresSingleLine,
            attachmentFolderPath: attachment
        )
    }
}
