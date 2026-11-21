import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotStore

/// The in-memory store and the real one, made alike: the same clock moments, IDs, device,
/// generation and window, so that a script run on each gives answers that compare whole, as
/// the differential test compares them.
struct BothStores {
    let fake: InMemoryNoteStore
    let real: NoteRepository
    let database: StoreDatabase
    let fakeClock: FakeClock
    let realClock: FakeClock
    let device: DeviceID

    static func make(seed: UInt64, root: URL, minutes: Int = 5) async throws -> BothStores {
        let fakeClock = FakeClock(Captures.base)
        let realClock = FakeClock(Captures.base)
        let device: DeviceID = SeededIDGenerator(seed: seed &+ 20_000, clock: FakeClock(Captures.base)).make()
        let window = try AppendWindow(minutes: minutes)
        let fake = InMemoryNoteStore(
            clock: fakeClock, ids: SeededIDGenerator(seed: seed, clock: fakeClock), deviceID: device, window: window,
            generation: 2)
        let database = try StoreDatabase.open(
            locations: .testing(root: root), role: .app, clock: realClock,
            ids: SeededIDGenerator(seed: seed, clock: realClock),
            creation: StoreCreation(deviceID: device, generation: 2))
        try await setWindow(window, in: database)
        return BothStores(
            fake: fake, real: NoteRepository(database: database), database: database, fakeClock: fakeClock,
            realClock: realClock, device: device)
    }

    /// Runs `script` on the in-memory store, then on the real one, and expects the same answer
    /// at every step. The real store passes the consistency check at the end.
    static func run(
        seed: UInt64, minutes: Int = 5, sourceLocation: SourceLocation = #_sourceLocation,
        _ script: (Stage, Transcript) async throws -> Void
    ) async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let both = try await make(seed: seed, root: folders.make(), minutes: minutes)
        var answers: [[String]] = []
        for (store, clock) in [
            (both.fake as any NoteStore, both.fakeClock), (both.real as any NoteStore, both.realClock),
        ] {
            let ids = SeededIDGenerator(seed: seed &+ 10_000, clock: FakeClock(Captures.base))
            let transcript = Transcript()
            try await script(
                Stage(store: store, clock: clock, ids: ids, device: both.device, launch: ids.make()), transcript)
            answers.append(transcript.lines)
        }
        #expect(answers[0].count == answers[1].count, "Steps, seed \(seed)", sourceLocation: sourceLocation)
        for (index, (fake, real)) in zip(answers[0], answers[1]).enumerated() {
            #expect(fake == real, "Step \(index), seed \(seed)", sourceLocation: sourceLocation)
        }
        expectConsistent(both.database, sourceLocation: sourceLocation)
    }
}

/// What a script sees of one store: the store, its clock, and IDs that repeat from run to run.
struct Stage {
    let store: any NoteStore
    let clock: FakeClock
    let ids: SeededIDGenerator
    let device: DeviceID
    let launch: LaunchID

    func at(_ minutes: Double) -> Date { Captures.base.addingTimeInterval(minutes * 60) }

    /// A typed capture from this device, with the clock at its end, or at its start when open.
    func typed(
        _ text: String, from start: Double, to end: Double?, placement: CapturePlacement = .window,
        revision: Int64 = 1
    ) -> NewCapture {
        clock.set(at(end ?? start))
        return NewCapture(
            id: ids.make(), kind: .typed, origin: CaptureOrigin(source: .device(device), surface: .app),
            launchID: launch, placement: placement, startedAt: at(start), endedAt: end.map(at), body: .text(text),
            revision: revision)
    }

    /// The note a capture's first segment is in now.
    func note(of capture: CaptureID) async throws -> NoteID {
        guard let read = try await store.segment(SegmentID(capture)) else { throw KnotError.notFound }
        return read.noteID
    }
}

/// The answers of one run of a script, one line per step: a value as it describes itself, or a
/// failure by its code. A capture's content hash is keyed with each store's own secret, so the
/// lines that hold one say only whether it is there.
final class Transcript: Sendable {
    private let recorded = Mutex<[String]>([])

    var lines: [String] { recorded.withLock { $0 } }

    func step<Value>(_ label: String, _ body: () async throws -> Value) async {
        let line: String
        do {
            line = "\(label): \(String(describing: try await body()))"
        } catch let error as KnotError {
            line = "\(label): failed \(error.code)"
        } catch {
            line = "\(label): failed \(error)"
        }
        recorded.withLock { $0.append(line) }
    }
}
