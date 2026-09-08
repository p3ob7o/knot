import AppKit
import KnotKit
import SwiftUI

struct RecoveryEntry: Identifiable, Sendable {
    enum Kind: Sendable { case draft(DraftID); case capture(CaptureID) }
    let id: String
    let kind: Kind
    let vault: String
    let date: Date
    let destination: String
    let state: String
    let excerpt: String
}

@MainActor
extension EditorModel {
    func recoveryEntries() async -> [RecoveryEntry] {
        guard let store else { return [] }
        do {
            let drafts = try await store.recoverableDrafts().compactMap { draft -> RecoveryEntry? in
                guard !draft.markdown.isEmpty,
                      let text = String(data: draft.markdown, encoding: .utf8) else { return nil }
                return RecoveryEntry(
                    id: "draft-\(draft.id.description)", kind: .draft(draft.id),
                    vault: draft.profileID == profile?.id ? (vaultName ?? "Current vault") : "Inactive vault",
                    date: draft.updatedAt, destination: draft.routingChoice.rawValue.capitalized,
                    state: draft.state.rawValue, excerpt: Self.recoveryExcerpt(text)
                )
            }
            let captures = try await store.pendingCaptures().map { capture in
                RecoveryEntry(
                    id: "capture-\(capture.snapshot.id.description)", kind: .capture(capture.snapshot.id),
                    vault: capture.snapshot.vaultID == profile?.id ? (vaultName ?? "Current vault") : "Inactive vault",
                    date: capture.snapshot.createdAt,
                    destination: Self.destinationLabel(capture.snapshot.destination),
                    state: capture.state.rawValue,
                    excerpt: Self.recoveryExcerpt(capture.snapshot.document.markdown)
                )
            }
            return (drafts + captures).sorted { $0.date > $1.date }
        } catch {
            status = .error(error.localizedDescription)
            return []
        }
    }

    func reopenRecoveryDraft(_ id: DraftID) async throws {
        await flushDraft()
        guard let store, let draft = try await store.draft(id: id) else { throw CaptureStoreError.draftMissing }
        guard draft.profileID == nil || draft.profileID == profile?.id else { throw CaptureStoreError.profileMissing }
        guard let markdown = String(data: draft.markdown, encoding: .utf8) else { throw CaptureStoreError.corruptRecord }
        suppressCheckpoint = true
        content = markdown
        draftID = draft.id
        draftRevision = draft.revision
        switch draft.routingChoice {
        case .automatic: manualMode = nil
        case .today: manualMode = .daily
        case .inbox: manualMode = .inbox
        }
        suppressCheckpoint = false
    }

    func cancelRecoveryCapture(_ id: CaptureID) async throws {
        guard let store else { throw CaptureStoreError.storageUnavailable("uninitialized") }
        try await store.cancelCapture(id: id)
        pendingCount = try await store.pendingCaptures().count
    }

    func markRecoveryCaptureAlreadySaved(_ id: CaptureID) async throws {
        guard let store else { throw CaptureStoreError.storageUnavailable("uninitialized") }
        try await store.resolveNeedsReviewAsSaved(captureID: id)
        pendingCount = try await store.pendingCaptures().count
        status = .idle
    }

    func retryRecoveryCaptureAsNew(_ id: CaptureID) async throws {
        guard let store else { throw CaptureStoreError.storageUnavailable("uninitialized") }
        let newID = try await store.retryNeedsReviewAsNew(captureID: id)
        pendingCount = try await store.pendingCaptures().count
        retry(captureID: newID)
    }

    func exportRecoveryData(_ entry: RecoveryEntry) async throws -> Data {
        guard let store else { throw CaptureStoreError.storageUnavailable("uninitialized") }
        switch entry.kind {
        case .draft(let id):
            guard let draft = try await store.draft(id: id) else { throw CaptureStoreError.draftMissing }
            return draft.markdown
        case .capture(let id):
            return try await store.exportableMarkdown(captureID: id)
        }
    }

    private static func destinationLabel(_ destination: ResolvedDestination) -> String {
        switch destination {
        case .today(let path, _): "Today: \(path.string)"
        case .inbox(let parent, _): parent.isRoot ? "Inbox" : "Inbox: \(parent.string)"
        }
    }

    private static func recoveryExcerpt(_ text: String) -> String {
        String(text.replacingOccurrences(of: "\n", with: " ").prefix(140))
    }
}

struct RecoveryView: View {
    @Bindable var model: EditorModel
    @State private var entries: [RecoveryEntry] = []
    @State private var selectedID: String?
    @State private var errorMessage: String?
    @State private var retryAsNewConfirmation: CaptureID?

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                ContentUnavailableView("No recoverable work", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries, selection: $selectedID) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.destination).font(.headline).lineLimit(1)
                            Spacer()
                            Text(entry.state).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(entry.excerpt).lineLimit(2)
                        HStack {
                            Text(entry.vault)
                            Text(entry.date, style: .relative)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(entry.id)
                    .accessibilityElement(children: .combine)
                }
            }
            Divider()
            HStack {
                if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Button("Export", systemImage: "square.and.arrow.up") { Task { await exportSelected() } }
                    .disabled(selected == nil)
                if case .capture(let id) = selected?.kind {
                    if selected?.state == CaptureState.needsReview.rawValue {
                        Button("Mark Already Saved") { Task { await markSaved(id) } }
                        Button("Retry As New") { retryAsNewConfirmation = id }
                    } else {
                        Button("Retry") { model.retry(captureID: id) }
                    }
                    Button("Cancel Capture", role: .destructive) { Task { await cancel(id) } }
                }
                if case .draft(let id) = selected?.kind {
                    Button("Reopen") { Task { await reopen(id) } }
                }
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 360)
        .task { await reload() }
        .alert("Retry as a new capture?", isPresented: Binding(
            get: { retryAsNewConfirmation != nil },
            set: { if !$0 { retryAsNewConfirmation = nil } }
        )) {
            Button("Retry As New") {
                guard let id = retryAsNewConfirmation else { return }
                retryAsNewConfirmation = nil
                Task { await retryAsNew(id) }
            }
            Button("Cancel", role: .cancel) { retryAsNewConfirmation = nil }
        } message: {
            Text("Use this only after checking the target. If the earlier write succeeded, retrying can create duplicate content.")
        }
    }

    private var selected: RecoveryEntry? { entries.first { $0.id == selectedID } }
    private func reload() async { entries = await model.recoveryEntries() }
    private func reopen(_ id: DraftID) async {
        do { try await model.reopenRecoveryDraft(id); await reload() }
        catch { errorMessage = error.localizedDescription }
    }
    private func markSaved(_ id: CaptureID) async {
        do { try await model.markRecoveryCaptureAlreadySaved(id); await reload() }
        catch { errorMessage = error.localizedDescription }
    }
    private func retryAsNew(_ id: CaptureID) async {
        do { try await model.retryRecoveryCaptureAsNew(id); await reload() }
        catch { errorMessage = error.localizedDescription }
    }
    private func cancel(_ id: CaptureID) async {
        do { try await model.cancelRecoveryCapture(id); await reload() }
        catch { errorMessage = error.localizedDescription }
    }
    private func exportSelected() async {
        guard let selected else { return }
        do {
            let data = try await model.exportRecoveryData(selected)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Knot-Recovery.md"
            panel.allowedContentTypes = [.plainText]
            guard await panel.begin() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: [.atomic])
        } catch { errorMessage = error.localizedDescription }
    }
}
