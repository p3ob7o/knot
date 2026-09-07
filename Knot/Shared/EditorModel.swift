import Foundation
import Observation
import SwiftUI
import KnotKit

struct EditorAttachment: Sendable, Equatable {
    let token: String
    let filename: String
    let data: Data
}

@MainActor
@Observable
final class EditorModel {

    // MARK: - State the views observe

    var content: String = ""
    var manualMode: NoteMode? = nil
    var status: Status = .idle
    var settings: AppSettings = AppSettings.load()
    var vaultName: String? = nil
    var vaultUnavailableName: String? = nil
    var onboardingRequired: Bool = false
    private(set) var hasVault: Bool = false
    var lastImport: VaultImportResult? = nil

    enum Status: Equatable {
        case idle
        case sending
        case sent
        case error(String)
    }

    enum VaultImportResult: Equatable {
        case imported(ImportedVaultConfig, previous: AppSettings)
        case noConfigFound
    }

    // MARK: - Dependencies

    private let vaultStore: VaultStore
    private let queue: Queue?
    private let defaults: UserDefaults
    private let onboardingCompletedKey = "knot.onboarding.completed"

    // MARK: - Init

    init(vaultStore: VaultStore = VaultStore(), defaults: UserDefaults = .standard) {
        self.vaultStore = vaultStore
        self.defaults = defaults
        // Persist any failed writes inside the app's Application Support
        // folder so they survive relaunches.
        let queueDir = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Knot", directoryHint: .isDirectory)) ?? FileManager.default.temporaryDirectory
        self.queue = try? Queue(directory: queueDir)
        refreshVaultStatus()
        seedOnboardingState()
    }

    // MARK: - Derived

    var resolvedMode: NoteMode {
        manualMode ?? RoutingPolicy(settings: settings).decide(for: content)
    }

