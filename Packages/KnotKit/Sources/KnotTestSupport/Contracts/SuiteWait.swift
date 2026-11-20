import Foundation
import Synchronization
import Testing

/// The end of every wait in the contract suites and in the fakes' tests (finding 85).
///
/// A wait for something the subject should do, an event, a task's value, a flag, has an end
/// that a loaded machine cannot reach and that still ends: ten minutes, after which the check
/// records an issue that says what it waited for, and goes on. A subject that never does what
/// a check waits for, which is a wrong subject the suites exist to catch, then fails the suite
/// instead of holding it, and the gate with it, for ever.
public enum SuiteWait {
    /// Ten minutes.
    public static let limit: Duration = .seconds(600)

    /// Waits until `condition` holds. After `limit`, records that it waited for `what`, and
    /// returns false.
    @discardableResult
    public static func until(
        _ what: String, limit: Duration = SuiteWait.limit, sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !condition() {
            if ContinuousClock.now >= deadline {
                Issue.record("Waited \(limit) for \(what).", sourceLocation: sourceLocation)
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(2))
            } catch {
                // The test itself was cancelled: stop waiting.
                return condition()
            }
        }
        return true
    }

    /// Runs `body` and returns its value. After `limit` without it, records that it waited for
    /// `what`, cancels the body, and returns `nil`. The body runs in a task of its own, so that
    /// one that ignores its cancellation does not hold the caller.
    public static func value<T: Sendable>(
        _ what: String, limit: Duration = SuiteWait.limit, sourceLocation: SourceLocation = #_sourceLocation,
        _ body: @escaping @Sendable () async -> T
    ) async -> T? {
        let box = WaitBox<T>()
        let work = Task { box.set(await body()) }
        guard await until(what, limit: limit, sourceLocation: sourceLocation, { box.isSet }) else {
            work.cancel()
            return nil
        }
        return box.value
    }
}

/// A value one task sets and another reads.
final class WaitBox<T: Sendable>: Sendable {
    private let state = Mutex<T?>(nil)
    var isSet: Bool { state.withLock { $0 != nil } }
    var value: T? { state.withLock { $0 } }
    func set(_ value: T) { state.withLock { $0 = value } }
}
