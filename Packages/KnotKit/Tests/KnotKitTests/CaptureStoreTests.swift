import XCTest
@testable import KnotKit

final class CaptureStoreTests: XCTestCase {
    func test_T04_newerDraftSurvivesOlderCaptureCompletionAndDuplicateSend() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = try CaptureStore(directory: fixture.url)
        let context = try await makeContext(store: store, markdown: "revision A")

        let firstID = try await store.enqueue(context.snapshot)
        let duplicateID = try await store.enqueue(context.snapshot)
        XCTAssertEqual(firstID, duplicateID)

        let revisionB = try Revision(1)
        try await store.checkpointDraft(try DraftCheckpoint(
            id: context.draftID,
            profileID: context.profileID,
            revision: revisionB,
            markdown: Data("revision B  ".utf8)
        ))
        try await store.storeReceipt(CaptureReceipt(
            captureID: context.snapshot.id,
            noteRelativePath: try VaultRelativePath("Inbox/a.md", kind: .file),
            noteHashAtCommit: "hash"
        ))

        let loadedDraft = try await store.draft(id: context.draftID)
        let draft = try XCTUnwrap(loadedDraft)
        XCTAssertEqual(draft.revision, revisionB)
        XCTAssertEqual(String(decoding: draft.markdown, as: UTF8.self), "revision B  ")
        let committedState = try await store.capture(id: context.snapshot.id)?.state
        XCTAssertEqual(committedState, .committed)
    }

    func test_T05_journalAndCaptureStateSurviveStoreReopen() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let captureID: CaptureID
        let operationID = OperationID()
        do {
            let store = try CaptureStore(directory: fixture.url)
            let context = try await makeContext(store: store, markdown: "journal")
            captureID = context.snapshot.id
            _ = try await store.enqueue(context.snapshot)
            try await store.transition(captureID: captureID, to: .preparing)
            try await store.recordMutationPlan([
                MutationRecord(
                    operationID: operationID,
                    sequence: 0,
                    captureID: captureID,
                    kind: .note,
                    relativeTarget: try VaultRelativePath("Inbox/journal.md", kind: .file),
                    beforeHash: nil,
                    afterHash: "after",
                    beforeBlob: nil,
                    afterBlob: Data("journal".utf8)
                )
            ])
            try await store.transition(captureID: captureID, to: .committing)
        }

        let reopened = try CaptureStore(directory: fixture.url)
        let reopenedCapture = try await reopened.capture(id: captureID)
        let capture = try XCTUnwrap(reopenedCapture)
        XCTAssertEqual(capture.state, .committing)
        let mutations = try await reopened.mutations(captureID: captureID)
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations[0].phase, .planned)
        XCTAssertEqual(mutations[0].operationID, operationID)

        try await reopened.transition(captureID: captureID, to: .needsReview, errorCode: "outcomeUncertain")
        let reviewState = try await reopened.capture(id: captureID)?.state
        XCTAssertEqual(reviewState, .needsReview)
    }

    func test_T06_failedEnqueueNeverAcknowledgesAndPreservesDraft() async throws {
        enum Injected: Error { case diskFull }
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = try CaptureStore(
            directory: fixture.url,
            faults: PersistenceFaultInjector {
                if $0 == .enqueue { throw Injected.diskFull }
            }
        )
        let context = try await makeContext(store: store, markdown: "keep me")

        do {
            _ = try await store.enqueue(context.snapshot)
            XCTFail("Expected the durable enqueue to fail")
        } catch Injected.diskFull {
        }
        let pendingAfterFailure = try await store.pendingCaptures()
        XCTAssertTrue(pendingAfterFailure.isEmpty)
        let preservedValue = try await store.draft(id: context.draftID)
        let preserved = try XCTUnwrap(preservedValue)
        XCTAssertEqual(String(decoding: preserved.markdown, as: UTF8.self), "keep me")
    }

    func test_T06_missingAssetRejectsCaptureTransaction() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = try CaptureStore(directory: fixture.url)
        let context = try await makeContext(store: store, markdown: "![x](asset)")
        let missing = AssetID()
        let snapshot = try CaptureSnapshot(
            draftID: context.draftID,
            draftRevision: .zero,
            vaultID: context.profileID,
            settingsRevision: .zero,
            settings: try ValidatedSettings(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            timeZoneIdentifier: "UTC",
            localeIdentifier: "en_US",
            destination: .inbox(parent: try VaultRelativePath("Inbox"), filenameStem: "asset"),
            document: try CaptureDocument(markdown: "![x](asset)", assetIDs: [missing]),
            assetIDs: [missing]
        )
        await XCTAssertThrowsErrorAsync(try await store.enqueue(snapshot))
        let pendingWithoutAsset = try await store.pendingCaptures()
        XCTAssertTrue(pendingWithoutAsset.isEmpty)
    }

    func test_T06_T22_legacyQueueIsBackedUpQuarantinedAndIdempotent() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = try CaptureStore(directory: fixture.url)
        let queue = fixture.url.appending(path: "knot-queue.jsonl")
        let valid = #"{"id":"00000000-0000-0000-0000-000000000001","content":"synthetic","mode":"inbox","createdAt":0}"#
        let source = Data((valid + "\n{broken\n").utf8)
        try source.write(to: queue)
        let migrator = LegacyQueueMigrator(store: store, applicationSupportDirectory: fixture.url)

        let first = try await migrator.migrate(queueURL: queue)
        XCTAssertEqual(first.recoveredCount, 1)
        XCTAssertEqual(first.malformedCount, 1)
        XCTAssertEqual(try Data(contentsOf: first.backupURL), source)
        let firstQuarantineCount = try await store.quarantinedRecordCount()
        XCTAssertEqual(firstQuarantineCount, 2)

        let second = try await migrator.migrate(queueURL: queue)
        XCTAssertEqual(second.alreadyMigratedCount, 2)
        let secondQuarantineCount = try await store.quarantinedRecordCount()
        XCTAssertEqual(secondQuarantineCount, 2)
        XCTAssertEqual(try Data(contentsOf: queue), source)
    }

    func test_T05_uncertainCaptureCanBeMarkedSavedOrRetriedAsNewExplicitly() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = try CaptureStore(directory: fixture.url)

        let savedContext = try await makeContext(store: store, markdown: "asserted saved")
        _ = try await store.enqueue(savedContext.snapshot)
        try await store.transition(captureID: savedContext.snapshot.id, to: .preparing)
        let notePath = try VaultRelativePath("Inbox/asserted.md", kind: .file)
        let noteData = Data("asserted saved".utf8)
        try await store.recordMutationPlan([MutationRecord(
            operationID: OperationID(), sequence: 0, captureID: savedContext.snapshot.id,
            kind: .note, relativeTarget: notePath, beforeHash: nil,
            afterHash: AssetStager.sha256(noteData), beforeBlob: nil, afterBlob: noteData
        )])
        try await store.transition(captureID: savedContext.snapshot.id, to: .needsReview)
        try await store.resolveNeedsReviewAsSaved(captureID: savedContext.snapshot.id)
        let assertedCapture = try await store.capture(id: savedContext.snapshot.id)
        let assertedReceipt = try await store.receipt(captureID: savedContext.snapshot.id)
        XCTAssertEqual(assertedCapture?.state, .committed)
        XCTAssertEqual(assertedReceipt?.noteRelativePath, notePath)

        let retriedContext = try await makeContext(store: store, markdown: "retry unchanged snapshot")
        _ = try await store.enqueue(retriedContext.snapshot)
        try await store.transition(captureID: retriedContext.snapshot.id, to: .preparing)
        try await store.transition(captureID: retriedContext.snapshot.id, to: .needsReview)
        let retryID = try await store.retryNeedsReviewAsNew(captureID: retriedContext.snapshot.id)
        let original = try await store.capture(id: retriedContext.snapshot.id)
        let retry = try await store.capture(id: retryID)
        XCTAssertEqual(original?.state, .cancelled)
        XCTAssertEqual(retry?.state, .pending)
        XCTAssertNotEqual(retry?.snapshot.draftID, retriedContext.draftID)
        XCTAssertEqual(retry?.snapshot.document, retriedContext.snapshot.document)
        XCTAssertEqual(retry?.snapshot.destination, retriedContext.snapshot.destination)
        XCTAssertEqual(retry?.snapshot.createdAt, retriedContext.snapshot.createdAt)
    }

    func test_assetStagerValidatesAndRegistersPrivatePNG() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = try CaptureStore(directory: fixture.url)
        let draftID = DraftID()
        try await store.checkpointDraft(try DraftCheckpoint(
            id: draftID,
            profileID: nil,
            revision: .zero,
            markdown: Data()
        ))
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let stager = AssetStager(rootDirectory: fixture.url, store: store)
        let metadata = try await stager.stage(
            data: png,
            originalName: "pixel.png",
            declaredMediaType: "image/png",
            draftID: draftID
        )
        XCTAssertEqual(metadata.byteCount, png.count)
        let storedAsset = try await store.asset(id: metadata.id)
        XCTAssertEqual(storedAsset, metadata)
        XCTAssertEqual(
            try Data(contentsOf: fixture.url.appending(path: metadata.localRelativePath)),
            png
        )
    }

    func test_T16_nativeFileStagingStreamsIntoPrivateOwnedStorage() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = try CaptureStore(directory: fixture.url)
        let draftID = DraftID()
        try await store.checkpointDraft(try DraftCheckpoint(
            id: draftID,
            profileID: nil,
            revision: .zero,
            markdown: Data()
        ))
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let source = fixture.url.appending(path: "selected-pixel.png")
        try png.write(to: source)
        let stager = AssetStager(rootDirectory: fixture.url, store: store)
        let metadata = try await stager.stage(
            fileURL: source,
            originalName: "selected-pixel.png",
            declaredMediaType: "image/png",
            draftID: draftID
        )

        XCTAssertEqual(metadata.byteCount, png.count)
        XCTAssertEqual(metadata.sha256, AssetStager.sha256(png))
        XCTAssertEqual(
            try Data(contentsOf: fixture.url.appending(path: metadata.localRelativePath)),
            png
        )
        let stagedIDs = try await store.assetIDs(draftID: draftID)
        XCTAssertEqual(stagedIDs, [metadata.id])

        await XCTAssertThrowsErrorAsync(try await stager.stage(
            fileURL: source,
            originalName: "wrong.jpg",
            declaredMediaType: "image/jpeg",
            draftID: draftID
        ))
        let idsAfterRejectedType = try await store.assetIDs(draftID: draftID)
        XCTAssertEqual(idsAfterRejectedType, [metadata.id])
    }

    func test_illegalStateTransitionIsRejected() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = try CaptureStore(directory: fixture.url)
        let context = try await makeContext(store: store, markdown: "state")
        _ = try await store.enqueue(context.snapshot)
        await XCTAssertThrowsErrorAsync(
            try await store.transition(captureID: context.snapshot.id, to: .committed)
        )
        let stateAfterRejectedTransition = try await store.capture(id: context.snapshot.id)?.state
        XCTAssertEqual(stateAfterRejectedTransition, .pending)
    }

    private func makeContext(
        store: CaptureStore,
        markdown: String
    ) async throws -> (draftID: DraftID, profileID: VaultID, snapshot: CaptureSnapshot) {
        let settings = try ValidatedSettings()
        let profileID = try await store.createProfile(
            displayName: "Fixture Vault",
            bookmark: Data("fixture".utf8),
            settings: settings
        )
        let draftID = DraftID()
        try await store.checkpointDraft(try DraftCheckpoint(
            id: draftID,
            profileID: profileID,
            revision: .zero,
            markdown: Data(markdown.utf8)
        ))
        let snapshot = try CaptureSnapshot(
            draftID: draftID,
            draftRevision: .zero,
            vaultID: profileID,
            settingsRevision: .zero,
            settings: settings,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            timeZoneIdentifier: "UTC",
            localeIdentifier: "en_US",
            destination: .inbox(parent: try VaultRelativePath("Inbox"), filenameStem: "fixture"),
            document: try CaptureDocument(markdown: markdown)
        )
        return (draftID, profileID, snapshot)
    }

    private func makeFixture() throws -> (url: URL, cleanup: () -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "KnotCaptureStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, { try? FileManager.default.removeItem(at: url) })
    }
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
    }
}
