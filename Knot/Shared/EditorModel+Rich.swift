import Foundation
import KnotKit

struct RichAssetSeed: Sendable, Equatable {
    let id: AssetID
    let data: Data
    let mediaType: String
}

struct RichDraftSeed: Sendable, Equatable {
    let draftID: DraftID
    let revision: Revision
    let markdown: String
    let blocksJSON: Data?
    let opaqueSourcesJSON: Data?
    let assets: [RichAssetSeed]
}

@MainActor
extension EditorModel {
    func promoteCurrentDraftToRich() async throws -> RichDraftSeed {
        await flushDraft()
        guard let store else { throw CaptureStoreError.storageUnavailable("uninitialized") }
        let sourceID = draftID
        guard let stored = try await store.draft(id: sourceID) else {
            throw CaptureStoreError.draftMissing
        }
        let markdown = String(data: stored.markdown, encoding: .utf8) ?? content
        var richAssets: [RichAssetSeed] = []
        if let supportDirectory {
            for assetID in try await store.assetIDs(draftID: sourceID) {
                guard let metadata = try await store.asset(id: assetID) else { continue }
                let root = supportDirectory.standardizedFileURL
                let url = root.appending(path: metadata.localRelativePath).standardizedFileURL
                guard url.path.hasPrefix(root.path + "/") else { continue }
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url, options: [.mappedIfSafe])
                }.value
                richAssets.append(RichAssetSeed(id: assetID, data: data, mediaType: metadata.mediaType))
            }
        }
        let seed = RichDraftSeed(
            draftID: sourceID,
            revision: stored.revision,
            markdown: markdown,
            blocksJSON: stored.blocksJSON,
            opaqueSourcesJSON: stored.opaqueSourcesJSON,
            assets: richAssets
        )

        let replacementID = DraftID()
        let replacement = try DraftCheckpoint(
            id: replacementID,
            profileID: profile?.id,
            revision: .zero,
            markdown: Data(),
            routingChoice: .automatic
        )
        try await store.checkpointDraft(replacement)
        suppressCheckpoint = true
        content = ""
        manualMode = nil
        draftID = replacementID
        draftRevision = .zero
        suppressCheckpoint = false
        return seed
    }

    func checkpointRichDraft(
        draftID: DraftID,
        baseRevision: Revision,
        nextRevision: Revision,
        markdown: String,
        blocksJSON: Data,
        opaqueSourcesJSON: Data,
        assetIDs: [AssetID]
    ) async throws -> Revision {
        guard nextRevision.rawValue == baseRevision.rawValue + 1 else {
            throw CaptureStoreError.revisionConflict(current: baseRevision)
        }
        guard let store else { throw CaptureStoreError.storageUnavailable("uninitialized") }
        guard let current = try await store.draft(id: draftID) else { throw CaptureStoreError.draftMissing }
        guard current.revision == baseRevision else {
            throw CaptureStoreError.revisionConflict(current: current.revision)
        }
        for assetID in assetIDs where try await store.asset(id: assetID) == nil {
            throw CaptureStoreError.assetMissing
        }
        let checkpoint = try DraftCheckpoint(
            id: draftID,
            profileID: current.profileID,
            revision: nextRevision,
            representationVersion: 1,
            markdown: Data(markdown.utf8),
            blocksJSON: blocksJSON,
            opaqueSourcesJSON: opaqueSourcesJSON,
            routingChoice: .inbox,
            selectedRangeJSON: nil,
            state: .active
        )
        try await store.checkpointDraft(checkpoint)
        return nextRevision
    }

    func stageRichAsset(
        data: Data,
        filename: String,
        mediaType: String,
        draftID: DraftID
    ) async throws -> AssetMetadata {
        guard let assetStager else { throw CaptureStoreError.storageUnavailable("stager") }
        return try await assetStager.stage(
            data: data,
            originalName: filename,
            declaredMediaType: mediaType,
            draftID: draftID
        )
    }

    func stageRichAsset(
        fileURL: URL,
        filename: String,
        mediaType: String,
        draftID: DraftID
    ) async throws -> AssetMetadata {
        guard let assetStager else { throw CaptureStoreError.storageUnavailable("stager") }
        return try await assetStager.stage(
            fileURL: fileURL,
            originalName: filename,
            declaredMediaType: mediaType,
            draftID: draftID
        )
    }

    func exportRichDraft(_ draftID: DraftID) async throws -> Data {
        guard let store, let draft = try await store.draft(id: draftID) else {
            throw CaptureStoreError.draftMissing
        }
        return draft.markdown
    }

    func discardRichDraft(_ draftID: DraftID) async throws {
        guard let store else { throw CaptureStoreError.storageUnavailable("uninitialized") }
        try await store.discardDraft(id: draftID)
    }

    func enqueueRichDraft(
        draftID: DraftID,
        revision: Revision,
        assetIDs: [AssetID]
    ) async throws -> CaptureID {
        guard let store, let profile else { throw CaptureStoreError.profileMissing }
        guard let draft = try await store.draft(id: draftID), draft.revision == revision,
              let markdown = String(data: draft.markdown, encoding: .utf8) else {
            throw CaptureStoreError.draftMissing
        }
        let ownedAssets = Set(try await store.assetIDs(draftID: draftID))
        guard Set(assetIDs).isSubset(of: ownedAssets) else { throw CaptureStoreError.assetMissing }

        let date = Date()
        let prepared = try prepare(markdown: markdown, mode: .inbox, settings: profile.settings, date: date)
        let document = try CaptureDocument(
            markdown: prepared.markdown,
            representation: .blocks,
            representationVersion: draft.representationVersion,
            blocksJSON: draft.blocksJSON,
            opaqueSourcesJSON: draft.opaqueSourcesJSON,
            assetIDs: assetIDs
        )
        let snapshot = try CaptureSnapshot(
            draftID: draftID,
            draftRevision: revision,
            vaultID: profile.id,
            settingsRevision: profile.settingsRevision,
            settings: profile.settings,
            createdAt: date,
            timeZoneIdentifier: TimeZone.current.identifier,
            localeIdentifier: Locale.current.identifier,
            destination: prepared.destination,
            document: document,
            assetIDs: assetIDs
        )
        let captureID = try await store.enqueue(snapshot)
        pendingCount = try await store.pendingCaptures().count
        status = .locallySaved(captureID)
        return captureID
    }

    func publishRichCapture(_ captureID: CaptureID) async throws -> VaultCommitReceipt {
        guard let store, let gateway else { throw CaptureStoreError.profileMissing }
        status = .sending(captureID)
        do {
            let receipt = try await gateway.commit(captureID: captureID)
            pendingCount = try await store.pendingCaptures().count
            status = .saved(receipt.notePath)
            return receipt
        } catch {
            pendingCount = (try? await store.pendingCaptures().count) ?? pendingCount
            if try await store.capture(id: captureID)?.state == .needsReview {
                status = .needsReview(captureID, error.localizedDescription)
            } else {
                status = .retryable(captureID, error.localizedDescription)
                scheduleRetryWorker()
            }
            throw error
        }
    }

    func richCaptureState(_ captureID: CaptureID) async -> CaptureState? {
        try? await store?.capture(id: captureID)?.state
    }

}
