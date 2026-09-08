import Foundation
import GRDB

public enum PersistenceOperation: String, Sendable {
    case migrate
    case checkpoint
    case enqueue
    case transition
    case journal
    case receipt
    case asset
    case legacyMigration
}

public struct PersistenceFaultInjector: Sendable {
    private let body: @Sendable (PersistenceOperation) throws -> Void

    public init(_ body: @escaping @Sendable (PersistenceOperation) throws -> Void = { _ in }) {
        self.body = body
    }

    func check(_ operation: PersistenceOperation) throws { try body(operation) }
    public static let none = PersistenceFaultInjector()
}

public enum CaptureStoreError: Error, Equatable, LocalizedError, Sendable {
    case storageUnavailable(String)
    case revisionConflict(current: Revision)
    case draftMissing
    case profileMissing
    case captureMissing
    case assetMissing
    case illegalTransition(from: CaptureState, to: CaptureState)
    case corruptRecord
    case backupVerificationFailed

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable: "Knot cannot access durable local storage."
        case .revisionConflict: "A newer draft revision is already stored."
        case .draftMissing: "The draft no longer exists."
        case .profileMissing: "The vault profile no longer exists."
        case .captureMissing: "The pending capture no longer exists."
        case .assetMissing: "A referenced attachment is missing."
        case .illegalTransition(let from, let to): "Illegal capture transition from \(from.rawValue) to \(to.rawValue)."
        case .corruptRecord: "A stored record could not be decoded."
        case .backupVerificationFailed: "The migration backup could not be verified."
        }
    }
}

public struct DraftCheckpoint: Codable, Equatable, Sendable {
    public let id: DraftID
    public let profileID: VaultID?
    public let revision: Revision
    public let representationVersion: Int
    public let markdown: Data
    public let blocksJSON: Data?
    public let opaqueSourcesJSON: Data?
    public let routingChoice: RoutingChoice
    public let selectedRangeJSON: Data?
    public let updatedAt: Date
    public let state: DraftState

    public init(
        id: DraftID,
        profileID: VaultID?,
        revision: Revision,
        representationVersion: Int = 1,
        markdown: Data,
        blocksJSON: Data? = nil,
        opaqueSourcesJSON: Data? = nil,
        routingChoice: RoutingChoice = .automatic,
        selectedRangeJSON: Data? = nil,
        updatedAt: Date = Date(),
        state: DraftState = .active
    ) throws {
        guard markdown.count <= CaptureDocument.maximumMarkdownBytes else {
            throw DomainValidationError.documentTooLarge
        }
        self.id = id
        self.profileID = profileID
        self.revision = revision
        self.representationVersion = representationVersion
        self.markdown = markdown
        self.blocksJSON = blocksJSON
        self.opaqueSourcesJSON = opaqueSourcesJSON
        self.routingChoice = routingChoice
        self.selectedRangeJSON = selectedRangeJSON
        self.updatedAt = updatedAt
        self.state = state
    }
}

public struct StoredCapture: Equatable, Sendable {
    public let snapshot: CaptureSnapshot
    public let state: CaptureState
    public let attemptCount: Int
    public let nextAttemptAt: Date?
    public let lastErrorCode: String?
    public let committedAt: Date?
}

public enum MutationKind: String, Codable, Sendable {
    case asset
    case note
}

public enum MutationPhase: String, Codable, Sendable {
    case planned
    case temporaryWritten
    case published
}

public struct MutationRecord: Codable, Equatable, Sendable {
    public let operationID: OperationID
    public let sequence: Int
    public let captureID: CaptureID
    public let kind: MutationKind
    public let relativeTarget: VaultRelativePath
    public let beforeHash: String?
    public let afterHash: String
    public let beforeBlob: Data?
    public let afterBlob: Data
    public let phase: MutationPhase
    public let publishedResourceID: Data?

    public init(
        operationID: OperationID,
        sequence: Int,
        captureID: CaptureID,
        kind: MutationKind,
        relativeTarget: VaultRelativePath,
        beforeHash: String?,
        afterHash: String,
        beforeBlob: Data?,
        afterBlob: Data,
        phase: MutationPhase = .planned,
        publishedResourceID: Data? = nil
    ) {
        self.operationID = operationID
        self.sequence = sequence
        self.captureID = captureID
        self.kind = kind
        self.relativeTarget = relativeTarget
        self.beforeHash = beforeHash
        self.afterHash = afterHash
        self.beforeBlob = beforeBlob
        self.afterBlob = afterBlob
        self.phase = phase
        self.publishedResourceID = publishedResourceID
    }
}

