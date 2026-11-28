import Foundation
import KnotCore
import Observation

/// The text and deletion details shown for one recoverable note or segment.
public struct DeletedItemRow: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case note
        case segment
    }

    public let id: RestoreTarget
    public let title: String
    public let kind: Kind
    public let parentNoteTitle: String?
    public let deletedAt: Date

    init(_ item: DeletedItem) {
        id = item.restoreTarget
        deletedAt = item.deletedAt

        switch item {
        case .note(let record, _):
            kind = .note
            parentNoteTitle = nil
            let segments = record.segments.filter { segment in
                guard segment.isLiveCapture else { return false }
                switch segment.state {
                case .typed(.discarded), .voice(.discarded), .ink(.discarded): return false
                default: return true
                }
            }
            if let noteTitle = record.note.title, !CaptureText.isEmpty(noteTitle) {
                title = noteTitle
            } else if let first = segments.first(where: { !CaptureText.isEmpty($0.text) }) {
                title = StreamRowModel.excerpt(StreamRowModel.firstLine(of: first.text))
            } else {
                title = StreamRowModel.holding(segments)
            }
        case .segment(let segment, let noteTitle, _):
            kind = .segment
            parentNoteTitle = noteTitle.flatMap { CaptureText.isEmpty($0) ? nil : $0 }
            title =
                CaptureText.isEmpty(segment.text)
                ? segment.kind.holding(duration: segment.duration) : StreamRowModel.excerpt(segment.text)
        }
    }

    public func daysRemaining(at now: Date) -> Int {
        // The purge uses elapsed 24-hour days. Round up while any part of a day remains.
        let elapsedDays = max(0, now.timeIntervalSince(deletedAt) / 86_400)
        return Int(max(0, (Double(Limits.keptForDays) - elapsedDays).rounded(.up)))
    }
}

/// Feedback from the last restore attempt, kept until dismissed or another restore starts.
public enum RestoreNotice: Hashable, Sendable {
    case restored
    case failed(StoreProblem)

    var announcement: Announcement {
        switch self {
        case .restored: .itemRestored
        case .failed: .itemRestoreFailed
        }
    }
}

@MainActor @Observable public final class RecentlyDeletedViewModel {
    public private(set) var items: [DeletedItemRow] = []
    public private(set) var isLoaded = false
    /// A failed read. Restore feedback is kept separately so a store signal cannot clear it.
    public private(set) var problem: StoreProblem?
    public private(set) var restoring: RestoreTarget?
    public private(set) var notice: RestoreNotice?

    private let environment: AppEnvironment
    private let announcer: any Announcer
    @ObservationIgnored private var readGeneration = 0

    public init(environment: AppEnvironment, announcer: any Announcer = VoiceOverAnnouncer()) {
        self.environment = environment
        self.announcer = announcer
    }

    var now: Date { environment.clock.now() }

    public func refresh() async {
        guard !Task.isCancelled else { return }
        readGeneration += 1
        let generation = readGeneration
        defer {
            if generation == readGeneration, !Task.isCancelled { isLoaded = true }
        }
        do {
            let deleted = try await environment.notes.recentlyDeleted()
            guard generation == readGeneration, !Task.isCancelled else { return }
            items = deleted.map(DeletedItemRow.init)
            problem = nil
        } catch {
            guard generation == readGeneration, !Task.isCancelled else { return }
            problem = StoreProblem(error)
        }
    }

    public func observeStore() async {
        let signals = environment.notes.changeSignals()
        // Read after subscribing so a write during the view's initial read is seen too.
        await refresh()
        for await _ in signals {
            await refresh()
        }
    }

    public func restore(_ target: RestoreTarget) async {
        guard restoring == nil, items.contains(where: { $0.id == target }) else { return }
        restoring = target
        notice = nil
        defer { restoring = nil }

        let feedback: RestoreNotice
        do {
            _ = try await environment.notes.restore(target)
            items.removeAll { $0.id == target }
            feedback = .restored
        } catch {
            feedback = .failed(StoreProblem(error))
        }
        notice = feedback
        announcer.announce(feedback.announcement)
        await refresh()
    }

    public func dismissNotice() {
        notice = nil
    }
}
