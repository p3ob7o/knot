import Foundation
import KnotCore
import KnotTestSupport
import Synchronization
import Testing

/// The system's files, with places where a test pauses a call or makes one fail: before a
/// folder is made, before a file is synced, before a rename, at a folder's sync, at a rename and
/// at a file's sync.
struct HookedFileLayer: FileLayer {
    let base = PosixFileLayer()
    var beforeCreate: @Sendable (URL) -> Void = { _ in }
    var beforeSyncFile: @Sendable (URL) -> Void = { _ in }
    var beforeRename: @Sendable (URL, URL) -> Void = { _, _ in }
    var refuseSync: @Sendable (URL) -> Bool = { _ in false }
    var refuseRename: @Sendable (URL, URL) -> Bool = { _, _ in false }
    var refuseSyncFile: @Sendable (URL) -> Bool = { _ in false }

    func createFolder(_ url: URL) throws(KnotError) {
        beforeCreate(url)
        try base.createFolder(url)
    }

    func write(_ data: Data, to url: URL) throws(KnotError) { try base.write(data, to: url) }

    func syncFile(_ url: URL) throws(KnotError) {
        beforeSyncFile(url)
        if refuseSyncFile(url) { throw KnotError.writeFailed.with(.init(posixError: EIO)) }
        try base.syncFile(url)
    }

    func rename(_ source: URL, to destination: URL) throws(KnotError) {
        beforeRename(source, destination)
        if refuseRename(source, destination) { throw KnotError.writeFailed.with(.init(posixError: EIO)) }
        try base.rename(source, to: destination)
    }

    func syncFolder(_ url: URL) throws(KnotError) {
        if refuseSync(url) { throw KnotError.writeFailed.with(.init(posixError: EIO)) }
        try base.syncFolder(url)
    }

    func remove(_ url: URL) throws(KnotError) { try base.remove(url) }
    func read(_ url: URL) throws(KnotError) -> Data { try base.read(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
    func entryKind(_ url: URL) -> FileEntryKind? { base.entryKind(url) }
    func contents(of folder: URL) throws(KnotError) -> [String] { try base.contents(of: folder) }
}

/// A point that the code under test stops at until the test lets it go. The test's wait ends
/// through `SuiteWait`, and the stopped call's wait ends after the same ten minutes. The stop
/// blocks the thread the code runs on, so code that a gate stops runs on a thread of its own,
/// started with `onOwnThread`, never on a thread of the cooperative pool.
final class Gate: Sendable {
    private let state = Mutex((armed: true, reached: false))
    private let released = DispatchSemaphore(value: 0)

    /// Called by the code under test: the first call stops, later ones pass.
    func stop() {
        let first = state.withLock { state in
            defer { state.armed = false }
            if state.armed { state.reached = true }
            return state.armed
        }
        guard first else { return }
        _ = released.wait(timeout: .now() + 600)
    }

    /// Waits until the code under test has stopped.
    func untilReached(sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await SuiteWait.until("the code under test to reach its gate", sourceLocation: sourceLocation) { [self] in
            state.withLock { $0.reached }
        }
    }

    func release() { released.signal() }
}

/// A thread of its own for the code a test stops, outside Swift's cooperative pool.
///
/// A `Gate` stops the code under test by blocking the thread it runs on, and a call that waits
/// on stopped code, as a caller of GRDB's writer does, blocks its own thread too. The pool has
/// as many threads as the machine has cores, three on a hosted runner: three stopped tests took
/// every one, and the tests that would have let them go never ran. So no test blocks a thread
/// of the pool: a wait in a test is async, or the code it stops runs here. The task that prefers
/// this executor owns it, and every job of the task runs on its one serial queue.
final class OwnThread: TaskExecutor {
    private let queue = DispatchQueue(label: "knot.store-tests.own-thread")

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

/// Starts `operation` in a task of its own whose code runs on a thread of its own
/// (`OwnThread`): the way to run code under test that a `Gate` stops.
func onOwnThread<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) -> Task<T, any Error> {
    Task.detached(executorPreference: OwnThread(), operation: operation)
}

/// A switch a test turns on and off while the code under test reads it.
final class Switch: Sendable {
    private let state: Mutex<Bool>

    init(_ on: Bool) { state = Mutex(on) }

    var isOn: Bool { state.withLock { $0 } }

    func set(_ on: Bool) { state.withLock { $0 = on } }
}

/// What the code under test reported, in order.
final class Recorded: Sendable {
    private let items = Mutex<[String]>([])

    func add(_ item: String) { items.withLock { $0.append(item) } }

    var all: [String] { items.withLock { $0 } }
}
