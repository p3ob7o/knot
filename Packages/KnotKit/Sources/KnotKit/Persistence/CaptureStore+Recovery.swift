import Foundation
import GRDB

public extension CaptureStore {
    func latestDraft(profileID: VaultID? = nil) throws -> DraftCheckpoint? {
        try database.read { db in
            let row: Row?
            if let profileID {
                row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT * FROM drafts
                    WHERE profile_id = ? AND state IN ('active','parked')
                    ORDER BY updated_at DESC, id DESC LIMIT 1
                    """,
                    arguments: [profileID.description]
                )
            } else {
                row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT * FROM drafts
                    WHERE state IN ('active','parked')
                    ORDER BY updated_at DESC, id DESC LIMIT 1
                    """
                )
            }
            return try row.map(decodeDraft)
        }
    }

    func assetIDs(draftID: DraftID) throws -> [AssetID] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT asset_id FROM draft_assets WHERE owner_id = ? ORDER BY asset_id",
                arguments: [draftID.description]
            ).map { raw in
                guard let uuid = UUID(uuidString: raw) else { throw CaptureStoreError.corruptRecord }
                return AssetID(rawValue: uuid)
            }
        }
    }

    func draftAssetUsage(draftID: DraftID) throws -> (count: Int, bytes: Int) {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) AS count, COALESCE(SUM(assets.byte_count), 0) AS bytes
                FROM draft_assets JOIN assets ON assets.id = draft_assets.asset_id
                WHERE draft_assets.owner_id = ?
                """,
                arguments: [draftID.description]
            ) else { return (0, 0) }
            return (row["count"], row["bytes"])
        }
    }

    func cancelCapture(id: CaptureID) throws {
        try database.write { db in
            guard let raw: String = try String.fetchOne(
                db,
                sql: "SELECT state FROM captures WHERE id = ?",
                arguments: [id.description]
            ), let state = CaptureState(rawValue: raw) else { throw CaptureStoreError.captureMissing }
            guard [CaptureState.pending, .preparing, .retryableFailure, .waitingForVault].contains(state) else {
                throw CaptureStoreError.illegalTransition(from: state, to: .cancelled)
            }
            try db.execute(sql: "UPDATE captures SET state = 'cancelled' WHERE id = ?", arguments: [id.description])
        }
    }

    func resolveNeedsReviewAsSaved(captureID: CaptureID, now: Date = Date()) throws {
        guard let capture = try capture(id: captureID) else { throw CaptureStoreError.captureMissing }
        guard capture.state == .needsReview else {
            throw CaptureStoreError.illegalTransition(from: capture.state, to: .committed)
        }
        let records = try mutations(captureID: captureID)
        guard let note = records.last(where: { $0.kind == .note }) else {
            throw CaptureStoreError.corruptRecord
        }
        let assetPaths = records.filter { $0.kind == .asset }.map(\.relativeTarget)
        try storeReceipt(CaptureReceipt(
            captureID: captureID, noteRelativePath: note.relativeTarget,
            noteHashAtCommit: note.afterHash, committedAt: now,
            assetResultsJSON: try encoder.encode(assetPaths)
        ))
    }

    @discardableResult
    func retryNeedsReviewAsNew(captureID: CaptureID, now: Date = Date()) throws -> CaptureID {
        guard let original = try capture(id: captureID) else { throw CaptureStoreError.captureMissing }
        guard original.state == .needsReview else {
            throw CaptureStoreError.illegalTransition(from: original.state, to: .cancelled)
        }
        let newDraftID = DraftID()
        let newCaptureID = CaptureID()
        let newDraft = try DraftCheckpoint(
            id: newDraftID, profileID: original.snapshot.vaultID, revision: .zero,
            representationVersion: original.snapshot.document.representationVersion,
            markdown: Data(original.snapshot.document.markdown.utf8),
            blocksJSON: original.snapshot.document.blocksJSON,
            opaqueSourcesJSON: original.snapshot.document.opaqueSourcesJSON,
            routingChoice: .automatic, updatedAt: now, state: .active
        )
        let newSnapshot = try CaptureSnapshot(
            id: newCaptureID, draftID: newDraftID, draftRevision: .zero,
            vaultID: original.snapshot.vaultID, settingsRevision: original.snapshot.settingsRevision,
            settings: original.snapshot.settings, createdAt: original.snapshot.createdAt,
            timeZoneIdentifier: original.snapshot.timeZoneIdentifier,
            localeIdentifier: original.snapshot.localeIdentifier, destination: original.snapshot.destination,
            document: original.snapshot.document, assetIDs: original.snapshot.assetIDs
        )
        let snapshotData = try encoder.encode(newSnapshot)
        try database.write { db in
            guard try String.fetchOne(
                db, sql: "SELECT state FROM captures WHERE id = ?", arguments: [captureID.description]
            ) == CaptureState.needsReview.rawValue else {
                throw CaptureStoreError.illegalTransition(from: .needsReview, to: .cancelled)
            }
            try db.execute(
                sql: """
                INSERT INTO drafts
                    (id, profile_id, revision, representation_version, markdown, blocks_json,
                     opaque_sources_json, routing_choice, selected_range_json, updated_at, state)
                VALUES (?, ?, 0, ?, ?, ?, ?, ?, NULL, ?, 'captured')
                """,
                arguments: [
                    newDraft.id.description, newDraft.profileID?.description,
                    newDraft.representationVersion, newDraft.markdown, newDraft.blocksJSON,
                    newDraft.opaqueSourcesJSON, newDraft.routingChoice.rawValue,
                    newDraft.updatedAt.timeIntervalSince1970
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO captures
                    (id, draft_id, draft_revision, profile_id, immutable_snapshot_json,
                     state, attempt_count, created_at)
                VALUES (?, ?, 0, ?, ?, 'pending', 0, ?)
                """,
                arguments: [
                    newCaptureID.description, newDraftID.description,
                    newSnapshot.vaultID.description, snapshotData, now.timeIntervalSince1970
                ]
            )
            for assetID in newSnapshot.assetIDs {
                guard try Bool.fetchOne(
                    db, sql: "SELECT EXISTS(SELECT 1 FROM assets WHERE id = ?)",
                    arguments: [assetID.description]
                ) == true else { throw CaptureStoreError.assetMissing }
                try db.execute(
                    sql: "INSERT INTO capture_assets (owner_id, asset_id) VALUES (?, ?)",
                    arguments: [newCaptureID.description, assetID.description]
                )
            }
            try db.execute(
                sql: "UPDATE captures SET state = 'cancelled', next_attempt_at = NULL WHERE id = ?",
                arguments: [captureID.description]
            )
        }
        return newCaptureID
    }

    func exportableMarkdown(captureID: CaptureID) throws -> Data {
        let data: Data = try database.read { db in
            guard let value = try Data.fetchOne(
                db,
                sql: "SELECT immutable_snapshot_json FROM captures WHERE id = ?",
                arguments: [captureID.description]
            ) else { throw CaptureStoreError.captureMissing }
            return value
        }
        let snapshot = try decoder.decode(CaptureSnapshot.self, from: data)
        return Data(snapshot.document.markdown.utf8)
    }
}
