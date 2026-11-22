import Foundation
import KnotCore
import KnotStore
import Synchronization

/// The store as the live environment holds it before, while and after the launch opens it
/// (docs/architecture.md §6, rule 6, and §13).
///
/// The capture surface is on screen before the launch steps run, and opening the store is the
/// first of them, so the environment's store ports exist before the store does. Each call goes
/// to the opened store once it is open. Before that, and while it migrates, a call fails at
/// once with `store_not_open`, so the engine never waits for the store: its capture takes
/// `Inbox/`, and ingest stores it once the store is open. A store that did not open fails each
/// call with the error it failed with, and the stream says what is wrong.
public final class StoreGate: Sendable {
    /// The store's ports, as `KnotStoreLive.wire(_:store:)` put them in an environment.
    public struct Ports: Sendable {
        public let opened: OpenedStore
        public let notes: any NoteStore
        public let assets: any AssetStore
        public let settings: any SettingsStore
        public let fetcher: any AssetFetcher

        init(opened: OpenedStore) {
            let wired = KnotStoreLive.wire(.unavailable, store: opened)
            self.opened = opened
            notes = wired.notes
            assets = wired.assets
            settings = wired.settings
            fetcher = wired.fetcher
        }
    }

    /// Where the store stands.
    public enum Phase: Sendable {
        case opening
        case open(Ports)
        case failed(KnotError)
    }

    private struct State {
        var phase: Phase = .opening
        var waiters: [CheckedContinuation<Ports?, Never>] = []
    }

    private let state = Mutex(State())

    public init() {}

    public var phase: Phase { state.withLock { $0.phase } }

    /// The opened store's ports, or the error a call fails with now.
    public func ports() throws(KnotError) -> Ports {
        switch phase {
        case .opening: throw KnotError.storeNotOpen
        case .open(let ports): return ports
        case .failed(let error): throw error
        }
    }

