import Foundation
import XCTest
@testable import KnotKit

final class ConfigurationRewriteTests: XCTestCase {
    func test_T10_onboardingResumesEveryStepAndFinishesAtomically() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let defaults = try ValidatedSettings()
        let sessionID = OnboardingSessionID()
        var generation = 0

        for step in OnboardingStep.allCases {
            generation += 1
            let store = try CaptureStore(directory: fixture.url)
            let session = try OnboardingSession(
                id: sessionID,
                generation: generation,
                step: step,
                workingSettings: defaults,
                proposedBookmark: Data("fixture-bookmark".utf8),
                browserState: FolderBrowserState(
                    browserPath: try VaultRelativePath("Parent"),
                    selectedPath: try VaultRelativePath("Selected"),
                    query: "typed"
                ),
                folderCreationIntents: [try VaultRelativePath("New/Nested")],
                dailyTemplatePath: try VaultRelativePath("Templates/Daily.md", kind: .file),
                updatedAt: Date(timeIntervalSince1970: Double(generation))
            )
            try await store.saveOnboardingSession(session)

            let reopened = try CaptureStore(directory: fixture.url)
            let restored = try await reopened.onboardingSession(id: sessionID)
            XCTAssertEqual(restored, session)
            if step != .summary {
                await XCTAssertThrowsErrorAsync(
                    try await reopened.finishOnboarding(sessionID: sessionID, displayName: "Fixture")
                )
                let active = try await reopened.activeProfile()
                XCTAssertNil(active)
            }
        }

