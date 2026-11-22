import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// A call of a model that a test holds where it is: it waits, as a process that dies there waits
/// for ever, until the test releases it. Every wait rests on the order of calls, never on a time.
final class CallHolds: Sendable {
    private struct State {
        var calls = 0
        var held: Set<Int> = []
        var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
        var arrived: Set<Int> = []
        var released: Set<Int> = []
    }

    private let state = Mutex(State())

    /// Holds the calls with these numbers, counted from 1 across every queue that shares the model.
    func hold(_ calls: Int...) { state.withLock { $0.held.formUnion(calls) } }

    var calls: Int { state.withLock { $0.calls } }

    /// Counts a call, and holds it if its number is held, until `release(_:)`. Returns whether it
    /// was held.
    func pass() async -> Bool {
        let number = state.withLock { state in
            state.calls += 1
            return state.calls
        }
        let held = state.withLock { $0.held.contains(number) }
        guard held else { return false }
        await withCheckedContinuation { continuation in
            let releasedAlready = state.withLock { state in
                state.arrived.insert(number)
                if state.released.contains(number) { return true }
                state.waiting[number] = continuation
                return false
            }
            if releasedAlready { continuation.resume() }
        }
        return true
    }

    /// Waits until the held call `number` has arrived.
    func untilHeld(_ number: Int) async -> Bool {
        await SuiteWait.until("held call \(number) to arrive") { [self] in
            state.withLock { $0.arrived.contains(number) }
        }
    }

    /// Lets every held call go.
    func releaseAll() {
        let waiting = state.withLock { state in
            state.released.formUnion(state.held)
            let waiting = Array(state.waiting.values)
            state.waiting = [:]
            return waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}

/// The scripted transcriber, which records where each run started. With `heldRunsDie`, a held run
/// never returns its text: it is one a process died inside, and when it is let go it throws
/// `cancelled`, so nothing of it is saved. Without it, a held run answers once it is let go.
final class HeldTranscriber: Transcriber {
    let inner: ScriptedTranscriber
    let holds = CallHolds()
    let heldRunsDie: Bool
    private let starts = Mutex<[Duration]>([])

    init(_ inner: ScriptedTranscriber, heldRunsDie: Bool = true) {
        self.inner = inner
        self.heldRunsDie = heldRunsDie
    }

    /// Where each run started, in the order they were asked for.
    var offsets: [Duration] { starts.withLock { $0 } }

    var locale: Locale { inner.locale }
    func readiness() async -> TranscriberReadiness { await inner.readiness() }
    func install(progress: @escaping @Sendable (Double) -> Void) async throws(KnotError) {
        try await inner.install(progress: progress)
    }

    func transcribe(file: URL, from offset: Duration, budget: Duration?) async throws(KnotError) -> TranscriptionRun {
        starts.withLock { $0.append(offset) }
        if await holds.pass(), heldRunsDie { throw KnotError.cancelled }
        return try await inner.transcribe(file: file, from: offset, budget: budget)
    }

    func live(_ chunks: AsyncStream<AudioChunk>) -> AsyncStream<LiveTranscriptEvent> { inner.live(chunks) }
}

/// The scripted cleaner, whose held calls wait for the test and then answer as the scripted one does.
final class HeldCleaner: Cleaner {
    let inner: ScriptedCleaner
    let holds = CallHolds()

    init(_ inner: ScriptedCleaner) { self.inner = inner }

    func availability() async -> CleanupAvailability { await inner.availability() }
    func availabilityChanges() -> AsyncStream<CleanupAvailability> { inner.availabilityChanges() }

    func clean(_ rawTranscript: String, proposeTitle: Bool) async throws(KnotError) -> CleanupResult {
        _ = await holds.pass()
        return try await inner.clean(rawTranscript, proposeTitle: proposeTitle)
    }
}