    /// Waits until the store has opened, or `nil` once it failed to.
    public func opened() async -> Ports? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Ports?, Never>) in
            let ready: Ports?? = state.withLock { state in
                switch state.phase {
                case .opening:
                    state.waiters.append(continuation)
                    return nil
                case .open(let ports): return .some(ports)
                case .failed: return .some(nil)
                }
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func open(_ opened: OpenedStore) -> Ports {
        let ports = Ports(opened: opened)
        settle(.open(ports), with: ports)
        return ports
    }

    func fail(_ error: KnotError) {
        settle(.failed(error), with: nil)
    }

    private func settle(_ phase: Phase, with ports: Ports?) {
        let waiters = state.withLock { state -> [CheckedContinuation<Ports?, Never>] in
            guard case .opening = state.phase else { return [] }
            state.phase = phase
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: ports) }
    }

    /// A stream that begins once the store has opened: the elements `source` gives then.
    func relay<Element: Sendable>(_ source: @escaping @Sendable (Ports) async -> AsyncStream<Element>)
        -> AsyncStream<Element>
    {
        AsyncStream { continuation in
            let task = Task {
                guard let ports = await self.opened() else {
                    continuation.finish()
                    return
                }
                for await element in await source(ports) {
                    continuation.yield(element)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// `NoteStore` through the gate. Searches and note reads are timed for the diagnostics.
struct GatedNoteStore: NoteStore {
    let gate: StoreGate
    let timings: SignpostTimings

    private func notes() throws(KnotError) -> any NoteStore { try gate.ports().notes }

    func cursor() async throws(KnotError) -> StoreCursor { try await notes().cursor() }

    /// The cursor once the store opens, so that a view that read nothing before reads again,
    /// then every signal the store gives.
    func changeSignals() -> AsyncStream<StoreCursor> {
        gate.relay { ports in
            Self.fromOpening(subscribe: { ports.notes.changeSignals() }, current: { try? await ports.notes.cursor() })
        }
    }

    /// The store's current value once it opens, so that a view that read nothing before reads
    /// again, then every signal after it. It subscribes before it reads the value, so a commit
    /// that lands while the value is read, as recovery's ingest of a line typed before a kill
    /// can, is signalled and never missed.
    static func fromOpening<Element: Sendable>(
        subscribe: @escaping @Sendable () -> AsyncStream<Element>,
        current: @escaping @Sendable () async -> Element?
    ) -> AsyncStream<Element> {
        AsyncStream { continuation in
            let signals = subscribe()
            let task = Task {
                if let value = await current() { continuation.yield(value) }
                for await signal in signals { continuation.yield(signal) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func predictPlacement(_ request: AppendRequest, kind: SegmentKind, surface: CaptureSurface) async throws(KnotError)
        -> AppendDecision
    {
        try await notes().predictPlacement(request, kind: kind, surface: surface)
    }

    func record(_ capture: NewCapture) async throws(KnotError) -> CaptureReceipt {
        try await notes().record(capture)
    }

    func ingest(_ capture: NewCapture) async throws(KnotError) -> IngestResult {
        try await notes().ingest(capture)
    }

    func recordKeptItem(_ item: KeptInboxItem) async throws(KnotError) -> IngestResult {
        try await notes().recordKeptItem(item)
    }

    func checkpoint(_ checkpoint: CaptureCheckpoint) async throws(KnotError) -> CheckpointResult {
        try await notes().checkpoint(checkpoint)
    }

    func end(_ end: CaptureEnd) async throws(KnotError) -> CaptureReceipt {
        try await notes().end(end)
    }

    func openCaptures() async throws(KnotError) -> [Capture] { try await notes().openCaptures() }

    func capture(_ id: CaptureID) async throws(KnotError) -> Capture? { try await notes().capture(id) }

    func note(_ id: NoteID) async throws(KnotError) -> NoteRecord? {
        let interval = timings.begin(.noteOpened)
        defer { interval.end() }
        return try await notes().note(id)
    }

    func segment(_ id: SegmentID) async throws(KnotError) -> SegmentRead? { try await notes().segment(id) }

    func keptFiles(of capture: CaptureID) async throws(KnotError) -> [KeptFile] {
        try await notes().keptFiles(of: capture)
    }

    func asset(_ id: AssetID) async throws(KnotError) -> Asset? { try await notes().asset(id) }

    func stream(after position: StreamPosition?, limit: Int) async throws(KnotError) -> StreamPage {
        try await notes().stream(after: position, limit: limit)
    }

    func search(_ query: String, limit: Int) async throws(KnotError) -> [NoteID] {
        let interval = timings.begin(.searchResults)
        defer { interval.end() }
        return try await notes().search(query, limit: limit)
    }

    func changes(after cursor: StoreCursor?, limit: Int) async throws(KnotError) -> ChangePage {
        try await notes().changes(after: cursor, limit: limit)
    }

    func replaceText(_ replacement: TextReplacement) async throws(KnotError) -> TextReplacementResult {
        try await notes().replaceText(replacement)
    }

    func setTitle(_ title: String?, of note: NoteID, ifRevision: StampedRevision?) async throws(KnotError) -> NoteRead {
        try await notes().setTitle(title, of: note, ifRevision: ifRevision)
    }

    func delete(_ target: StoreTarget) async throws(KnotError) -> StoreCursor { try await notes().delete(target) }

    func restore(_ target: RestoreTarget) async throws(KnotError) -> StoreCursor { try await notes().restore(target) }

    func removeRecording(of segment: SegmentID) async throws(KnotError) -> Asset {
        try await notes().removeRecording(of: segment)
    }

    func clearArrivalMarks(in note: NoteID) async throws(KnotError) { try await notes().clearArrivalMarks(in: note) }

    func move(_ segment: SegmentID, from note: NoteID) async throws(KnotError) -> MoveResult {
        try await notes().move(segment, from: note)
    }

    func returnToFormerNote(_ segment: SegmentID, from note: NoteID) async throws(KnotError) -> MoveOutcome {
        try await notes().returnToFormerNote(segment, from: note)
    }

    func setState(_ state: SegmentState, of segment: SegmentID) async throws(KnotError) -> SegmentRead {
        try await notes().setState(state, of: segment)
    }

    func appendTranscript(_ run: TranscriptionRun, to segment: SegmentID, job: JobID) async throws(KnotError)
        -> SegmentRead
    {
        try await notes().appendTranscript(run, to: segment, job: job)
    }

    func applyCleanup(_ result: CleanupResult, to segment: SegmentID) async throws(KnotError) -> CleanupApplied {
        try await notes().applyCleanup(result, to: segment)
    }

    func applyRecognition(_ recognition: InkRecognition, to segment: SegmentID) async throws(KnotError)
        -> SegmentRead
    {
        try await notes().applyRecognition(recognition, to: segment)
    }

    @discardableResult
    func saveJob(_ job: Job) async throws(KnotError) -> Job { try await notes().saveJob(job) }

    func jobs(for segment: SegmentID?) async throws(KnotError) -> [Job] { try await notes().jobs(for: segment) }

    func purge(before date: Date) async throws(KnotError) -> PurgeResult { try await notes().purge(before: date) }
}

/// `AssetStore` through the gate.
struct GatedAssetStore: AssetStore {
    let gate: StoreGate

    private func assets() throws(KnotError) -> any AssetStore { try gate.ports().assets }

    func place(_ data: Data, as asset: AssetID, kind: AssetKind) async throws(KnotError) -> StoredFile {
        try await assets().place(data, as: asset, kind: kind)
    }

    func move(_ source: URL, as asset: AssetID, kind: AssetKind) async throws(KnotError) -> StoredFile {
        try await assets().move(source, as: asset, kind: kind)
    }

    func find(_ asset: AssetID, kind: AssetKind) async throws(KnotError) -> StoredFile? {
        try await assets().find(asset, kind: kind)
    }

    func verify(_ asset: AssetID, kind: AssetKind, sha256: String) async throws(KnotError) {
        try await assets().verify(asset, kind: kind, sha256: sha256)
    }

    func remove(_ asset: AssetID, kind: AssetKind) async throws(KnotError) {
        try await assets().remove(asset, kind: kind)
    }
}

/// `SettingsStore` through the gate. Its changes begin once the store has opened.
struct GatedSettingsStore: SettingsStore {
    let gate: StoreGate

    func load() async throws(KnotError) -> Settings { try await gate.ports().settings.load() }

    func save(_ settings: Settings) async throws(KnotError) { try await gate.ports().settings.save(settings) }

    func changes() -> AsyncStream<Settings> { gate.relay { $0.settings.changes() } }
}

/// The local-only `AssetFetcher` through the gate.
struct GatedAssetFetcher: AssetFetcher {
    let gate: StoreGate

    func fetch(_ asset: Asset, progress: @escaping @Sendable (Double) -> Void) async throws(KnotError) -> Asset {
        try await gate.ports().fetcher.fetch(asset, progress: progress)
    }
}
