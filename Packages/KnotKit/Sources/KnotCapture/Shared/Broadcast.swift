import Foundation
import Synchronization

/// Hands every value sent to each current subscriber. A subscriber that goes away is
/// dropped; nobody else is affected.
final class Broadcast<Element: Sendable>: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<Element>.Continuation]>([:])

    func subscribe() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
        let key = UUID()
        continuations.withLock { $0[key] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.continuations.withLock { $0.removeValue(forKey: key) }
        }
        return stream
    }

    func send(_ value: Element) {
        for continuation in continuations.withLock({ Array($0.values) }) { continuation.yield(value) }
    }
}

/// A first-in, first-out lock for one key at a time, for an actor whose operations on one
/// key must not interleave across their suspension points. Used only from the actor that
/// owns it.
struct KeyedLine<Key: Hashable> {
    private var busy: Set<Key> = []
    private var waiting: [Key: [CheckedContinuation<Void, Never>]] = [:]

    /// True when `key` was free and is now taken. Otherwise the caller waits with `enqueue`.
    mutating func take(_ key: Key) -> Bool {
        busy.insert(key).inserted
    }

    mutating func enqueue(_ key: Key, _ continuation: CheckedContinuation<Void, Never>) {
        waiting[key, default: []].append(continuation)
    }

    /// Hands `key` to the next waiter, which then holds it, or frees it.
    mutating func release(_ key: Key) -> CheckedContinuation<Void, Never>? {
        if var queue = waiting[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiting[key] = queue.isEmpty ? nil : queue
            return next
        }
        busy.remove(key)
        return nil
    }
}