        let finalStore = try CaptureStore(directory: fixture.url)
        let profileID = try await finalStore.finishOnboarding(sessionID: sessionID, displayName: "Fixture")
        let active = try await finalStore.activeProfile()
        let finishedSession = try await finalStore.onboardingSession(id: sessionID)
        XCTAssertEqual(active?.id, profileID)
        XCTAssertNil(finishedSession)
    }

    func test_T10_resetLeavesPendingCaptureOnInactiveOldProfile() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let store = try CaptureStore(directory: fixture.url)
        let settings = try ValidatedSettings()
        let profileID = try await store.createProfile(
            displayName: "Old Fixture",
            bookmark: Data("old".utf8),
            settings: settings,
            onboardingState: "complete"
        )
        let draftID = DraftID()
        try await store.checkpointDraft(try DraftCheckpoint(
            id: draftID,
            profileID: profileID,
            revision: .zero,
            markdown: Data("pending".utf8)
        ))
        let snapshot = try CaptureSnapshot(
            draftID: draftID,
            draftRevision: .zero,
            vaultID: profileID,
            settingsRevision: .zero,
            settings: settings,
            createdAt: Date(timeIntervalSince1970: 1),
            timeZoneIdentifier: "UTC",
            localeIdentifier: "en_US",
            destination: .inbox(parent: settings.inboxFolder, filenameStem: "pending"),
            document: try CaptureDocument(markdown: "pending")
        )
        _ = try await store.enqueue(snapshot)

        let reset = try await store.resetConfiguration(profileID: profileID, defaults: settings)
        XCTAssertEqual(reset.step, .vault)
        let oldProfile = try await store.profile(id: profileID)
        let pending = try await store.pendingCaptures(profileID: profileID)
        let active = try await store.activeProfile()
        XCTAssertEqual(oldProfile?.onboardingState, "inactive")
        XCTAssertEqual(pending.map(\.snapshot.id), [snapshot.id])
        XCTAssertNil(active)
    }

    func test_T11_descriptorBrowserListsOnlyImmediateVisibleDirectories() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.url.appending(path: "One/Nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.url.appending(path: "Two"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.url.appending(path: ".hidden"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.url.appending(path: "Thing.app"), withIntermediateDirectories: true)
        try Data().write(to: fixture.url.appending(path: "file.md"))
        let vaultID = VaultID()
        let browser = VaultBrowser(provider: DescriptorFolderListingProvider(
            access: DirectoryVaultAccessProvider(vaultID: vaultID, rootURL: fixture.url)
        ))

        let root = try await browser.load(path: .root, generation: 0, requestID: UUID())
        XCTAssertEqual(root.children.map(\.name), ["One", "Two"])
        let child = try await browser.load(path: try VaultRelativePath("One"), generation: 0, requestID: UUID())
        XCTAssertEqual(child.children.map(\.name), ["Nested"])
    }

    func test_T11_allTenThousandChildrenAndTypedParentPrefixRemainReachable() async throws {
        let vaultID = VaultID()
        let provider = FixtureListingProvider(vaultID: vaultID) { path in
            if path.string == "Parent" {
                return Self.listing(path: path, names: ["alpha", "Alpine", "beta"], identity: 2)
            }
            return Self.listing(path: path, names: (0..<10_000).map { String(format: "Folder-%05d", $0) }, identity: 1)
        }
        let browser = VaultBrowser(provider: provider)
        let root = try await browser.load(path: .root, generation: 0, requestID: UUID())
        XCTAssertEqual(root.children.count, 10_000)
        XCTAssertEqual(root.children.last?.name, "Folder-09999")

        let suggestions = try await browser.suggestions(
            typedPath: "Parent/alp",
            generation: 0,
            requestID: UUID()
        )
        XCTAssertEqual(suggestions.parent.string, "Parent")
        XCTAssertEqual(Set(suggestions.matches.map(\.name)), Set(["alpha", "Alpine"]))
        XCTAssertNil(suggestions.exactMatch)
    }

    func test_T12_lateOldGenerationCannotPublishOverNewVaultResult() async throws {
        let provider = FixtureListingProvider(vaultID: VaultID()) { path in
            if path.isRoot {
                try await Task.sleep(for: .milliseconds(100))
                return Self.listing(path: path, names: ["old"], identity: 1)
            }
            return Self.listing(path: path, names: ["new"], identity: 2)
        }
        let browser = VaultBrowser(provider: provider)
        let old = Task { try await browser.load(path: .root, generation: 0, requestID: UUID()) }
        try await Task.sleep(for: .milliseconds(10))
        try await browser.beginGeneration(1)
        let current = try await browser.load(
            path: try VaultRelativePath("Current"),
            generation: 1,
            requestID: UUID()
        )
        XCTAssertEqual(current.children.map(\.name), ["new"])
        await XCTAssertThrowsErrorAsync(try await old.value)
    }

    func test_T13_importPrecedenceEnablementValidationAndScopedUndo() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try writeJSON(["periodic-notes"], to: ".obsidian/community-plugins.json", root: fixture.url)
        try writeJSON([
            "daily": ["enabled": true, "folder": "../outside", "format": "YYYY-MM-DD"]
        ], to: ".obsidian/plugins/periodic-notes/data.json", root: fixture.url)
        try writeJSON([String](), to: ".obsidian/core-plugins.json", root: fixture.url)
        try writeJSON(["folder": "Core", "format": "YYYY-MM-DD"], to: ".obsidian/daily-notes.json", root: fixture.url)
        try writeJSON(["attachmentFolderPath": "./assets"], to: ".obsidian/app.json", root: fixture.url)

        let imported = await ObsidianConfigurationReader.read(
            access: DirectoryVaultAccessProvider(vaultID: VaultID(), rootURL: fixture.url)
        )
        XCTAssertEqual(imported.daily?.source, .periodicNotes)
        XCTAssertEqual(imported.daily?.enablement, .enabled)
        XCTAssertFalse(imported.daily?.validationErrors.isEmpty ?? true)
        XCTAssertEqual(imported.attachment?.value, "./assets")
        XCTAssertTrue(imported.attachment?.validationErrors.isEmpty == true)

        let original = try ValidatedSettings(inboxFolder: "Inbox")
        let validImport = ImportedVaultConfiguration(
            daily: ImportedDailyProposal(
                folder: "Journal",
                filenameFormat: "YYYY-MM-DD",
                templatePath: nil,
                source: .periodicNotes,
                enablement: .enabled,
                validationErrors: []
            ),
            attachment: ImportedAttachmentProposal(value: "./assets", validationErrors: [])
        )
        let (adopted, diff) = try original.applying(imported: validImport)
        let manuallyEdited = try ValidatedSettings(
            dailyFolder: adopted.dailyFolder.string,
            inboxFolder: "Manual Inbox",
            dailyFilenameFormat: adopted.dailyFilenameFormat,
            inboxFilenameFormat: adopted.inboxFilenameFormat,
            dailyTarget: adopted.dailyTarget,
            dailyBulletFormat: adopted.dailyBulletFormat,
            routingMaxChars: adopted.routingMaxChars,
            routingRequiresSingleLine: adopted.routingRequiresSingleLine,
            attachmentFolderPath: adopted.attachmentFolderPath
        )
        let undone = try manuallyEdited.undoing(diff)
        XCTAssertEqual(undone.dailyFolder.string, original.dailyFolder.string)
        XCTAssertEqual(undone.attachmentFolderPath, original.attachmentFolderPath)
        XCTAssertEqual(undone.inboxFolder.string, "Manual Inbox")
    }

    func test_T13_coreDisabledAndUnknownAreVisibleProposalsNotAutomaticAdoption() async throws {
        for (plugins, expected) in [([String](), ImportEnablement.disabled), (nil, ImportEnablement.unknown)] {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            if let plugins {
                try writeJSON(plugins, to: ".obsidian/core-plugins.json", root: fixture.url)
            }
            try writeJSON(["folder": "Daily", "format": "YYYY-MM-DD"], to: ".obsidian/daily-notes.json", root: fixture.url)
            let imported = await ObsidianConfigurationReader.read(
                access: DirectoryVaultAccessProvider(vaultID: VaultID(), rootURL: fixture.url)
            )
            XCTAssertEqual(imported.daily?.enablement, expected)
            XCTAssertEqual(imported.daily?.automaticAdoptionAllowed, false)
        }
    }

    private static func listing(path: VaultRelativePath, names: [String], identity: UInt64) -> FolderListing {
        FolderListing(
            path: path,
            identity: DirectoryIdentity(device: 1, inode: identity),
            children: names.enumerated().map { index, name in
                FolderEntry(
                    name: name,
                    path: try! path.appending(component: name, kind: .folder),
                    identity: DirectoryIdentity(device: 1, inode: identity * 20_000 + UInt64(index + 1))
                )
            }
        )
    }

    private func writeJSON(_ value: Any, to path: String, root: URL) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: url)
    }

    private func makeFixture() throws -> (url: URL, cleanup: () -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "KnotConfigurationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, { try? FileManager.default.removeItem(at: url) })
    }
}

private struct FixtureListingProvider: FolderListingProvider {
    let vaultID: VaultID
    let body: @Sendable (VaultRelativePath) async throws -> FolderListing

    init(
        vaultID: VaultID,
        body: @escaping @Sendable (VaultRelativePath) async throws -> FolderListing
    ) {
        self.vaultID = vaultID
        self.body = body
    }

    func list(path: VaultRelativePath) async throws -> FolderListing {
        try await body(path)
    }
}
