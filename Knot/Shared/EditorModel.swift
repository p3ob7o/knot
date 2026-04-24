import Foundation
import Observation
import SwiftUI
import KnotKit

@MainActor
@Observable
final class EditorModel {

    // MARK: - State the views observe

    var content: String = ""
    var manualMode: NoteMode? = nil
    var status: Status = .idle
    var settings: AppSettings = AppSettings.load()
    var vaultName: String? = nil
    private(set) var hasVault: Bool = false

    enum Status: Equatable {
        case idle
        case sending
        case sent
        case error(String)
    }

    // MARK: - Dependencies

    private let vaultStore: VaultStore
    private let queue: Queue?

    // MARK: - Init

    init(vaultStore: VaultStore = VaultStore()) {
        self.vaultStore = vaultStore
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

    // MARK: - Vault

    func refreshVaultStatus() {
        hasVault = vaultStore.hasVault
        vaultName = vaultStore.vaultName
    }

    func setVault(url: URL) throws {
        try vaultStore.saveBookmark(from: url)
        refreshVaultStatus()
    }

    func clearVault() {
        vaultStore.clear()
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
            guard let resolved = try vaultStore.resolveBookmark() else {
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

    @MainActor
    private func handleWriteSucceeded() {
        content = ""
        manualMode = nil
        status = .sent
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

    // MARK: - Settings

    func updateSettings(_ newValue: AppSettings) {
        settings = newValue
        newValue.save()
    }

}