public struct CaptureReceipt: Codable, Equatable, Sendable {
    public let captureID: CaptureID
    public let noteRelativePath: VaultRelativePath
    public let noteHashAtCommit: String
    public let committedAt: Date
    public let assetResultsJSON: Data

    public init(
        captureID: CaptureID,
        noteRelativePath: VaultRelativePath,
        noteHashAtCommit: String,
        committedAt: Date = Date(),
        assetResultsJSON: Data = Data("[]".utf8)
    ) {
        self.captureID = captureID
        self.noteRelativePath = noteRelativePath
        self.noteHashAtCommit = noteHashAtCommit
        self.committedAt = committedAt
        self.assetResultsJSON = assetResultsJSON
    }
}

public struct AssetMetadata: Codable, Equatable, Sendable {
    public let id: AssetID
    public let localRelativePath: String
    public let originalName: String
    public let mediaType: String
    public let byteCount: Int
    public let sha256: String
    public let width: Int?
    public let height: Int?

    public init(
        id: AssetID,
        localRelativePath: String,
        originalName: String,
        mediaType: String,
        byteCount: Int,
        sha256: String,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.id = id
        self.localRelativePath = localRelativePath
        self.originalName = originalName
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.width = width
        self.height = height
    }
}

public struct VaultProfileRecord: Equatable, Sendable {
    public let id: VaultID
    public let displayName: String
    public let bookmark: Data
    public let resourceIdentity: Data?
    public let settingsRevision: Revision
    public let settings: ValidatedSettings
    public let onboardingState: String

    public init(
        id: VaultID,
        displayName: String,
        bookmark: Data,
        resourceIdentity: Data?,
        settingsRevision: Revision,
        settings: ValidatedSettings,
        onboardingState: String
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmark = bookmark
        self.resourceIdentity = resourceIdentity
        self.settingsRevision = settingsRevision
        self.settings = settings
        self.onboardingState = onboardingState
    }
}

