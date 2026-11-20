import Foundation
import Synchronization
import Testing

/// Subscribers that join while changes run (finding 28 on pull request 41).
///
/// A stream that starts with the current value and then gives every change, each once and in
/// order, gives a subscriber that joins late the end of what one there from the start sees: the
/// value current when it joined, then each later change. A subject that records a subscriber
/// and gives it the current value in two steps can let a change through in between, and the
/// late subscriber then sees the newer value before the older one.
enum JoiningSubscribers {
    /// One round: a subscriber from the start, then `changes` all at once with as many
    /// subscribers joining among them, then `last`, whose value only `isLast` matches. Each
    /// late subscriber must see the end of what the first one saw. Returns how many did not.
    static func round<Value: Sendable & Equatable>(
        _ what: String, sourceLocation: SourceLocation = #_sourceLocation,
        subscribe: @escaping @Sendable () -> AsyncStream<Value>,
        changes: [@Sendable () async throws -> Void],
        last: @escaping @Sendable () async throws -> Void,
        isLast: @escaping @Sendable (Value) -> Bool
    ) async throws -> Int {
        let first = subscribe()
        let late = Late<Value>()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for change in changes {
                group.addTask { try await change() }
                group.addTask { late.add(subscribe()) }
            }
            try await group.waitForAll()
        }
        try await last()
        func seen(_ stream: AsyncStream<Value>) async -> [Value]? {
            await SuiteWait.value("\(what): a subscriber to see the last change", sourceLocation: sourceLocation) {
                var seen: [Value] = []
                for await value in stream {
                    seen.append(value)
                    if isLast(value) { break }
                }
                return seen
            }
        }
        guard let whole = await seen(first) else { return 0 }
        var wrong = 0
        for stream in late.streams {
            guard let part = await seen(stream) else { continue }
            if part.isEmpty || whole.count < part.count || Array(whole.suffix(part.count)) != part { wrong += 1 }
        }
        return wrong
    }

    /// `round` `rounds` times; records an issue naming how many late subscribers saw changes out
    /// of order.
    static func check(
        _ what: String, rounds: Int, sourceLocation: SourceLocation = #_sourceLocation,
        _ round: (Int) async throws -> Int
    ) async throws {
        var wrong = 0
        for index in 0..<rounds { wrong += try await round(index) }
        #expect(
            wrong == 0,
            "\(what): \(wrong) subscribers that joined while changes ran saw them out of order.",
            sourceLocation: sourceLocation)
    }

    private final class Late<Value: Sendable>: Sendable {
        private let state = Mutex<[AsyncStream<Value>]>([])
        func add(_ stream: AsyncStream<Value>) { state.withLock { $0.append(stream) } }
        var streams: [AsyncStream<Value>] { state.withLock { $0 } }
    }
}
