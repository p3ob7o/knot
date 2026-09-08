import Foundation
import KnotKit
import Observation
import SwiftUI

struct EditorAttachment: Sendable, Equatable {
    let token: String
    let filename: String
    let data: Data
    var mediaType: String = "image/png"
}

@MainActor @Observable
final class EditorModel {
    var content = "" {
        didSet {
            guard !suppressCheckpoint, content != oldValue else { return }
            if let next = try? draftRevision.next() { draftRevision = next }
            scheduleCheckpoint()
        }
    }
    var manualMode: NoteMode?
    var status: Status = .idle
    var settings = AppSettings()
    var vaultName: String?
    var vaultUnavailableName: String?
    var onboardingRequired = true
    private(set) var hasVault = false
    private(set) var onboardingSession: OnboardingSession?
    var pendingCount = 0
    private(set) var storageAvailable = false
    private(set) var configurationDiff: ConfigDiff?

    enum Status: Equatable {
        case idle, checkpointing, sent
        case locallySaved(CaptureID)
        case sending(CaptureID?)
        case saved(VaultRelativePath)
        case retryable(CaptureID, String)
        case needsReview(CaptureID, String)
        case error(String)
    }

    private let vaultStore: VaultStore
    private let defaults: UserDefaults
    private let supportDirectoryOverride: URL?
    private let onboardingCompletedKey = "knot.onboarding.completed"
    var store: CaptureStore?
    var supportDirectory: URL?
    var profile: VaultProfileRecord?
    var gateway: VaultGateway?
    var assetStager: AssetStager?
    var draftID = DraftID()
    var draftRevision = Revision.zero
    private var checkpointTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    var suppressCheckpoint = false
    private var sessionGeneration = 0

    init(vaultStore: VaultStore = VaultStore(), defaults: UserDefaults = .standard, supportDirectory: URL? = nil) {
        self.vaultStore = vaultStore
        self.defaults = defaults
        self.supportDirectoryOverride = supportDirectory
        settings = AppSettings.load(from: defaults)
        vaultName = vaultStore.vaultName
        Task { await bootstrap() }
    }

    var documentRevision: Revision { draftRevision }
    var settingsRevision: Revision? { profile?.settingsRevision }

    var resolvedMode: NoteMode {
        let value = (try? settings.validated()) ?? (try! ValidatedSettings())
        return manualMode ?? RoutingPolicy(settings: value).decide(for: content)
    }
    var canSend: Bool {
        content.unicodeScalars.contains { !$0.properties.isWhitespace } &&
            profile != nil && storageAvailable && !isSending
    }
    var shouldShowOnboarding: Bool { onboardingRequired || profile == nil }
    private var isSending: Bool { if case .sending = status { true } else { false } }

    func bootstrap() async {
        do {
            let directoryOverride = supportDirectoryOverride
            let pair = try await Task.detached(priority: .userInitiated) { () -> (URL, CaptureStore) in
                let directory = try directoryOverride ?? CaptureStore.applicationSupportDirectory()
                return (directory, try CaptureStore(directory: directory))
            }.value
            supportDirectory = pair.0
            store = pair.1
            assetStager = AssetStager(rootDirectory: pair.0, store: pair.1)
            storageAvailable = true
            try await migrateLegacyStateIfNeeded(store: pair.1, support: pair.0)
            try await restoreState(store: pair.1)
        } catch {
            storageAvailable = false
            onboardingRequired = true
            status = .error(error.localizedDescription)
        }
    }

    private func migrateLegacyStateIfNeeded(store: CaptureStore, support: URL) async throws {
        if let raw = defaults.data(forKey: AppSettings.userDefaultsKey) {
            let report = try LegacySettingsMigrator(applicationSupportDirectory: support).migrate(rawData: raw)
            settings = AppSettings(validated: report.settings)
        }
        if try await store.activeProfile() == nil,
           try await store.latestOnboardingSession() == nil,
           let bookmark = vaultStore.bookmarkData {
            let defaultSettings = try ValidatedSettings()
            let value = (try? settings.validated()) ?? defaultSettings
            if defaults.object(forKey: onboardingCompletedKey) as? Bool == true {
                _ = try await store.createProfile(
                    displayName: vaultStore.vaultName ?? "Vault",
                    bookmark: bookmark,
                    settings: value,
                    onboardingState: "complete"
                )
            } else {
                let session = try OnboardingSession(
                    step: .vault,
                    workingSettings: value,
                    proposedBookmark: bookmark
                )
                try await store.saveOnboardingSession(session)
            }
        }
        let legacyQueue = support.appending(path: "knot-queue.jsonl")
        if FileManager.default.fileExists(atPath: legacyQueue.path) {
            _ = try await LegacyQueueMigrator(store: store, applicationSupportDirectory: support)
                .migrate(queueURL: legacyQueue)
        }
    }