    var canSend: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        hasVault &&
        (status != .sending)
    }

    var shouldShowOnboarding: Bool {
        onboardingRequired || !hasVault
    }

    // MARK: - Vault

    func refreshVaultStatus() {
        let hadBookmark = vaultStore.hasBookmark
        do {
            let resolved = try vaultStore.resolveAccessibleVault()
            hasVault = resolved != nil
            vaultUnavailableName = resolved == nil && hadBookmark ? vaultStore.vaultName : nil
        } catch {
            hasVault = false
            vaultUnavailableName = hadBookmark ? vaultStore.vaultName : nil
        }
        vaultName = vaultStore.vaultName
        if vaultUnavailableName != nil {
            onboardingRequired = true
        }
    }

    @discardableResult
    func setVault(url: URL) throws -> VaultImportResult {
        try vaultStore.saveBookmark(from: url)

        let imported = ObsidianConfigImporter.readVaultConfig(vaultURL: url)
        guard imported.daily != nil || imported.attachment != nil else {
            refreshVaultStatus()
            return .noConfigFound
        }

        let previous = settings
        var merged = settings
        if let daily = imported.daily {
            merged.dailyFolder = daily.folder
            merged.dailyFilenameFormat = daily.filenameFormat
        }
        if let attachment = imported.attachment {
            merged.attachmentFolderPath = attachment.attachmentFolderPath
        }

        guard merged != previous else {
            refreshVaultStatus()
            return .noConfigFound
        }

        updateSettings(merged)
        let result: VaultImportResult = .imported(imported, previous: previous)
        lastImport = result
        refreshVaultStatus()
        return result
    }

    func resolveVaultURL() throws -> URL? {
        try vaultStore.resolveAccessibleVault()
    }

    func undoLastImport() {
        if case .imported(_, let previous) = lastImport {
            updateSettings(previous)
        }
        lastImport = nil
    }

    func dismissLastImport() {
        lastImport = nil
    }

    func clearVault() {
        vaultStore.clear()
        lastImport = nil
        defaults.removeObject(forKey: onboardingCompletedKey)
        onboardingRequired = true
        refreshVaultStatus()
    }

    // MARK: - Send

    func send() {
        guard canSend else { return }
        let note = Note(
            content: content,
            mode: resolvedMode,
            createdAt: Date()
        )
        let savedSettings = settings

        // Resolve the bookmark on the main actor up-front; the actual write
        // happens off the main thread so file coordination doesn't block UI.
        let url: URL
        do {
            guard let resolved = try vaultStore.resolveAccessibleVault() else {
                refreshVaultStatus()
                status = .error(VaultError.noVaultConfigured.localizedDescription)
                return
            }
            url = resolved
        } catch {
            status = .error(error.localizedDescription)
            return
        }

        status = .sending
        let savedQueue = queue

        Task.detached { [weak self] in
            do {
                let vault = Vault(url: url, settings: savedSettings)
                _ = try vault.write(note: note)
                await self?.handleWriteSucceeded()
            } catch {
                try? savedQueue?.enqueue(note)
                await self?.handleWriteFailed(message: error.localizedDescription)
            }
        }
    }

    func sendInboxMarkdown(
        _ markdown: String,
        attachments: [EditorAttachment],
        promotedContent: String?,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, hasVault, status != .sending else {
            completion(false)
            return
        }

        let note = Note(
            content: trimmed,
            mode: .inbox,
            createdAt: Date()
        )
        let savedSettings = settings

        let url: URL
        do {
            guard let resolved = try vaultStore.resolveAccessibleVault() else {
                refreshVaultStatus()
                status = .error(VaultError.noVaultConfigured.localizedDescription)
                completion(false)
                return
            }
            url = resolved
        } catch {
            status = .error(error.localizedDescription)
            completion(false)
            return
        }

        status = .sending
        let savedQueue = queue

        Task.detached { [weak self] in
            var queueNote = note
            do {
                let inbox = InboxWriter(vault: url, settings: savedSettings)
                let planned = try inbox.makePlan(for: note)
                let attachmentWriter = AttachmentWriter(vault: url, settings: savedSettings)
                var body = planned.body

                for attachment in attachments {
                    let result = try attachmentWriter.write(AttachmentWriteRequest(
                        filename: attachment.filename,
                        data: attachment.data,
                        noteURL: planned.fileURL
                    ))
                    body = body.replacingOccurrences(
                        of: attachment.token,
                        with: result.markdownEmbed
                    )
                }

                queueNote = Note(
                    id: note.id,
                    content: body,
                    mode: .inbox,
                    createdAt: note.createdAt
                )
                try inbox.write(InboxWritePlan(fileURL: planned.fileURL, body: body))
                await self?.handleInboxWriteSucceeded(
                    promotedContent: promotedContent,
                    completion: completion
                )
            } catch {
                try? savedQueue?.enqueue(queueNote)
                await self?.handleWriteFailed(
                    message: error.localizedDescription,
                    completion: completion
                )
            }
        }
    }

    @MainActor
    private func handleWriteSucceeded() {
        content = ""
        manualMode = nil
        status = .sent
        lastImport = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            if case .sent = self.status {
                self.status = .idle
            }
        }
    }

    @MainActor
    private func handleWriteFailed(message: String) {
        status = .error(message)
    }

    @MainActor
    private func handleInboxWriteSucceeded(
        promotedContent: String?,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        if let promotedContent {
            if content == promotedContent {
                content = ""
            }
        } else {
            content = ""
        }
        manualMode = nil
        status = .sent
        lastImport = nil
        completion(true)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            if case .sent = self.status {
                self.status = .idle
            }
        }
    }

    @MainActor
    private func handleWriteFailed(
        message: String,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        status = .error(message)
        completion(false)
    }

    // MARK: - Settings

    func updateSettings(_ newValue: AppSettings) {
        settings = newValue
        newValue.save()
    }

    func completeOnboarding() {
        defaults.set(true, forKey: onboardingCompletedKey)
        onboardingRequired = false
        vaultUnavailableName = nil
        refreshVaultStatus()
    }

    /// Wipes everything the model knows how to persist and resets in-memory
    /// state to factory defaults: clears the vault bookmark, drops the saved
    /// AppSettings JSON, and broadcasts `.knotSettingsReset` so platform code
    /// can clean up the bits the model doesn't own (the global shortcut and
    /// the detached-window state on macOS). Useful for re-running the
    /// onboarding flow without manually editing UserDefaults.
    func resetAllSettings() {
        UserDefaults.standard.removeObject(forKey: AppSettings.userDefaultsKey)
        defaults.removeObject(forKey: onboardingCompletedKey)
        vaultStore.clear()
        settings = AppSettings()
        manualMode = nil
        content = ""
        status = .idle
        lastImport = nil
        onboardingRequired = true
        refreshVaultStatus()
        NotificationCenter.default.post(name: .knotSettingsReset, object: nil)
    }

    private func seedOnboardingState() {
        if let completed = defaults.object(forKey: onboardingCompletedKey) as? Bool {
            onboardingRequired = !completed || !hasVault
        } else {
            // Existing users upgrading with a reachable vault should keep the
            // editor-first behavior they already had.
            onboardingRequired = !hasVault
        }
        if vaultUnavailableName != nil {
            onboardingRequired = true
        }
    }
}

extension Notification.Name {
    /// Broadcast by `EditorModel.resetAllSettings()`. Platforms observe it
    /// to clear their own UserDefaults keys.
    static let knotSettingsReset = Notification.Name("knot.settingsReset")
}
