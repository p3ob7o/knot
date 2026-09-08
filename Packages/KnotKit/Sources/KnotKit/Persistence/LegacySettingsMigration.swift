import CryptoKit
import Foundation

public struct LegacySettingsMigrationReport: Codable, Equatable, Sendable {
    public let sourceHash: String
    public let backupURL: URL
    public let repairedFields: [String]
    public let settings: ValidatedSettings
}

public struct LegacySettingsMigrator: Sendable {
    private let applicationSupportDirectory: URL

    public init(applicationSupportDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    public func migrate(rawData: Data) throws -> LegacySettingsMigrationReport {
        let hash = SHA256.hash(data: rawData).map { String(format: "%02x", $0) }.joined()
        let directory = applicationSupportDirectory
            .appending(path: "migration-backups/legacy-settings-\(hash)", directoryHint: .isDirectory)
        let backup = directory.appending(path: "knot.settings.json")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !FileManager.default.fileExists(atPath: backup.path) {
            try rawData.write(to: backup, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        guard try Data(contentsOf: backup) == rawData else { throw CaptureStoreError.backupVerificationFailed }

        let object = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any]
        var value = AppSettings()
        var repaired: [String] = []
        func string(_ key: String, _ apply: (inout AppSettings, String) -> Void) {
            guard let candidate = object?[key] as? String else {
                if object?[key] != nil { repaired.append(key) }
                return
            }
            var proposed = value
            apply(&proposed, candidate)
            if (try? proposed.validated()) != nil { value = proposed } else { repaired.append(key) }
        }
        string("dailyFolder") { $0.dailyFolder = $1 }
        string("inboxFolder") { $0.inboxFolder = $1 }
        string("dailyFilenameFormat") { $0.dailyFilenameFormat = $1 == "yyyy-MM-dd" ? "YYYY-MM-DD" : $1 }
        string("inboxFilenameFormat") { $0.inboxFilenameFormat = $1 == "yyyy-MM-dd HHmm" ? "YYYY-MM-DD HHmm" : $1 }
        string("dailyHeading") { $0.dailyHeading = $1 }
        string("dailyBulletFormat") { $0.dailyBulletFormat = $1 }
        string("attachmentFolderPath") { $0.attachmentFolderPath = $1 }
        if let number = object?["routingMaxChars"] as? NSNumber {
            var proposed = value
            proposed.routingMaxChars = number.intValue
            if (try? proposed.validated()) != nil { value = proposed } else { repaired.append("routingMaxChars") }
        } else if object?["routingMaxChars"] != nil { repaired.append("routingMaxChars") }
        if let flag = object?["routingRequiresSingleLine"] as? Bool {
            value.routingRequiresSingleLine = flag
        } else if object?["routingRequiresSingleLine"] != nil { repaired.append("routingRequiresSingleLine") }

        if object == nil { repaired.append("root") }
        return LegacySettingsMigrationReport(
            sourceHash: hash,
            backupURL: backup,
            repairedFields: repaired.sorted(),
            settings: try value.validated()
        )
    }
}
