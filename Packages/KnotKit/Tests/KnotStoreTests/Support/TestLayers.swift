import Foundation
import KnotCore
import KnotTestSupport
import Synchronization
import Testing

/// The system's files, with places where a test pauses a call or makes one fail: before a
/// folder is made, before a file is synced, before a rename, and at a folder's sync.
struct HookedFileLayer: FileLayer {
    let base = PosixFileLayer()
    var beforeCreate: @Sendable (URL) -> Void = { _ in }
    var beforeSyncFile: @Sendable (URL) -> Void = { _ in }
    var beforeRename: @Sendable (URL, URL) -> Void = { _, _ in }
    var refuseSync: @Sendable (URL) -> Bool = { _ in false }

    func createFolder(_ url: URL) throws(KnotError) {
        beforeCreate(url)
        try base.createFolder(url)
    }

    func write(_ data: Data, to url: URL) throws(KnotError) { try base.write(data, to: url) }

    func syncFile(_ url: URL) throws(KnotError) {
        beforeSyncFile(url)
        try base.syncFile(url)
    }

    func rename(_ source: URL, to destination: URL) throws(KnotError) {
        beforeRename(source, destination)
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
/// through `SuiteWait`, and the stopped call's wait ends after the same ten minutes.
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
