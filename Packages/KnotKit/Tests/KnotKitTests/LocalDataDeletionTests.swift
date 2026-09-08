import XCTest
@testable import KnotKit

final class LocalDataDeletionTests: XCTestCase {
    func test_T22_eraseLocalDraftsPreservesPendingCaptureAndItsAssets() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "KnotLocalErase-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureStore(directory: root)
        let profileID = try await store.createProfile(
            displayName: "Fixture",
            bookmark: Data("fixture".utf8),
            settings: try ValidatedSettings()
        )

        let pendingDraft = DraftID()
        try await store.checkpointDraft(try DraftCheckpoint(
            id: pendingDraft,
            profileID: profileID,
            revision: .zero,
            markdown: Data("pending".utf8)
        ))
        let pendingSnapshot = try CaptureSnapshot(
            draftID: pendingDraft,
            draftRevision: .zero,
            vaultID: profileID,
            settingsRevision: .zero,
            settings: try ValidatedSettings(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            timeZoneIdentifier: "UTC",
            localeIdentifier: "en_US",
            destination: .inbox(parent: try VaultRelativePath("Inbox"), filenameStem: "pending"),
            document: try CaptureDocument(markdown: "pending")
        )
        _ = try await store.enqueue(pendingSnapshot)

        let disposableDraft = DraftID()
        try await store.checkpointDraft(try DraftCheckpoint(
            id: disposableDraft,
            profileID: profileID,
            revision: .zero,
            markdown: Data("erase".utf8)
        ))

        let erased = try await store.eraseLocalDrafts()
        let erasedDraft = try await store.draft(id: disposableDraft)
        let retainedDraft = try await store.draft(id: pendingDraft)
        let retainedCapture = try await store.capture(id: pendingSnapshot.id)
        XCTAssertEqual(erased, 1)
        XCTAssertNil(erasedDraft)
        XCTAssertNotNil(retainedDraft)
        XCTAssertEqual(retainedCapture?.state, .pending)
    }
}