    private func restoreState(store: CaptureStore) async throws {
        profile = try await store.activeProfile()
        onboardingSession = try await store.latestOnboardingSession()
        onboardingRequired = profile == nil
        if let profile {
            settings = AppSettings(validated: profile.settings)
            vaultName = profile.displayName
            configureGateway(profile, store: store)
            if let draft = try await store.latestDraft(profileID: profile.id) {
                suppressCheckpoint = true
                draftID = draft.id
                draftRevision = draft.revision
                content = String(data: draft.markdown, encoding: .utf8) ?? ""
                manualMode = Self.noteMode(for: draft.routingChoice)
                suppressCheckpoint = false
            }
            await refreshVaultStatus()
            await resumePendingWork()
        } else if let session = onboardingSession {
            sessionGeneration = session.generation
            settings = AppSettings(validated: session.workingSettings)
        }
        pendingCount = try await store.pendingCaptures().count
    }

    private func configureGateway(_ profile: VaultProfileRecord, store: CaptureStore) {
        guard let supportDirectory else { return }
        gateway = VaultGateway(
            store: store,
            access: BookmarkVaultAccessProvider(
                vaultID: profile.id,
                bookmark: profile.bookmark,
                didRefresh: { data in
                    Task { try? await store.updateBookmark(profileID: profile.id, bookmark: data) }
                }
            ),
            privateRoot: supportDirectory
        )
    }

    func refreshVaultStatus() async {
        guard let gateway else { hasVault = false; return }
        let result = await gateway.inspect()
        hasVault = result == .usable
        vaultUnavailableName = hasVault ? nil : vaultName
        if [.missing, .bookmarkDenied, .malformedBookmark].contains(result) { onboardingRequired = true }
    }

    func makeFolderBrowser() -> VaultBrowser? {
        guard let session = onboardingSession, let bookmark = session.proposedBookmark else { return nil }
        let vaultID = session.importDiff?.vaultID ?? session.profileID ?? VaultID()
        let access = BookmarkVaultAccessProvider(vaultID: vaultID, bookmark: bookmark)
        return VaultBrowser(provider: DescriptorFolderListingProvider(access: access), generation: session.generation)
    }

    func discoverDaily(settings: ValidatedSettings, explicitLargeFileAnalysis: Bool = false) async -> DailyDiscoveryResult? {
        guard let session = onboardingSession, let bookmark = session.proposedBookmark else { return nil }
        let vaultID = session.importDiff?.vaultID ?? session.profileID ?? VaultID()
        return await DailyDiscovery.discover(
            access: BookmarkVaultAccessProvider(vaultID: vaultID, bookmark: bookmark),
            settings: settings,
            explicitLargeFileAnalysis: explicitLargeFileAnalysis
        )
    }

    func discoverDailyTemplate(explicitLargeFileAnalysis: Bool = false) async -> DailyDiscoveryResult? {
        guard let session = onboardingSession, let bookmark = session.proposedBookmark,
              let path = session.dailyTemplatePath else { return nil }
        let vaultID = session.importDiff?.vaultID ?? session.profileID ?? VaultID()
        return await DailyDiscovery.discover(
            access: BookmarkVaultAccessProvider(vaultID: vaultID, bookmark: bookmark),
            path: path, explicitLargeFileAnalysis: explicitLargeFileAnalysis
        )
    }

    func discoverSampleDaily(_ url: URL) async throws -> [DiscoveredHeading] {
        try await Task.detached(priority: .userInitiated) {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard byteCount <= DailyDocument.explicitSizeLimit else { throw DailyDocumentError.tooLarge }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            return try DailyDocument(data: data, maximumBytes: DailyDocument.explicitSizeLimit).headings
        }.value
    }

