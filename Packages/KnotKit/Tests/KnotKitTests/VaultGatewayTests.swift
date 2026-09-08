import XCTest
@testable import KnotKit

final class VaultGatewayTests: XCTestCase {
    func test_T01_invalidUTF8DailyFileRemainsByteIdenticalAndCapturePending() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let daily = fixture.vault.appending(path: "Daily/2026-09-08.md")
        try FileManager.default.createDirectory(at: daily.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data([0xFF, 0xFE, 0x00, 0x41])
        try original.write(to: daily)

        let context = try await makeCapture(
            fixture: fixture,
            markdown: "preserve this",
            destination: .today(
                notePath: try VaultRelativePath("Daily/2026-09-08.md", kind: .file),
                target: .heading(try HeadingSelector(title: "Quick notes", level: 2), missing: .createAtEnd)
            )
        )
        await XCTAssertThrowsErrorAsync(
            try await context.gateway.commit(captureID: context.captureID)
        )
        XCTAssertEqual(try Data(contentsOf: daily), original)
        let stored = try await context.store.capture(id: context.captureID)
        XCTAssertEqual(stored?.state, .needsReview)
    }

    func test_T02_symlinkAndHardlinkTargetsAreRejectedWithoutOutsideMutation() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let outside = fixture.root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.vault.appending(path: "Inbox"),
            withDestinationURL: outside
        )
        let inbox = try await makeCapture(
            fixture: fixture,
            markdown: "must stay inside",
            destination: .inbox(parent: try VaultRelativePath("Inbox"), filenameStem: "note")
        )
        await XCTAssertThrowsErrorAsync(try await inbox.gateway.commit(captureID: inbox.captureID))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)

        try FileManager.default.removeItem(at: fixture.vault.appending(path: "Inbox"))
        let dailyFolder = fixture.vault.appending(path: "Daily")
        try FileManager.default.createDirectory(at: dailyFolder, withIntermediateDirectories: true)
        let first = dailyFolder.appending(path: "2026-09-08.md")
        let linked = dailyFolder.appending(path: "linked.md")
        try Data("# Day\n".utf8).write(to: first)
        try FileManager.default.linkItem(at: first, to: linked)
        let before = try Data(contentsOf: first)
        let dailyCapture = try await makeCapture(
            fixture: fixture,
            markdown: "hardlink",
            destination: .today(
                notePath: try VaultRelativePath("Daily/2026-09-08.md", kind: .file),
                target: .endOfNote
            )
        )
        await XCTAssertThrowsErrorAsync(
            try await dailyCapture.gateway.commit(captureID: dailyCapture.captureID)
        )
        XCTAssertEqual(try Data(contentsOf: first), before)
        XCTAssertEqual(try Data(contentsOf: linked), before)
    }

    func test_T03_oneHundredConcurrentSameNameInboxCapturesNeverOverwrite() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = try CaptureStore(directory: fixture.support)
        let profileID = VaultID()
        let settings = try ValidatedSettings(inboxFolder: "Inbox")
        _ = try await store.createProfile(
            id: profileID,
            displayName: "Fixture Vault",
            bookmark: Data("fixture".utf8),
            settings: settings
        )
        let access = DirectoryVaultAccessProvider(vaultID: profileID, rootURL: fixture.vault)
        let gatewayA = VaultGateway(store: store, access: access, privateRoot: fixture.support)
        let gatewayB = VaultGateway(store: store, access: access, privateRoot: fixture.support)
        var captures: [(CaptureID, String)] = []
        for index in 0..<100 {
            let body = "body-\(index)"
            let draftID = DraftID()
            try await store.checkpointDraft(try DraftCheckpoint(
                id: draftID,
                profileID: profileID,
                revision: .zero,
                markdown: Data(body.utf8)
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
                destination: .inbox(parent: try VaultRelativePath("Inbox"), filenameStem: "same"),
                document: try CaptureDocument(markdown: body)
            )
            _ = try await store.enqueue(snapshot)
            captures.append((snapshot.id, body))
        }

        try await withThrowingTaskGroup(of: VaultCommitReceipt.self) { group in
            for (index, capture) in captures.enumerated() {
                let gateway = index.isMultiple(of: 2) ? gatewayA : gatewayB
                group.addTask { try await gateway.commit(captureID: capture.0) }
            }
            var count = 0
            for try await _ in group { count += 1 }
            XCTAssertEqual(count, 100)
        }

        let inbox = fixture.vault.appending(path: "Inbox")
        let files = try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        XCTAssertEqual(files.count, 100)
        let bodies = try Set(files.map { try String(contentsOf: $0, encoding: .utf8) })
        XCTAssertEqual(bodies, Set(captures.map(\.1)))
    }

    func test_T05_reconciliationProvesPublishedReceiptOrRequiresReview() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let context = try await makeCapture(
            fixture: fixture,
            markdown: "reconcile",
            destination: .inbox(parent: try VaultRelativePath("Inbox"), filenameStem: "reconcile")
        )
        try await context.store.transition(captureID: context.captureID, to: .preparing)
        let operation = OperationID()
        let path = try VaultRelativePath("Inbox/reconcile.md", kind: .file)
        let bytes = Data("reconcile".utf8)
        try await context.store.recordMutationPlan([
            MutationRecord(
                operationID: operation,
                sequence: 0,
                captureID: context.captureID,
                kind: .note,
                relativeTarget: path,
                beforeHash: nil,
                afterHash: AssetStager.sha256(bytes),
                beforeBlob: nil,
                afterBlob: bytes
            )
        ])
        try await context.store.transition(captureID: context.captureID, to: .committing)
        let target = fixture.vault.appending(path: path.string)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: target)

        let receipt = try await context.gateway.reconcile(captureID: context.captureID)
        XCTAssertEqual(receipt.notePath, path)
        let committed = try await context.store.capture(id: context.captureID)
        XCTAssertEqual(committed?.state, .committed)

        let second = try await makeCapture(
            fixture: fixture,
            markdown: "other",
            destination: .inbox(parent: try VaultRelativePath("Inbox"), filenameStem: "other")
        )
        try await second.store.transition(captureID: second.captureID, to: .preparing)
        let otherPath = try VaultRelativePath("Inbox/other.md", kind: .file)
        try await second.store.recordMutationPlan([
            MutationRecord(
                operationID: OperationID(),
                sequence: 0,
                captureID: second.captureID,
                kind: .note,
                relativeTarget: otherPath,
                beforeHash: nil,
                afterHash: AssetStager.sha256(Data("other".utf8)),
                beforeBlob: nil,
                afterBlob: Data("other".utf8)
            )
        ])
        try await second.store.transition(captureID: second.captureID, to: .committing)
        try Data("external".utf8).write(to: fixture.vault.appending(path: otherPath.string))
        await XCTAssertThrowsErrorAsync(try await second.gateway.reconcile(captureID: second.captureID))
        let needsReview = try await second.store.capture(id: second.captureID)
        XCTAssertEqual(needsReview?.state, .needsReview)
    }

    func test_T16_assetReferencesReplaceOnlyParsedImageDestinations() throws {
        let id = AssetID(rawValue: try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555")))
        let token = "knot-asset://" + id.description
        let markdown = """
        User text \(token) remains literal.

        `![inline code](\(token))`

        ```markdown
        ![fenced](\(token))
        ```

        ![emoji image](\(token))

        ![angle image](<\(token)> "title")
        """
        let destination = "../Media/diagram%20one.png"
        let rewritten = AssetReferenceRewriter.rewrite(
            markdown,
            destinations: [token: destination]
        )

        XCTAssertTrue(rewritten.contains("User text \(token) remains literal."))
        XCTAssertTrue(rewritten.contains("`![inline code](\(token))`"))
        XCTAssertTrue(rewritten.contains("![fenced](\(token))"))
        XCTAssertTrue(rewritten.contains("![emoji image](\(destination))"))
        XCTAssertTrue(rewritten.contains("![angle image](<\(destination)> \"title\")"))
        XCTAssertEqual(rewritten.components(separatedBy: token).count - 1, 3)
    }

    private func makeCapture(
        fixture: Fixture,
        markdown: String,
        destination: ResolvedDestination
    ) async throws -> (
        store: CaptureStore,
        gateway: VaultGateway,
        captureID: CaptureID
    ) {
        let store = try CaptureStore(directory: fixture.support)
        let profileID = VaultID()
        let settings = try ValidatedSettings()
        _ = try await store.createProfile(
            id: profileID,
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
            createdAt: Date(timeIntervalSince1970: 1_757_289_600),
            timeZoneIdentifier: "UTC",
            localeIdentifier: "en_US",
            destination: destination,
            document: try CaptureDocument(markdown: markdown)
        )
        _ = try await store.enqueue(snapshot)
        let access = DirectoryVaultAccessProvider(vaultID: profileID, rootURL: fixture.vault)
        return (
            store,
            VaultGateway(store: store, access: access, privateRoot: fixture.support),
            snapshot.id
        )
    }

    private struct Fixture {
        let root: URL
        let vault: URL
        let support: URL
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "KnotVaultGatewayTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let vault = root.appending(path: "Vault", directoryHint: .isDirectory)
        let support = root.appending(path: "Support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return Fixture(root: root, vault: vault, support: support)
    }
}