public actor CaptureStore {
    public static let databaseFilename = "captures.sqlite"
    public static let schemaVersion = 1

    let database: DatabaseQueue
    let rootDirectory: URL
    let encoder: JSONEncoder
    let decoder: JSONDecoder
    private let faults: PersistenceFaultInjector

    public init(directory: URL, faults: PersistenceFaultInjector = .none) throws {
        self.rootDirectory = directory
        self.faults = faults
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            for name in ["assets", "staging", "migration-backups"] {
                try FileManager.default.createDirectory(
                    at: directory.appending(path: name, directoryHint: .isDirectory),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try faults.check(.migrate)
            var configuration = Configuration()
            configuration.label = "Knot CaptureStore"
            configuration.busyMode = .timeout(5)
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA foreign_keys = ON")
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                try db.execute(sql: "PRAGMA synchronous = FULL")
            }
            let path = directory.appending(path: Self.databaseFilename).path
            database = try DatabaseQueue(path: path, configuration: configuration)
            try Self.migrator().migrate(database)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            throw CaptureStoreError.storageUnavailable(String(describing: type(of: error)))
        }
    }

    public static func applicationSupportDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appending(path: "Knot", directoryHint: .isDirectory)
    }

    public func createProfile(
        id: VaultID = VaultID(),
        displayName: String,
        bookmark: Data,
        resourceIdentity: Data? = nil,
        settings: ValidatedSettings,
        settingsRevision: Revision = .zero,
        onboardingState: String = "incomplete",
        now: Date = Date()
    ) throws -> VaultID {
        let settingsData = try encoder.encode(settings)
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO vault_profiles
                    (id, display_name, bookmark, resource_identity, settings_version,
                     settings_revision, settings_json, onboarding_state, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    display_name = excluded.display_name,
                    bookmark = excluded.bookmark,
                    resource_identity = excluded.resource_identity,
                    settings_version = excluded.settings_version,
                    settings_revision = excluded.settings_revision,
                    settings_json = excluded.settings_json,
                    onboarding_state = excluded.onboarding_state,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    id.description, displayName, bookmark, resourceIdentity,
                    ValidatedSettings.schemaVersion, settingsRevision.rawValue,
                    settingsData, onboardingState, now.timeIntervalSince1970,
                    now.timeIntervalSince1970
                ]
            )
        }
        return id
    }

    public func profile(id: VaultID) throws -> VaultProfileRecord? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM vault_profiles WHERE id = ?", arguments: [id.description]) else {
                return nil
            }
            return try decodeProfile(row)
        }
    }

    public func checkpointDraft(_ checkpoint: DraftCheckpoint) throws {
        try faults.check(.checkpoint)
        try database.write { db in
            if let current: Int64 = try Int64.fetchOne(
                db,
                sql: "SELECT revision FROM drafts WHERE id = ?",
                arguments: [checkpoint.id.description]
            ), current > checkpoint.revision.rawValue {
                throw CaptureStoreError.revisionConflict(current: try Revision(current))
            }
            try db.execute(
                sql: """
                INSERT INTO drafts
                    (id, profile_id, revision, representation_version, markdown,
                     blocks_json, opaque_sources_json, routing_choice,
                     selected_range_json, updated_at, state)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    profile_id = excluded.profile_id,
                    revision = excluded.revision,
                    representation_version = excluded.representation_version,
                    markdown = excluded.markdown,
                    blocks_json = excluded.blocks_json,
                    opaque_sources_json = excluded.opaque_sources_json,
                    routing_choice = excluded.routing_choice,
                    selected_range_json = excluded.selected_range_json,
                    updated_at = excluded.updated_at,
                    state = excluded.state
                """,
                arguments: [
                    checkpoint.id.description, checkpoint.profileID?.description,
                    checkpoint.revision.rawValue, checkpoint.representationVersion,
                    checkpoint.markdown, checkpoint.blocksJSON, checkpoint.opaqueSourcesJSON,
                    checkpoint.routingChoice.rawValue, checkpoint.selectedRangeJSON,
                    checkpoint.updatedAt.timeIntervalSince1970, checkpoint.state.rawValue
                ]
            )
        }
    }

    public func draft(id: DraftID) throws -> DraftCheckpoint? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM drafts WHERE id = ?", arguments: [id.description]) else {
                return nil
            }
            return try decodeDraft(row)
        }
    }

    @discardableResult
    public func enqueue(_ snapshot: CaptureSnapshot) throws -> CaptureID {
        try faults.check(.enqueue)
        let snapshotData = try encoder.encode(snapshot)
        return try database.write { db in
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM drafts WHERE id = ? AND revision = ?)",
                arguments: [snapshot.draftID.description, snapshot.draftRevision.rawValue]
            ) == true else {
                throw CaptureStoreError.draftMissing
            }
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM vault_profiles WHERE id = ?)",
                arguments: [snapshot.vaultID.description]
            ) == true else {
                throw CaptureStoreError.profileMissing
            }
            if let existing: String = try String.fetchOne(
                db,
                sql: "SELECT id FROM captures WHERE draft_id = ? AND draft_revision = ?",
                arguments: [snapshot.draftID.description, snapshot.draftRevision.rawValue]
            ), let uuid = UUID(uuidString: existing) {
                return CaptureID(rawValue: uuid)
            }
            for assetID in snapshot.assetIDs {
                guard try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM assets WHERE id = ? AND state = 'staged')",
                    arguments: [assetID.description]
                ) == true else {
                    throw CaptureStoreError.assetMissing
                }
            }
            try db.execute(
                sql: """
                INSERT INTO captures
                    (id, draft_id, draft_revision, profile_id, immutable_snapshot_json,
                     state, attempt_count, created_at)
                VALUES (?, ?, ?, ?, ?, 'pending', 0, ?)
                """,
                arguments: [
                    snapshot.id.description, snapshot.draftID.description,
                    snapshot.draftRevision.rawValue, snapshot.vaultID.description,
                    snapshotData, snapshot.createdAt.timeIntervalSince1970
                ]
            )
            for assetID in snapshot.assetIDs {
                try db.execute(
                    sql: "INSERT INTO capture_assets (owner_id, asset_id) VALUES (?, ?)",
                    arguments: [snapshot.id.description, assetID.description]
                )
            }
            try db.execute(
                sql: "UPDATE drafts SET state = 'captured' WHERE id = ? AND revision = ?",
                arguments: [snapshot.draftID.description, snapshot.draftRevision.rawValue]
            )
            return snapshot.id
        }
    }

    public func capture(id: CaptureID) throws -> StoredCapture? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM captures WHERE id = ?", arguments: [id.description]) else {
                return nil
            }
            return try decodeCapture(row)
        }
    }

    public func pendingCaptures(profileID: VaultID? = nil) throws -> [StoredCapture] {
        try database.read { db in
            let states = "('pending','preparing','committing','retryableFailure','waitingForVault','needsReview')"
            let rows: [Row]
            if let profileID {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM captures WHERE profile_id = ? AND state IN \(states) ORDER BY created_at, id",
                    arguments: [profileID.description]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM captures WHERE state IN \(states) ORDER BY created_at, id"
                )
            }
            return try rows.map(decodeCapture)
        }
    }

    public func claimNext(profileID: VaultID, now: Date = Date()) throws -> StoredCapture? {
        try faults.check(.transition)
        return try database.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM captures
                WHERE profile_id = ?
                  AND state IN ('pending','retryableFailure','waitingForVault')
                  AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
                ORDER BY created_at, id LIMIT 1
                """,
                arguments: [profileID.description, now.timeIntervalSince1970]
            ) else {
                return nil
            }
            let id: String = row["id"]
            try db.execute(
                sql: "UPDATE captures SET state = 'preparing', attempt_count = attempt_count + 1 WHERE id = ?",
                arguments: [id]
            )
            guard let updated = try Row.fetchOne(db, sql: "SELECT * FROM captures WHERE id = ?", arguments: [id]) else {
                throw CaptureStoreError.captureMissing
            }
            return try decodeCapture(updated)
        }
    }

    public func transition(
        captureID: CaptureID,
        to state: CaptureState,
        errorCode: String? = nil,
        nextAttemptAt: Date? = nil
    ) throws {
        try faults.check(.transition)
        try database.write { db in
            guard let raw: String = try String.fetchOne(
                db,
                sql: "SELECT state FROM captures WHERE id = ?",
                arguments: [captureID.description]
            ), let current = CaptureState(rawValue: raw) else {
                throw CaptureStoreError.captureMissing
            }
            guard Self.allowedTransitions[current, default: []].contains(state) else {
                throw CaptureStoreError.illegalTransition(from: current, to: state)
            }
            try db.execute(
                sql: "UPDATE captures SET state = ?, last_error_code = ?, next_attempt_at = ?, attempt_count = attempt_count + ? WHERE id = ?",
                arguments: [
                    state.rawValue, errorCode, nextAttemptAt?.timeIntervalSince1970,
                    state == .preparing ? 1 : 0, captureID.description
                ]
            )
        }
    }

    public func recordMutationPlan(_ records: [MutationRecord]) throws {
        try faults.check(.journal)
        guard !records.isEmpty else { return }
        try database.write { db in
            for record in records {
                try db.execute(
                    sql: """
                    INSERT INTO mutations
                        (operation_id, sequence, capture_id, kind, relative_target,
                         before_hash, after_hash, before_blob, after_blob, phase,
                         published_resource_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(operation_id, sequence) DO UPDATE SET
                        relative_target = excluded.relative_target,
                        before_hash = excluded.before_hash,
                        after_hash = excluded.after_hash,
                        before_blob = excluded.before_blob,
                        after_blob = excluded.after_blob
                    WHERE mutations.phase = 'planned'
                    """,
                    arguments: [
                        record.operationID.description, record.sequence,
                        record.captureID.description, record.kind.rawValue,
                        record.relativeTarget.string, record.beforeHash, record.afterHash,
                        record.beforeBlob, record.afterBlob, record.phase.rawValue,
                        record.publishedResourceID
                    ]
                )
            }
        }
    }

    public func markMutation(
        operationID: OperationID,
        sequence: Int,
        phase: MutationPhase,
        publishedResourceID: Data? = nil
    ) throws {
        try faults.check(.journal)
        try database.write { db in
            try db.execute(
                sql: "UPDATE mutations SET phase = ?, published_resource_id = ? WHERE operation_id = ? AND sequence = ?",
                arguments: [phase.rawValue, publishedResourceID, operationID.description, sequence]
            )
        }
    }

    public func mutations(captureID: CaptureID) throws -> [MutationRecord] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM mutations WHERE capture_id = ? ORDER BY sequence",
                arguments: [captureID.description]
            ).map(decodeMutation)
        }
    }

    public func storeReceipt(_ receipt: CaptureReceipt) throws {
        try faults.check(.receipt)
        try database.write { db in
            guard try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM captures WHERE id = ?)",
                arguments: [receipt.captureID.description]
            ) == true else {
                throw CaptureStoreError.captureMissing
            }
            try db.execute(
                sql: """
                INSERT INTO receipts
                    (capture_id, note_relative_path, note_hash_at_commit, committed_at, asset_results_json)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(capture_id) DO NOTHING
                """,
                arguments: [
                    receipt.captureID.description, receipt.noteRelativePath.string,
                    receipt.noteHashAtCommit, receipt.committedAt.timeIntervalSince1970,
                    receipt.assetResultsJSON
                ]
            )
            try db.execute(
                sql: "UPDATE captures SET state = 'committed', committed_at = ?, next_attempt_at = NULL, last_error_code = NULL WHERE id = ?",
                arguments: [receipt.committedAt.timeIntervalSince1970, receipt.captureID.description]
            )
        }
    }

    public func receipt(captureID: CaptureID) throws -> CaptureReceipt? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM receipts WHERE capture_id = ?",
                arguments: [captureID.description]
            ) else { return nil }
            guard let uuid = UUID(uuidString: row["capture_id"]) else {
                throw CaptureStoreError.corruptRecord
            }
            return try CaptureReceipt(
                captureID: CaptureID(rawValue: uuid),
                noteRelativePath: VaultRelativePath(row["note_relative_path"], kind: .file),
                noteHashAtCommit: row["note_hash_at_commit"],
                committedAt: Date(timeIntervalSince1970: row["committed_at"]),
                assetResultsJSON: row["asset_results_json"]
            )
        }
    }

    public func registerAsset(_ metadata: AssetMetadata) throws {
        try faults.check(.asset)
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO assets
                    (id, local_relative_path, original_name, media_type, byte_count,
                     sha256, width, height, state)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'staged')
                """,
                arguments: [
                    metadata.id.description, metadata.localRelativePath,
                    metadata.originalName, metadata.mediaType, metadata.byteCount,
                    metadata.sha256, metadata.width, metadata.height
                ]
            )
        }
    }

    public func asset(id: AssetID) throws -> AssetMetadata? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM assets WHERE id = ?", arguments: [id.description]) else {
                return nil
            }
            return try decodeAsset(row)
        }
    }

    public func linkDraftAsset(draftID: DraftID, assetID: AssetID) throws {
        try database.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO draft_assets (owner_id, asset_id) VALUES (?, ?)",
                arguments: [draftID.description, assetID.description]
            )
        }
    }

    public func quarantine(
        sourceName: String,
        byteOffset: Int,
        rawBytes: Data,
        errorCode: String,
        migrationKey: String? = nil
    ) throws {
        try database.write { db in
            if let migrationKey,
               try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM migration_records WHERE migration_key = ?)",
                arguments: [migrationKey]
               ) == true {
                return
            }
            try db.execute(
                sql: "INSERT INTO quarantined_records (id, source_name, byte_offset, raw_bytes, error_code) VALUES (?, ?, ?, ?, ?)",
                arguments: [UUID().uuidString, sourceName, byteOffset, rawBytes, errorCode]
            )
            if let migrationKey {
                try db.execute(
                    sql: "INSERT INTO migration_records (migration_key, source_hash, completed_at, report_json) VALUES (?, ?, ?, ?)",
                    arguments: [migrationKey, migrationKey.components(separatedBy: ":").first ?? migrationKey, Date().timeIntervalSince1970, Data("{}".utf8)]
                )
            }
        }
    }

    public func quarantinedRecordCount() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM quarantined_records") ?? 0
        }
    }

    func decodeProfile(_ row: Row) throws -> VaultProfileRecord {
        guard let uuid = UUID(uuidString: row["id"]) else { throw CaptureStoreError.corruptRecord }
        let settings: ValidatedSettings = try decoder.decode(ValidatedSettings.self, from: row["settings_json"])
        return VaultProfileRecord(
            id: VaultID(rawValue: uuid),
            displayName: row["display_name"],
            bookmark: row["bookmark"],
            resourceIdentity: row["resource_identity"],
            settingsRevision: try Revision(row["settings_revision"]),
            settings: settings,
            onboardingState: row["onboarding_state"]
        )
    }

    func decodeDraft(_ row: Row) throws -> DraftCheckpoint {
        guard let uuid = UUID(uuidString: row["id"]) else { throw CaptureStoreError.corruptRecord }
        let profileString: String? = row["profile_id"]
        return try DraftCheckpoint(
            id: DraftID(rawValue: uuid),
            profileID: profileString.flatMap(UUID.init(uuidString:)).map(VaultID.init(rawValue:)),
            revision: Revision(row["revision"]),
            representationVersion: row["representation_version"],
            markdown: row["markdown"],
            blocksJSON: row["blocks_json"],
            opaqueSourcesJSON: row["opaque_sources_json"],
            routingChoice: RoutingChoice(rawValue: row["routing_choice"]) ?? .automatic,
            selectedRangeJSON: row["selected_range_json"],
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            state: DraftState(rawValue: row["state"]) ?? .parked
        )
    }

    private func decodeCapture(_ row: Row) throws -> StoredCapture {
        guard let state = CaptureState(rawValue: row["state"]) else {
            throw CaptureStoreError.corruptRecord
        }
        let snapshot: CaptureSnapshot = try decoder.decode(CaptureSnapshot.self, from: row["immutable_snapshot_json"])
        let next: Double? = row["next_attempt_at"]
        let committed: Double? = row["committed_at"]
        return StoredCapture(
            snapshot: snapshot,
            state: state,
            attemptCount: row["attempt_count"],
            nextAttemptAt: next.map(Date.init(timeIntervalSince1970:)),
            lastErrorCode: row["last_error_code"],
            committedAt: committed.map(Date.init(timeIntervalSince1970:))
        )
    }

    private func decodeMutation(_ row: Row) throws -> MutationRecord {
        guard let operationUUID = UUID(uuidString: row["operation_id"]),
              let captureUUID = UUID(uuidString: row["capture_id"]),
              let kind = MutationKind(rawValue: row["kind"]),
              let phase = MutationPhase(rawValue: row["phase"]) else {
            throw CaptureStoreError.corruptRecord
        }
        return try MutationRecord(
            operationID: OperationID(rawValue: operationUUID),
            sequence: row["sequence"],
            captureID: CaptureID(rawValue: captureUUID),
            kind: kind,
            relativeTarget: VaultRelativePath(row["relative_target"], kind: .file),
            beforeHash: row["before_hash"],
            afterHash: row["after_hash"],
            beforeBlob: row["before_blob"],
            afterBlob: row["after_blob"],
            phase: phase,
            publishedResourceID: row["published_resource_id"]
        )
    }

    private func decodeAsset(_ row: Row) throws -> AssetMetadata {
        guard let uuid = UUID(uuidString: row["id"]) else { throw CaptureStoreError.corruptRecord }
        return AssetMetadata(
            id: AssetID(rawValue: uuid),
            localRelativePath: row["local_relative_path"],
            originalName: row["original_name"],
            mediaType: row["media_type"],
            byteCount: row["byte_count"],
            sha256: row["sha256"],
            width: row["width"],
            height: row["height"]
        )
    }

    private static let allowedTransitions: [CaptureState: Set<CaptureState>] = [
        .pending: [.preparing, .waitingForVault, .cancelled],
        .preparing: [.committing, .retryableFailure, .waitingForVault, .needsReview, .cancelled],
        .committing: [.committed, .retryableFailure, .waitingForVault, .needsReview],
        .retryableFailure: [.preparing, .waitingForVault, .cancelled],
        .waitingForVault: [.preparing, .retryableFailure, .cancelled],
        .needsReview: [.committed, .retryableFailure, .cancelled],
        .committed: [],
        .cancelled: []
    ]

    private static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("schema-v1") { db in
            try db.execute(sql: schemaSQL)
        }
        return migrator
    }

    private static let schemaSQL = """
    CREATE TABLE vault_profiles (
        id TEXT PRIMARY KEY NOT NULL,
        display_name TEXT NOT NULL,
        bookmark BLOB NOT NULL,
        resource_identity BLOB,
        settings_version INTEGER NOT NULL CHECK(settings_version > 0),
        settings_revision INTEGER NOT NULL CHECK(settings_revision >= 0),
        settings_json BLOB NOT NULL,
        onboarding_state TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE TABLE onboarding_sessions (
        id TEXT PRIMARY KEY NOT NULL,
        profile_id TEXT REFERENCES vault_profiles(id),
        generation INTEGER NOT NULL CHECK(generation >= 0),
        step TEXT NOT NULL,
        working_settings_json BLOB NOT NULL,
        proposed_bookmark BLOB,
        import_diff_json BLOB,
        browser_state_json BLOB,
        updated_at REAL NOT NULL
    );
    CREATE TABLE drafts (
        id TEXT PRIMARY KEY NOT NULL,
        profile_id TEXT REFERENCES vault_profiles(id),
        revision INTEGER NOT NULL CHECK(revision >= 0),
        representation_version INTEGER NOT NULL CHECK(representation_version > 0),
        markdown BLOB NOT NULL,
        blocks_json BLOB,
        opaque_sources_json BLOB,
        routing_choice TEXT NOT NULL CHECK(routing_choice IN ('automatic','today','inbox')),
        selected_range_json BLOB,
        updated_at REAL NOT NULL,
        state TEXT NOT NULL CHECK(state IN ('active','parked','captured','discarded'))
    );
    CREATE TABLE captures (
        id TEXT PRIMARY KEY NOT NULL,
        draft_id TEXT NOT NULL REFERENCES drafts(id),
        draft_revision INTEGER NOT NULL CHECK(draft_revision >= 0),
        profile_id TEXT NOT NULL REFERENCES vault_profiles(id),
        immutable_snapshot_json BLOB NOT NULL,
        state TEXT NOT NULL CHECK(state IN ('pending','preparing','committing','committed','retryableFailure','waitingForVault','needsReview','cancelled')),
        attempt_count INTEGER NOT NULL CHECK(attempt_count >= 0),
        next_attempt_at REAL,
        last_error_code TEXT,
        created_at REAL NOT NULL,
        committed_at REAL,
        UNIQUE(draft_id, draft_revision)
    );
    CREATE TABLE assets (
        id TEXT PRIMARY KEY NOT NULL,
        local_relative_path TEXT NOT NULL UNIQUE,
        original_name TEXT NOT NULL,
        media_type TEXT NOT NULL,
        byte_count INTEGER NOT NULL CHECK(byte_count >= 0),
        sha256 TEXT NOT NULL,
        width INTEGER,
        height INTEGER,
        state TEXT NOT NULL CHECK(state IN ('staged','published','missing','quarantined'))
    );
    CREATE TABLE draft_assets (
        owner_id TEXT NOT NULL REFERENCES drafts(id) ON DELETE CASCADE,
        asset_id TEXT NOT NULL REFERENCES assets(id),
        PRIMARY KEY(owner_id, asset_id)
    );
    CREATE TABLE capture_assets (
        owner_id TEXT NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
        asset_id TEXT NOT NULL REFERENCES assets(id),
        PRIMARY KEY(owner_id, asset_id)
    );
    CREATE TABLE mutations (
        operation_id TEXT NOT NULL,
        sequence INTEGER NOT NULL CHECK(sequence >= 0),
        capture_id TEXT NOT NULL REFERENCES captures(id),
        kind TEXT NOT NULL CHECK(kind IN ('asset','note')),
        relative_target TEXT NOT NULL,
        before_hash TEXT,
        after_hash TEXT NOT NULL,
        before_blob BLOB,
        after_blob BLOB NOT NULL,
        phase TEXT NOT NULL CHECK(phase IN ('planned','temporaryWritten','published')),
        published_resource_id BLOB,
        PRIMARY KEY(operation_id, sequence)
    );
    CREATE TABLE receipts (
        capture_id TEXT PRIMARY KEY NOT NULL REFERENCES captures(id),
        note_relative_path TEXT NOT NULL,
        note_hash_at_commit TEXT NOT NULL,
        committed_at REAL NOT NULL,
        asset_results_json BLOB NOT NULL
    );
    CREATE TABLE migration_records (
        migration_key TEXT PRIMARY KEY NOT NULL,
        source_hash TEXT NOT NULL,
        completed_at REAL NOT NULL,
        report_json BLOB NOT NULL
    );
    CREATE TABLE quarantined_records (
        id TEXT PRIMARY KEY NOT NULL,
        source_name TEXT NOT NULL,
        byte_offset INTEGER NOT NULL CHECK(byte_offset >= 0),
        raw_bytes BLOB NOT NULL,
        error_code TEXT NOT NULL
    );
    CREATE INDEX captures_pending ON captures(profile_id, state, created_at);
    CREATE INDEX mutations_capture ON mutations(capture_id, sequence);
    """
}