    func selectVault(_ url: URL) async throws {
        guard let store else { throw CaptureStoreError.storageUnavailable("uninitialized") }
        let bookmark = try vaultStore.saveBookmark(from: url)
        sessionGeneration += 1
        let vaultID = VaultID()
        let imported = await ObsidianConfigurationReader.read(
            access: BookmarkVaultAccessProvider(vaultID: vaultID, bookmark: bookmark)
        )
        let validatedSettings = try settings.validated()
        let base = onboardingSession?.workingSettings ?? validatedSettings
        let result = try? base.applying(imported: imported)
        let adopted = result?.0 ?? base
        let entries = result?.1.entries ?? []
        let diff = entries.isEmpty ? nil : ConfigDiff(vaultID: vaultID, baseRevision: .zero, entries: entries)
        let templatePath = imported.daily?.templatePath.flatMap {
            try? VaultRelativePath($0, kind: .file)
        }
        let session = try OnboardingSession(
            id: onboardingSession?.id ?? OnboardingSessionID(),
            generation: sessionGeneration,
            step: .inbox,
            workingSettings: adopted,
            proposedBookmark: bookmark,
            importDiff: diff,
            dailyTemplatePath: templatePath
        )
        try await store.saveOnboardingSession(session)
        onboardingSession = session
        settings = AppSettings(validated: adopted)
        vaultName = url.lastPathComponent
        hasVault = true
        onboardingRequired = true
    }

    func persistOnboarding(_ session: OnboardingSession) async throws {
        guard let store else { throw CaptureStoreError.storageUnavailable("uninitialized") }
        guard session.generation == sessionGeneration else { throw ConfigurationError.staleResult }
        try await store.saveOnboardingSession(session)
        onboardingSession = session
        settings = AppSettings(validated: session.workingSettings)
    }

    func completeOnboarding(session: OnboardingSession) async throws {
        guard let store else { throw CaptureStoreError.storageUnavailable("uninitialized") }
        var final = session
        final.step = .summary
        final.updatedAt = Date()
        try await store.saveOnboardingSession(final)
        let profileID = try await store.finishOnboarding(
            sessionID: final.id,
            profileID: final.profileID ?? VaultID(),
            displayName: vaultName ?? "Vault"
        )
        guard let saved = try await store.profile(id: profileID) else { throw CaptureStoreError.profileMissing }
        profile = saved
        onboardingSession = nil
        configurationDiff = final.importDiff
        onboardingRequired = false
        defaults.set(true, forKey: onboardingCompletedKey)
        settings = AppSettings(validated: saved.settings)
        configureGateway(saved, store: store)
        await refreshVaultStatus()
    }

    func completeOnboarding() {
        guard let session = onboardingSession else { return }
        Task { try? await completeOnboarding(session: session) }
    }
    func resolveVaultURL() throws -> URL? { try vaultStore.resolveAccessibleVault() }
    func clearVault() { Task { await resetConfiguration() } }
    func send() {
        let value = content
        Task { await sendDocument(value, inbox: false, attachments: []) { _ in } }
    }

    func sendInboxMarkdown(
        _ markdown: String,
        attachments: [EditorAttachment],
        promotedContent: String?,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        Task {
            await sendDocument(markdown, inbox: true, attachments: attachments,
                               promotedContent: promotedContent, completion: completion)
        }
    }

