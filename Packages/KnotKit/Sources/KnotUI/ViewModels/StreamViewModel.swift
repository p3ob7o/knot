import Foundation
import KnotCore
import Observation

/// The stream says once that captures arrived, with a way to go to them
/// (docs/product-spec.md §7).
public struct ArrivalNotice: Hashable, Sendable {
    /// The notes that hold an arrived capture, newest first.
    public var notes: [NoteID]

    public var message: String {
        notes.count == 1 ? localized("A capture arrived.") : localized("\(notes.count) captures arrived.")
    }
}

/// What the empty stream shows on first run (docs/product-spec.md §12).
public struct FirstRunContent: Hashable, Sendable {
    /// The line about sync, or `nil` for none.
    public var syncLine: String?
    /// Up to three dismissible rows on setting up a way to capture (assumption A29).
    public var setupRows: [SetupRow]
}

/// The stream: every note, newest first, a page at a time.
@MainActor
@Observable
public final class StreamViewModel {
    public private(set) var rows: [StreamRowModel] = []
    /// True while more pages wait after the last one read.
    public private(set) var hasMore = false
    /// True until the first page has been read or has failed.
    public private(set) var isLoading = true
    /// What is wrong when the notes cannot be read. Capture still works meanwhile.
    public private(set) var problem: StoreProblem?
    public private(set) var arrival: ArrivalNotice?
    /// What the stream shows while it is empty, or `nil` when it has notes or cannot read them.
    public private(set) var firstRun: FirstRunContent?
    /// The first-run case of sync, read with the settings.
    public private(set) var sync: FirstRunSync = .notAvailable

    public let pageSize: Int
    private let environment: AppEnvironment
    private let context: UIContext
    private var setupRows: [SetupRow]
    private let onDismissSetupRow: @Sendable (SetupRow) -> Void
    private var next: StreamPosition?
    private var pages = 1
    /// The notes whose arrivals the stream has already told the person about.
    private var announced: Set<NoteID> = []
    private var speech: TranscriberReadiness = .ready

    /// - Parameters:
    ///   - setupRows: the setup rows that apply on this device and are not dismissed yet. At
    ///     most three are shown.
    ///   - onDismissSetupRow: keeps a dismissal, which the app shell stores in its own settings.
    public init(
        environment: AppEnvironment, context: UIContext, setupRows: [SetupRow] = [], pageSize: Int = 50,
        onDismissSetupRow: @escaping @Sendable (SetupRow) -> Void = { _ in }
    ) {
        self.environment = environment
        self.context = context
        self.setupRows = Array(setupRows.prefix(3))
        self.pageSize = max(1, pageSize)
        self.onDismissSetupRow = onDismissSetupRow
    }

    /// Reads the stream again from its start, as many pages as were read before.
    public func load() async {
        speech = await environment.transcriber.readiness()
        let settings = (try? await environment.settings.load()) ?? .defaults
        sync = FirstRunSync.resolve(sync: context.sync, settings: settings, gates: environment.gates)
        var read: [NoteRecord] = []
        var position: StreamPosition?
        do {
            for _ in 0..<pages {
                let page = try await environment.notes.stream(after: position, limit: pageSize)
                read += page.notes
                position = page.next
                if position == nil { break }
            }
        } catch {
            isLoading = false
            problem = StoreProblem(error)
            firstRun = nil
            return
        }
        problem = nil
        isLoading = false
        next = position
        hasMore = position != nil
        apply(read)
    }

    /// Reads the next page.
    public func loadMore() async {
        guard let next else { return }
        do {
            let page = try await environment.notes.stream(after: next, limit: pageSize)
            pages += 1
            self.next = page.next
            hasMore = page.next != nil
            let known = Set(rows.map(\.id))
            rows += page.notes.filter { !known.contains($0.note.id) }.map(row)
        } catch {
            problem = StoreProblem(error)
        }
    }

    /// Reads the stream again after each change the store publishes.
    public func observeChanges() async {
        for await _ in environment.notes.changeSignals() {
            await load()
        }
    }

    /// The person saw the notice: the stream does not say it again for these captures.
    public func dismissArrivalNotice() {
        announced.formUnion(arrival?.notes ?? [])
        arrival = nil
    }

    public func dismissSetupRow(_ row: SetupRow) {
        setupRows.removeAll { $0 == row }
        onDismissSetupRow(row)
        if firstRun != nil { firstRun = FirstRunContent(syncLine: sync.line, setupRows: setupRows) }
    }

    private func row(_ record: NoteRecord) -> StreamRowModel {
        StreamRowModel(record, thisDevice: context.thisDevice, speech: speech)
    }

    private func apply(_ records: [NoteRecord]) {
        rows = records.map(row)
        firstRun = rows.isEmpty ? FirstRunContent(syncLine: sync.line, setupRows: setupRows) : nil
        let arrived = rows.filter(\.hasArrived).map(\.id)
        // A note opened since clears its marks, and leaves the notice.
        announced.formIntersection(arrived)
        let fresh = arrived.filter { !announced.contains($0) }
        arrival = fresh.isEmpty ? nil : ArrivalNotice(notes: fresh)
    }
}
