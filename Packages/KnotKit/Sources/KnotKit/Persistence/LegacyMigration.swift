import CryptoKit
import Foundation

public struct LegacyMigrationReport: Codable, Equatable, Sendable {
    public let sourceHash: String
    public let backupURL: URL
    public let recoveredCount: Int
    public let malformedCount: Int
    public let alreadyMigratedCount: Int
}

public struct LegacyQueueMigrator: Sendable {
    private let store: CaptureStore
    private let applicationSupportDirectory: URL

    public init(store: CaptureStore, applicationSupportDirectory: URL) {
        self.store = store
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    public func migrate(queueURL: URL) async throws -> LegacyMigrationReport {
        let source = try Data(contentsOf: queueURL, options: [.mappedIfSafe])
        let hash = Self.sha256(source)
        let backupDirectory = applicationSupportDirectory
            .appending(path: "migration-backups/legacy-queue-\(hash)", directoryHint: .isDirectory)
        let backup = backupDirectory.appending(path: "knot-queue.jsonl")
        try FileManager.default.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !FileManager.default.fileExists(atPath: backup.path) {
            try source.write(to: backup, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        guard try Data(contentsOf: backup) == source else {
            throw CaptureStoreError.backupVerificationFailed
        }

        var recovered = 0
        var malformed = 0
        var duplicates = 0
        var offset = 0
        for line in Self.linesWithOffsets(source) {
            defer { offset = line.nextOffset }
            guard !line.bytes.isEmpty else { continue }
            let key = "\(hash):\(offset)"
            let before = try await store.quarantinedRecordCount()
            let valid = Self.isLegacyNote(line.bytes)
            try await store.quarantine(
                sourceName: queueURL.lastPathComponent,
                byteOffset: offset,
                rawBytes: line.bytes,
                errorCode: valid ? "legacyRequiresAssignment" : "malformedLegacyQueue",
                migrationKey: key
            )
            let after = try await store.quarantinedRecordCount()
            if after == before {
                duplicates += 1
            } else if valid {
                recovered += 1
            } else {
                malformed += 1
            }
        }
        return LegacyMigrationReport(
            sourceHash: hash,
            backupURL: backup,
            recoveredCount: recovered,
            malformedCount: malformed,
            alreadyMigratedCount: duplicates
        )
    }

    private static func isLegacyNote(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["id"] is String &&
            object["content"] is String &&
            object["mode"] is String &&
            object["createdAt"] != nil
    }

    private static func linesWithOffsets(_ data: Data) -> [(bytes: Data, nextOffset: Int)] {
        var result: [(Data, Int)] = []
        var start = 0
        for index in data.indices where data[index] == 10 {
            var end = index
            if end > start, data[end - 1] == 13 { end -= 1 }
            result.append((Data(data[start..<end]), index + 1))
            start = index + 1
        }
        if start < data.count { result.append((Data(data[start..<data.count]), data.count)) }
        return result
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
