import Foundation
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotApp
@testable import KnotCore

/// The stream's change signals through the gate (docs/architecture.md §6): a view that read
/// nothing before the store opened reads again when it opens, and misses no commit after.
@Suite("The change signals of .live")
struct SignalTests {
    /// A broadcast whose subscribers are registered when they subscribe.
    final class Signals: Sendable {
        private let subscribers = Mutex<[AsyncStream<Int>.Continuation]>([])

        func subscribe() -> AsyncStream<Int> {
            let (stream, continuation) = AsyncStream.makeStream(of: Int.self)
            subscribers.withLock { $0.append(continuation) }
            return stream
        }

        func send(_ value: Int) {
            for subscriber in subscribers.withLock({ $0 }) { subscriber.yield(value) }
        }
    }

    /// A commit that lands between the read of the current value and the subscription, as
    /// recovery's ingest can commit the line typed before a kill while the stream subscribes.
    /// The subscription comes first, so the commit's signal arrives.
    @Test("A commit while the current value is read is signalled")
    func commitDuringTheReadIsSignalled() async {
        let signals = Signals()
        let stream = GatedNoteStore.fromOpening(
            subscribe: { signals.subscribe() },
            current: {
                // The value read, then a commit before the read returns.
                signals.send(2)
                return 1
            })
        let seen = await SuiteWait.value("the commit's signal", limit: .seconds(60)) {
            for await value in stream where value == 2 { return true }
            return false
        }
        #expect(seen == true)
    }

    /// The first signal on opening: a stream subscribed before the store opened gets one when it
    /// opens, though nothing commits.
    @Test("A view subscribed before the store opens is signalled when it opens")
    func signalledOnOpening() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let composition = folder.compose()
        let signals = composition.environment.notes.changeSignals()
        _ = try #require(await launch(composition))
        let first = await SuiteWait.value("a signal when the store opened", limit: .seconds(60)) {
            () -> Int64? in
            for await cursor in signals { return cursor.counter }
            return nil
        }
        let cursor = try await composition.environment.notes.cursor()
        #expect(first == .some(cursor.counter))
    }
}