    private func sendDocument(
        _ markdown: String,
        inbox: Bool,
        attachments: [EditorAttachment],
        promotedContent: String? = nil,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) async {
        guard let store, let profile, let gateway else {
            status = .error("Complete vault setup before sending.")
            completion(false)
            return
        }
        let sourceDraft = draftID
        let sourceRevision = draftRevision
        do {
            status = .checkpointing
            try await checkpoint(store, markdown: markdown, id: sourceDraft, revision: sourceRevision, profileID: profile.id)
            var durableMarkdown = markdown
            var stagedIDs: [AssetID] = []
            if !attachments.isEmpty {
                guard let assetStager else { throw CaptureStoreError.storageUnavailable("stager") }
                for attachment in attachments {
                    let asset = try await assetStager.stage(
                        data: attachment.data,
                        originalName: attachment.filename,
                        declaredMediaType: attachment.mediaType,
                        draftID: sourceDraft
                    )
                    stagedIDs.append(asset.id)
                    durableMarkdown = durableMarkdown.replacingOccurrences(
                        of: attachment.token, with: "knot-asset://\(asset.id.description)"
                    )
                }
                try await checkpoint(store, markdown: durableMarkdown, id: sourceDraft,
                                     revision: sourceRevision, profileID: profile.id)
            }
            let date = Date()
            let mode = inbox ? NoteMode.inbox : (manualMode ?? RoutingPolicy(settings: profile.settings).decide(for: durableMarkdown))
            let prepared = try prepare(markdown: durableMarkdown, mode: mode, settings: profile.settings, date: date)
            let snapshot = try CaptureSnapshot(
                draftID: sourceDraft,
                draftRevision: sourceRevision,
                vaultID: profile.id,
                settingsRevision: profile.settingsRevision,
                settings: profile.settings,
                createdAt: date,
                timeZoneIdentifier: TimeZone.current.identifier,
                localeIdentifier: Locale.current.identifier,
                destination: prepared.destination,
                document: try CaptureDocument(
                    markdown: prepared.markdown,
                    representation: attachments.isEmpty ? .markdown : .blocks,
                    assetIDs: stagedIDs
                ),
                assetIDs: stagedIDs
            )
            let captureID = try await store.enqueue(snapshot)
            pendingCount = try await store.pendingCaptures().count
            status = .locallySaved(captureID)
            status = .sending(captureID)
            let receipt = try await gateway.commit(captureID: captureID)
            pendingCount = try await store.pendingCaptures().count
            if draftID == sourceDraft, draftRevision == sourceRevision,
               promotedContent == nil || content == promotedContent {
                suppressCheckpoint = true
                content = ""
                manualMode = nil
                draftID = DraftID()
                draftRevision = .zero
                suppressCheckpoint = false
            }
            status = .saved(receipt.notePath)
            completion(true)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                if let self, case .saved = self.status { self.status = .idle }
            }
        } catch {
            let pending = (try? await store.pendingCaptures()) ?? []
            pendingCount = pending.count
            if let capture = pending.last, capture.state == .needsReview {
                status = .needsReview(capture.snapshot.id, error.localizedDescription)
            } else if let capture = pending.last {
                status = .retryable(capture.snapshot.id, error.localizedDescription)
            } else {
                status = .error(error.localizedDescription)
            }
            scheduleRetryWorker()
            completion(false)
        }
    }

    private func checkpoint(
        _ store: CaptureStore, markdown: String, id: DraftID,
        revision: Revision, profileID: VaultID?
    ) async throws {
        try await store.checkpointDraft(try DraftCheckpoint(
            id: id,
            profileID: profileID,
            revision: revision,
            markdown: Data(markdown.utf8),
            routingChoice: Self.routingChoice(for: manualMode)
        ))
    }

    func flushDraft() async {
        checkpointTask?.cancel()
        guard let store else { return }
        do {
            try await checkpoint(store, markdown: content, id: draftID,
                                 revision: draftRevision, profileID: profile?.id)
            if case .checkpointing = status { status = .idle }
        } catch { status = .error(error.localizedDescription) }
    }

    private func scheduleCheckpoint() {
        checkpointTask?.cancel()
        status = .checkpointing
        let id = draftID, revision = draftRevision, markdown = content, profileID = profile?.id
        checkpointTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, let store = self.store else { return }
            do {
                try await self.checkpoint(store, markdown: markdown, id: id,
                                          revision: revision, profileID: profileID)
                if self.draftID == id, self.draftRevision == revision,
                   case .checkpointing = self.status { self.status = .idle }
            } catch { self.status = .error(error.localizedDescription) }
        }
    }

    func retry(captureID: CaptureID) {
        Task {
            guard let gateway else { return }
            do {
                status = .sending(captureID)
                status = .saved(try await gateway.commit(captureID: captureID).notePath)
                pendingCount = (try? await store?.pendingCaptures().count) ?? pendingCount
            } catch {
                status = .retryable(captureID, error.localizedDescription)
                scheduleRetryWorker()
            }
        }
    }

    func resumePendingWork() async {
        guard let store, let gateway, let profile else { return }
        let captures = (try? await store.pendingCaptures(profileID: profile.id)) ?? []
        pendingCount = captures.count
        let now = Date()
        for capture in captures {
            if let next = capture.nextAttemptAt, next > now { continue }
            do {
                let receipt = capture.state == .committing || capture.state == .needsReview
                    ? try await gateway.reconcile(captureID: capture.snapshot.id)
                    : try await gateway.commit(captureID: capture.snapshot.id)
                status = .saved(receipt.notePath)
            } catch {
                if let current = try? await store.capture(id: capture.snapshot.id), current.state == .needsReview {
                    status = .needsReview(capture.snapshot.id, error.localizedDescription)
                    break
                }
            }
        }
        pendingCount = (try? await store.pendingCaptures().count) ?? pendingCount
        scheduleRetryWorker()
    }

    func scheduleRetryWorker() {
        retryTask?.cancel()
        guard let store, let profile else { return }
        retryTask = Task { [weak self] in
            let captures = (try? await store.pendingCaptures(profileID: profile.id)) ?? []
            guard let deadline = captures.compactMap(\.nextAttemptAt).min() else { return }
            let delay = max(0, deadline.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.profile?.id == profile.id else { return }
            await self.resumePendingWork()
        }
    }

    func updateSettings(_ value: AppSettings) { Task { try? await applySettings(value) } }
    func applySettings(_ value: AppSettings, expectedRevision: Revision? = nil) async throws {
        guard let store, let profile else { throw CaptureStoreError.profileMissing }
        let validated = try value.validated()
        let revision = try await store.applySettings(
            profileID: profile.id, expectedRevision: expectedRevision ?? profile.settingsRevision, settings: validated
        )
        self.profile = VaultProfileRecord(
            id: profile.id, displayName: profile.displayName, bookmark: profile.bookmark,
            resourceIdentity: profile.resourceIdentity, settingsRevision: revision,
            settings: validated, onboardingState: profile.onboardingState
        )
        settings = value
    }
    func reimportConfiguration() async throws {
        guard let store, let profile else { throw CaptureStoreError.profileMissing }
        let imported = await ObsidianConfigurationReader.read(
            access: BookmarkVaultAccessProvider(vaultID: profile.id, bookmark: profile.bookmark)
        )
        let result = try profile.settings.applying(imported: imported)
        guard !result.1.entries.isEmpty else { configurationDiff = nil; return }
        let diff = ConfigDiff(vaultID: profile.id, baseRevision: profile.settingsRevision, entries: result.1.entries)
        try await applySettings(AppSettings(validated: result.0))
        configurationDiff = diff
        _ = store
    }

    func undoConfigurationImport() async throws {
        guard let diff = configurationDiff, let profile, diff.vaultID == profile.id else { return }
        let restored = try profile.settings.undoing(diff)
        try await applySettings(AppSettings(validated: restored))
        configurationDiff = nil
    }

    func resetAllSettings() { Task { await resetConfiguration() } }

    private func resetConfiguration() async {
        retryTask?.cancel()
        await flushDraft()
        guard let store else { return }
        do {
            sessionGeneration += 1
            let session = try await store.resetConfiguration(profileID: profile?.id, defaults: ValidatedSettings())
            profile = nil
            gateway = nil
            onboardingSession = session
            onboardingRequired = true
            hasVault = false
            vaultUnavailableName = nil
            vaultName = nil
            vaultStore.clear()
            defaults.removeObject(forKey: onboardingCompletedKey)
            settings = AppSettings(validated: session.workingSettings)
            NotificationCenter.default.post(name: .knotSettingsReset, object: nil)
        } catch { status = .error(error.localizedDescription) }
    }

    func eraseLocalDrafts() async throws -> Int {
        checkpointTask?.cancel()
        guard let store else { throw CaptureStoreError.storageUnavailable("uninitialized") }
        let erased = try await store.eraseLocalDrafts()
        suppressCheckpoint = true
        content = ""
        manualMode = nil
        draftID = DraftID()
        draftRevision = .zero
        suppressCheckpoint = false
        try await checkpoint(store, markdown: "", id: draftID, revision: .zero, profileID: profile?.id)
        status = .idle
        return erased
    }

    func prepare(
        markdown: String, mode: NoteMode, settings: ValidatedSettings, date: Date
    ) throws -> (markdown: String, destination: ResolvedDestination) {
        let zone = TimeZone.current, locale = Locale.current
        switch mode {
        case .daily:
            let rendered = settings.compiledDailyPattern.render(date: date, locale: locale, timeZone: zone)
            let path = try joinedFilePath(parent: settings.dailyFolder, formatted: rendered)
            return (markdown, .today(notePath: path, target: settings.dailyTarget))
        case .inbox:
            let rendered = settings.compiledInboxPattern.render(date: date, locale: locale, timeZone: zone)
            let path = try VaultRelativePath(rendered, kind: .file)
            let extracted = TitleExtractor.extract(from: markdown)
            let parent = try VaultRelativePath(
                components: settings.inboxFolder.components + path.parent.components, kind: .folder
            )
            return (extracted?.strippedBody ?? markdown,
                    .inbox(parent: parent, filenameStem: extracted?.filename ?? path.lastComponent ?? "Untitled"))
        }
    }

    private func joinedFilePath(parent: VaultRelativePath, formatted: String) throws -> VaultRelativePath {
        let path = try VaultRelativePath(formatted, kind: .file)
        guard let leaf = path.lastComponent else { throw PathValidationError.emptyFilename }
        return try VaultRelativePath(
            components: parent.components + path.parent.components + [leaf.hasSuffix(".md") ? leaf : leaf + ".md"],
            kind: .file
        )
    }

    private static func routingChoice(for mode: NoteMode?) -> RoutingChoice {
        switch mode { case nil: .automatic; case .daily: .today; case .inbox: .inbox }
    }
    private static func noteMode(for choice: RoutingChoice) -> NoteMode? {
        switch choice { case .automatic: nil; case .today: .daily; case .inbox: .inbox }
    }
}

extension Notification.Name {
    static let knotSettingsReset = Notification.Name("knot.settingsReset")
}
