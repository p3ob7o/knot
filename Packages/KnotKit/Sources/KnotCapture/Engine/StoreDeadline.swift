import Foundation
import KnotCore
import Synchronization

/// How long the engine waits for the store before a capture takes `Inbox/`
/// (docs/architecture.md §6, rule 6): 100 ms in the app.
///
/// `wait` returns when the store has had its time, or as soon as its task is cancelled,
/// which the engine does when the store answers first. Tests pass a deadline of their own,
/// so that whether the store answered in time never depends on a loaded machine's clock.
public struct StoreDeadline: Sendable {
    public let wait: @Sendable () async -> Void

    public init(wait: @escaping @Sendable () async -> Void) {
        self.wait = wait
    }

    /// The store has `duration` to answer.
    public static func after(_ duration: Duration) -> StoreDeadline {
        StoreDeadline { try? await Task.sleep(for: duration) }
    }

    /// How long the store has in the app (docs/architecture.md §6, rule 6).
    public static let standardLimit: Duration = .milliseconds(100)

    /// The app's: `standardLimit`.
    public static let standard = StoreDeadline.after(standardLimit)
}

/// What one store call came to, as far as the engine waits for it.
enum StoreAnswer<Value: Sendable>: Sendable {
    /// The store answered in time.
    case answered(Value)
    /// The store answered in time, with an error.
    case refused(KnotError)
    /// The store did not answer in time. The call goes on, and may still commit: `late` ends
    /// with what it came to.
    case timedOut(late: Task<Result<Value, KnotError>, Never>)

    /// The code a capture's state carries when the store path did not take it.
    var fallbackCode: ErrorCode? {
        switch self {
        case .answered: nil
        case .refused(let error): error.code
        case .timedOut: KnotError.storeNotOpen.code
        }
    }
}

extension StoreDeadline {
    /// Runs `call` against the store, and stops waiting for it when the deadline comes first.
    /// The call runs in a task of its own, so neither the deadline nor a cancelled caller
    /// cancels it: a store call the engine stopped waiting for may still commit.
    func race<Value: Sendable>(_ call: @escaping @Sendable () async throws(KnotError) -> Value) async
        -> StoreAnswer<Value>
    {
        let store = Task { () -> Result<Value, KnotError> in
            do throws(KnotError) {
                return .success(try await call())
            } catch {
                return .failure(error)
            }
        }
        let once = Once<Result<Value, KnotError>?>()
        let timer = Mutex<Task<Void, Never>?>(nil)
        let first = await withCheckedContinuation {
            (continuation: CheckedContinuation<Result<Value, KnotError>?, Never>) in
            once.arm(continuation)
            Task { once.resume(with: await store.value) }
            timer.withLock {
                $0 = Task {
                    await wait()
                    once.resume(with: nil)
                }
            }
        }
        timer.withLock { $0?.cancel() }
        switch first {
        case .success(let value): return .answered(value)
        case .failure(let error): return .refused(error)
        case nil: return .timedOut(late: store)
        }
    }
}

/// A continuation that the first of several tasks resumes.
private final class Once<Value: Sendable>: Sendable {
    private let continuation = Mutex<CheckedContinuation<Value, Never>?>(nil)

    func arm(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation.withLock { $0 = continuation }
    }

    func resume(with value: Value) {
        let waiting = continuation.withLock { stored -> CheckedContinuation<Value, Never>? in
            defer { stored = nil }
            return stored
        }
        waiting?.resume(returning: value)
    }
}
