import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotCapture

/// Finding 74 of the second review of pull request 58: the two protections of a typed item in
/// `Inbox/`, each with a test that fails without it alone. Ingest on another task may take an
/// item and remove it as soon as its manifest names the payload's digest.
@Suite struct InboxItemLockTests {
    /// Without the lock. A removal of the item, as ingest makes once it has stored an item, runs
    /// between the end's manifest and its payload, whose bytes are already the end's. With the
    /// lock, the removal waits for the writing to end, and then removes the whole item; without
    /// it, the writing finds no payload and places one again, which no manifest names, and it stays
    /// in `Inbox/`.
    ///
    /// No thread of Swift's cooperative pool waits here (findings 77 and 80): the writing runs on
    /// a thread of its own, which the hook holds until the removal, on another thread of its own,
    /// has finished or waits for the lock; the test awaits both, suspended.
    @Test func removalBetweenAnItemsTwoPlacingsLeavesNoPayloadAlone() async throws {
        let r = Rig(engineIngests: false)
        let engine = BoundedEngine(r.engine(ingests: false))
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let begun = try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "one"))
        let id = begun.captureID
        // The capture's end, as the engine would write it: the same text, with an end.
        var manifest = try CaptureManifest.decode(try r.layer.read(r.locations.inboxManifest(id)))
        manifest.endedAt = r.clock.now()
        manifest.revision += 1
        let ending = manifest
        let items = InboxItems(locations: r.locations, layer: r.layer)
        let ownLock = ItemLock.of(inbox: r.locations.inbox, layer: r.layer)
        let ran = Mutex(false)
        InboxItems.afterManifestPlaced.withLock { hook in
            hook = { capture, lock in
                // Another test's store may make a capture with the same ID: only this store's.
                guard capture == id, lock === ownLock else { return }
                let finished = Mutex(false)
                Thread {
                    try? items.remove(id, kind: .typed)
                    finished.withLock { $0 = true }
                }.start()
                // On the writing's own thread: until the removal has finished, or waits for the lock.
                let limit = ContinuousClock.now.advanced(by: SuiteWait.limit)
                while !finished.withLock({ $0 }), ownLock.removalsWaiting.withLock({ $0[id] ?? 0 }) == 0 {
                    guard ContinuousClock.now < limit else { break }
                    usleep(200)
                }
                ran.withLock { $0 = true }
            }
        }
        defer { InboxItems.afterManifestPlaced.withLock { $0 = nil } }
        let written = await SuiteWait.value("the item's writing") { () async -> Bool in
            await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                Thread {
                    let placed = (try? items.writeTyped(ending, text: "one")) != nil
                    done.resume(returning: placed)
                }.start()
            }
        }
        #expect(written == true)
        #expect(ran.withLock { $0 })
        #expect(
            await eventually("the removal to end") { ownLock.removalsWaiting.withLock { $0[id] == nil } })
        let after = Set(r.inboxFiles())
        let manifestName = r.locations.inboxManifest(id).lastPathComponent
        let payloadName = r.locations.inboxPayload(id, kind: .typed).lastPathComponent
        #expect(
            !(after.contains(payloadName) && !after.contains(manifestName)),
            "A payload is left with no manifest: \(after)")
    }

    /// Without the check. An end whose text is the payload already on the drive places no payload
    /// again: it is durable, and a second placing is a write the drive does not need.
    @Test func endWithTheSameTextPlacesNoPayloadAgain() async throws {
        let r = Rig(engineIngests: false)
        let layer = CountingFileLayer(r.layer)
        let engine = BoundedEngine(
            StandardCaptureEngine(
                notes: r.notes, assets: r.assets, recorder: r.recorder, queue: r.queue, clock: r.clock, ids: r.ids,
                deviceID: r.deviceID, launchID: r.launchID, locations: r.locations, layer: layer, deadline: .patient,
                log: KnotLog(.capture, sink: r.logs)))
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let begun = try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "one"))
        let payload = r.locations.inboxPayload(begun.captureID, kind: .typed)
        #expect(layer.writes(to: payload) == 1)
        _ = try await engine.end(begun.captureID)
        #expect(layer.writes(to: payload) == 1, "The end placed the same text a second time.")
    }
}

/// A file layer that counts the writes of each file, the temporary file `DurableFile` writes
/// before it renames it into place included.
final class CountingFileLayer: FileLayer {
    let base: PowerCutFileLayer
    private let written = Mutex<[String]>([])

    init(_ base: PowerCutFileLayer) { self.base = base }

    /// How many writes placed `url`, by the name of the file or of a temporary file for it.
    func writes(to url: URL) -> Int {
        let name = url.lastPathComponent
        return written.withLock { $0.filter { $0 == name || $0.hasPrefix("." + name + ".") }.count }
    }

    func createFolder(_ url: URL) throws(KnotError) { try base.createFolder(url) }
    func write(_ data: Data, to url: URL) throws(KnotError) {
        written.withLock { $0.append(url.lastPathComponent) }
        try base.write(data, to: url)
    }
    func syncFile(_ url: URL) throws(KnotError) { try base.syncFile(url) }
    func rename(_ source: URL, to destination: URL) throws(KnotError) { try base.rename(source, to: destination) }
    func syncFolder(_ url: URL) throws(KnotError) { try base.syncFolder(url) }
    func remove(_ url: URL) throws(KnotError) { try base.remove(url) }
    func read(_ url: URL) throws(KnotError) -> Data { try base.read(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
    func entryKind(_ url: URL) -> FileEntryKind? { base.entryKind(url) }
    func contents(of folder: URL) throws(KnotError) -> [String] { try base.contents(of: folder) }
}

/// Finding 76: the item lock of one `Inbox/` is one lock, whatever happened to the folder. A path
/// in its `/private` form reads as another path through `standardizedFileURL` once the folder
/// exists, so an engine made before `Inbox/` exists and an ingest made after would hold two locks.
/// Every caller takes its paths from one `StoreLocations`, so the key is the path as written.
@Suite struct InboxItemLockKeyTests {
    @Test func oneInboxHasOneLockBeforeAndAfterItsFolderExists() throws {
        // The temporary folder in its `/private` form, as an app group's container is handed over.
        let plain = NSTemporaryDirectory()
        try #require(plain.hasPrefix("/var/") || plain.hasPrefix("/tmp/"), "The test needs a folder below /private.")
        let temporary = URL(fileURLWithPath: "/private" + plain, isDirectory: true)
        let root = temporary.appending(path: "knot-item-lock-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = root.appending(path: "Inbox", directoryHint: .isDirectory)
        let layer = PosixFileLayer()
        let before = ItemLock.of(inbox: inbox, layer: layer)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let after = ItemLock.of(inbox: inbox, layer: layer)
        #expect(before === after)
    }

    /// Finding 79, the re-check's witness. One `Inbox/`, reached as `/private/var/…` by one caller
    /// and `/var/…` by another, before its folder exists and after: one item lock.
    @Test func oneInboxOneLockWithAndWithoutPrivate() throws {
        let plain = NSTemporaryDirectory()
        try #require(plain.hasPrefix("/var/"), "The test needs a folder below /private/var.")
        let name = "knot-item-lock-\(UUID().uuidString)"
        let withPrivate = URL(fileURLWithPath: "/private" + plain, isDirectory: true)
            .appending(path: name, directoryHint: .isDirectory).appending(path: "Inbox", directoryHint: .isDirectory)
        let without = URL(fileURLWithPath: plain, isDirectory: true)
            .appending(path: name, directoryHint: .isDirectory).appending(path: "Inbox", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: withPrivate.deletingLastPathComponent()) }
        let layer = PosixFileLayer()
        let beforeA = ItemLock.of(inbox: withPrivate, layer: layer)
        let beforeB = ItemLock.of(inbox: without, layer: layer)
        try FileManager.default.createDirectory(at: withPrivate, withIntermediateDirectories: true)
        let afterA = ItemLock.of(inbox: withPrivate, layer: layer)
        let afterB = ItemLock.of(inbox: without, layer: layer)
        #expect(beforeA === afterA)
        #expect(beforeB === afterB)
        #expect(beforeA === beforeB, "One Inbox/, with /private and without, has one lock.")
    }
}
