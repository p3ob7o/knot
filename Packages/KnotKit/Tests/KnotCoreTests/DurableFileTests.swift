import Foundation
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotCore

/// The store's root in the tests on the power-cut layer.
private let storeRoot = URL(fileURLWithPath: "/store", isDirectory: true)

@Suite struct DurableFileTests {
    let folder = URL(fileURLWithPath: "/store/Inbox", isDirectory: true)
    var target: URL { folder.appending(path: "capture.json") }
    let old = Data("old content".utf8)
    let new = Data("new content, longer".utf8)

    /// A layer whose folder exists and whose target holds `old`, all synced, with the
    /// `DurableFile` that placed it, which remembers the folders it synced.
    func withOldFile() throws -> (PowerCutFileLayer, DurableFile) {
        let layer = PowerCutFileLayer()
        let durable = DurableFile(layer: layer, root: storeRoot)
        try durable.makeFolder(folder)
        try durable.place(old, at: target)
        return (layer, durable)
    }

    @Test("file-layer-drops-unsynced-writes", .tags(.named))
    func theFileLayerDropsUnsyncedWritesAndRecoveryHolds() throws {
        // The layer drops what was not synced: a plain write, and a synced file whose name
        // the folder never synced.
        let plain = PowerCutFileLayer()
        try DurableFile(layer: plain, root: storeRoot).makeFolder(folder)
        try plain.write(new, to: target)
        plain.cutPower()
        #expect(!plain.exists(target))
        try plain.write(new, to: target)
        try plain.syncFile(target)
        plain.cutPower()
        #expect(!plain.exists(target))

        // A file placed by DurableFile survives.
        let (placed, placer) = try withOldFile()
        try placer.place(new, at: target)
        placed.cutPower()
        #expect(try placed.read(target) == new)

        // Cut the power after each operation of a placement in turn. The target holds the old
        // content or the new, whole, and once the call returned, and the row that points to
        // the file could be committed, it holds the new.
        let (probe, prober) = try withOldFile()
        let start = probe.operationCount
        try prober.place(new, at: target)
        let steps = probe.operationCount - start
        #expect(steps == 4, "write, sync, rename, sync the folder: folders already synced cost nothing")
        for cut in 0...steps {
            let (layer, durable) = try withOldFile()
            layer.die(afterOperations: cut)
            var rowCommitted = false
            do {
                try durable.place(new, at: target)
                rowCommitted = true
            } catch {
                #expect(error == .writeFailed)
            }
            layer.cutPower()
            let content = try layer.read(target)
            #expect(content == old || content == new, "Cut after \(cut) operations: a part of a file.")
            if rowCommitted { #expect(content == new, "Cut after \(cut) operations: a committed row lost its file.") }
            // What a crash left beside the target is cleared at relaunch.
            try durable.removePartials(in: folder)
            #expect(try layer.contents(of: folder) == ["capture.json"])
        }

        // A folder's name is an entry in its parent: a folder made from nothing survives
        // only when every new level's parent was synced.
        let bare = PowerCutFileLayer()
        let bareFolder = URL(fileURLWithPath: "/store/KnotStore/Assets/ab", isDirectory: true)
        try DurableFile(layer: bare, root: storeRoot).makeFolder(bareFolder)
        try DurableFile(layer: bare, root: storeRoot).place(new, at: bareFolder.appending(path: "x.m4a"))
        bare.cutPower()
        #expect(try bare.read(bareFolder.appending(path: "x.m4a")) == new)

        // Two writers: A makes a folder and is paused before it syncs the folder's parent; B
        // finds the folder, saves into it and is acknowledged. The save survives a power cut,
        // because B syncs the name of every folder down to the file, made or found.
        let shared = PowerCutFileLayer()
        try DurableFile(layer: shared, root: storeRoot).makeFolder(storeRoot)
        try shared.createFolder(storeRoot.appending(path: "A"))
        let writerB = DurableFile(layer: shared, root: storeRoot)
        try writerB.place(new, at: storeRoot.appending(path: "A/x"))
        shared.cutPower()
        #expect((try? shared.read(storeRoot.appending(path: "A/x"))) == new, "B's acknowledged save was lost.")

        // And the test notices a DurableFile that forgets any one of its syncs: with each
        // sync of each operation forgotten in turn, what the operation promised is lost.
        for scenario in Scenario.allCases {
            let clean = try run(scenario, forgetting: nil)
            #expect(clean.survived, "\(scenario) loses what it promised.")
            #expect(clean.syncs > 0)
            for index in 0..<clean.syncs {
                #expect(
                    try !run(scenario, forgetting: index).survived,
                    "\(scenario): forgetting sync \(index) of \(clean.syncs) goes unnoticed.")
            }
        }
    }

    /// The durable operations, each from a disk that holds only what it needs.
    enum Scenario: CaseIterable {
        /// Folders made from nothing down to `Assets/ab`, then a file placed there.
        case placeIntoNewFolders
        /// A received file, written but not synced, moved into `Inbox/`.
        case moveReceivedFile
        case remove
    }

    /// Runs a scenario with sync number `forgetting` forgotten, cuts the power, and says how
    /// many syncs it made and whether what it promised survived.
    func run(_ scenario: Scenario, forgetting index: Int?) throws -> (syncs: Int, survived: Bool) {
        let layer: PowerCutFileLayer
        let durable: DurableFile
        let before: Int
        switch scenario {
        case .placeIntoNewFolders:
            layer = PowerCutFileLayer()
            durable = DurableFile(layer: layer, root: storeRoot)
            let assets = URL(fileURLWithPath: "/store/KnotStore/Assets/ab", isDirectory: true)
            before = layer.syncCount
            if let index { layer.forgetSync(index) }
            try durable.makeFolder(assets)
            try durable.place(new, at: assets.appending(path: "x.m4a"))
            let syncs = layer.syncCount - before
            layer.cutPower()
            return (syncs, (try? layer.read(assets.appending(path: "x.m4a"))) == new)
        case .moveReceivedFile:
            layer = PowerCutFileLayer()
            durable = DurableFile(layer: layer, root: storeRoot)
            let received = URL(fileURLWithPath: "/store/Received", isDirectory: true)
            let source = received.appending(path: "file.m4a")
            let destination = folder.appending(path: "file.m4a")
            try durable.makeFolder(received)
            try durable.makeFolder(folder)
            try layer.write(new, to: source)
            try layer.syncFolder(received)
            before = layer.syncCount
            if let index { layer.forgetSync(index) }
            try durable.move(source, to: destination)
            let syncs = layer.syncCount - before
            layer.cutPower()
            return (syncs, (try? layer.read(destination)) == new && !layer.exists(source))
        case .remove:
            (layer, durable) = try withOldFile()
            before = layer.syncCount
            if let index { layer.forgetSync(index) }
            try durable.remove(target)
            let syncs = layer.syncCount - before
            layer.cutPower()
            return (syncs, !layer.exists(target))
        }
    }

    @Test func aMoveIsDurableToo() throws {
        // The received file's name is synced but its content is not, as when the watch link
        // hands over a file. A move syncs the file before it renames it, so the destination
        // never shows a file whose content a cut has lost.
        let received = URL(fileURLWithPath: "/store/Received", isDirectory: true)
        let source = received.appending(path: "file.m4a")
        let destination = folder.appending(path: "file.m4a")
        for cut in 0...4 {
            let layer = PowerCutFileLayer()
            let durable = DurableFile(layer: layer, root: storeRoot)
            try durable.makeFolder(folder)
            try durable.makeFolder(received)
            try layer.write(new, to: source)
            try layer.syncFolder(received)
            layer.die(afterOperations: cut)
            var acknowledged = false
            do {
                try durable.move(source, to: destination)
                acknowledged = true
            } catch {}
            layer.cutPower()
            let there = layer.exists(destination)
            #expect(there || layer.exists(source), "Cut after \(cut): the file is in neither folder.")
            if acknowledged { #expect(there && !layer.exists(source)) }
            if there {
                #expect(try layer.read(destination) == new, "Cut after \(cut): the moved file lost its content.")
            }
        }
    }

    @Test func aFullDiskLeavesTheOldFile() throws {
        let (layer, durable) = try withOldFile()
        layer.failNextWrite(with: .diskFull)
        #expect(throws: KnotError.diskFull) { try durable.place(new, at: target) }
        layer.cutPower()
        #expect(try layer.read(target) == old)
    }

    @Test func aRemovalStays() throws {
        let (layer, durable) = try withOldFile()
        try durable.remove(target)
        layer.cutPower()
        #expect(!layer.exists(target))
    }

    @Test func thePosixLayerPlacesReadsMovesAndRemoves() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "knot-durable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let durable = DurableFile(layer: PosixFileLayer(), root: root)
        let inbox = root.appending(path: "Inbox", directoryHint: .isDirectory)
        try durable.makeFolder(inbox)
        let file = inbox.appending(path: "a.json")
        try durable.place(old, at: file)
        try durable.place(new, at: file)
        #expect(try durable.layer.read(file) == new)
        #expect(try durable.layer.contents(of: inbox) == ["a.json"], "No partial file is left behind.")
        let moved = root.appending(path: "b.json")
        try durable.move(file, to: moved)
        #expect(!durable.layer.exists(file))
        #expect(try durable.layer.read(moved) == new)
        try durable.remove(moved)
        #expect(!durable.layer.exists(moved))
        try durable.remove(moved)
        // A folder below the root that is missing is made; a path outside the root is refused.
        try durable.place(new, at: root.appending(path: "missing/c.json"))
        #expect(try durable.layer.read(root.appending(path: "missing/c.json")) == new)
        do {
            try durable.place(new, at: root.deletingLastPathComponent().appending(path: "outside.json"))
            Issue.record("A path outside the store's root was written.")
        } catch {
            #expect(error.code == KnotError.writeFailed.code)
            #expect(error.context.posixError == EINVAL)
        }
    }
}

/// How the live layer flushes: F_FULLFSYNC, and fsync only where the file system does not
/// support it.
@Suite struct PosixFlushTests {
    /// Scripted answers of the two calls, and how often each was made.
    final class Calls: Sendable {
        private struct State {
            var full: [Int32]
            var plain: [Int32]
            var fullCount = 0
            var plainCount = 0
        }

        private let state: Mutex<State>

        init(full: [Int32], plain: [Int32] = []) {
            self.state = Mutex(State(full: full, plain: plain))
        }

        var fullCount: Int { state.withLock { $0.fullCount } }
        var plainCount: Int { state.withLock { $0.plainCount } }

        var flushCalls: PosixFileLayer.FlushCalls {
            PosixFileLayer.FlushCalls(
                fullSync: { _ in
                    self.state.withLock { state in
                        state.fullCount += 1
                        return state.full.isEmpty ? 0 : state.full.removeFirst()
                    }
                },
                plainSync: { _ in
                    self.state.withLock { state in
                        state.plainCount += 1
                        return state.plain.isEmpty ? 0 : state.plain.removeFirst()
                    }
                })
        }
    }

    @Test func aFullSyncThatWorksIsEnough() throws {
        let calls = Calls(full: [0])
        try PosixFileLayer.flush(3, calls: calls.flushCalls)
        #expect(calls.plainCount == 0)
    }

    @Test(arguments: [EIO, ENOSPC, EBADF, EINVAL])
    func aFullSyncThatFailsIsAFailureEvenIfFsyncWorks(failure: Int32) {
        let calls = Calls(full: [failure], plain: [0])
        #expect(throws: KnotError.self) { try PosixFileLayer.flush(3, calls: calls.flushCalls) }
        do {
            try PosixFileLayer.flush(3, calls: Calls(full: [failure], plain: [0]).flushCalls)
        } catch {
            #expect(error.context.posixError == failure)
        }
        #expect(calls.plainCount == 0, "fsync is no stand-in for a flush that failed.")
    }

    @Test(arguments: [ENOTSUP, ENOTTY, ENODEV])
    func aFileSystemWithoutFullSyncFallsBackToFsync(unsupported: Int32) throws {
        let calls = Calls(full: [unsupported], plain: [0])
        try PosixFileLayer.flush(3, calls: calls.flushCalls)
        #expect(calls.plainCount == 1)
        let failing = Calls(full: [unsupported], plain: [EIO])
        #expect(throws: KnotError.writeFailed.with(.init(posixError: EIO))) {
            try PosixFileLayer.flush(3, calls: failing.flushCalls)
        }
    }

    @Test func theLiveCallsFallBackOnADeviceWithoutFullSync() throws {
        // /dev/null sits on devfs, which has no F_FULLFSYNC and answers ENODEV.
        let descriptor = open("/dev/null", O_RDONLY)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(PosixFileLayer.FlushCalls.live.fullSync(descriptor) == ENODEV)
        try PosixFileLayer.flush(descriptor, calls: .live)
    }

    @Test func anInterruptionIsRetried() throws {
        let calls = Calls(full: [EINTR, EINTR, 0])
        try PosixFileLayer.flush(3, calls: calls.flushCalls)
        #expect(calls.fullCount == 3)
        #expect(calls.plainCount == 0)
        let fallback = Calls(full: [ENOTSUP], plain: [EINTR, 0])
        try PosixFileLayer.flush(3, calls: fallback.flushCalls)
        #expect(fallback.plainCount == 2)
    }
}

@Suite struct DurableAncestorTests {
    let new = Data("new".utf8)

    @Test func aSaveIntoAFolderAnotherWriterHasNotSyncedYetSurvives() throws {
        let layer = PowerCutFileLayer()
        let root = URL(fileURLWithPath: "/store", isDirectory: true)
        try DurableFile(layer: layer, root: root).makeFolder(root)
        // Writer A creates /store/A and is paused before it syncs /store.
        try layer.createFolder(root.appending(path: "A"))
        // Writer B finds /store/A, places a file in it, and reports success.
        let b = DurableFile(layer: layer, root: root)
        try b.makeFolder(root.appending(path: "A"))
        try b.place(new, at: root.appending(path: "A/x"))
        layer.cutPower()
        #expect((try? layer.read(root.appending(path: "A/x"))) == new, "An acknowledged save was lost.")
    }

    @Test func aRetryAfterAFailedSyncOfAParentMakesTheFolderDurable() throws {
        let layer = PowerCutFileLayer()
        let root = URL(fileURLWithPath: "/store", isDirectory: true)
        let durable = DurableFile(layer: layer, root: root)
        try durable.makeFolder(root)
        // The first try creates /store/A and dies before it syncs /store.
        layer.die(afterOperations: 1)
        #expect(throws: KnotError.self) { try durable.makeFolder(root.appending(path: "A")) }
        layer.die(afterOperations: 1_000)
        try durable.makeFolder(root.appending(path: "A"))
        try durable.place(new, at: root.appending(path: "A/x"))
        layer.cutPower()
        #expect((try? layer.read(root.appending(path: "A/x"))) == new, "An acknowledged save was lost.")
    }
}

@Suite struct FolderCheckTests {
    let root = URL(fileURLWithPath: "/store", isDirectory: true)

    @Test func aFileWhereAFolderShouldBeIsRefused() throws {
        let layer = PowerCutFileLayer()
        let durable = DurableFile(layer: layer, root: root)
        try durable.makeFolder(root)
        try durable.place(Data("x".utf8), at: root.appending(path: "Inbox"))
        do {
            try DurableFile(layer: layer, root: root).makeFolder(root.appending(path: "Inbox"))
            Issue.record("makeFolder accepted a file as a folder.")
        } catch {
            #expect(error.context.posixError == ENOTDIR)
        }
    }

    @Test func theFakeRefusesToRenameAFileOverAFolder() throws {
        let layer = PowerCutFileLayer()
        let durable = DurableFile(layer: layer, root: root)
        try durable.makeFolder(root.appending(path: "Assets"))
        try layer.write(Data("x".utf8), to: root.appending(path: "f"))
        #expect(throws: KnotError.self) {
            try layer.rename(root.appending(path: "f"), to: root.appending(path: "Assets"))
        }
        #expect(layer.exists(root.appending(path: "Assets")))
    }

    @Test func onDiskAFileOrALinkInThePathIsRefused() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "knot-folders-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = base.appending(path: "KnotStore", directoryHint: .isDirectory)
        let elsewhere = base.appending(path: "Elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: store.appending(path: "Inbox"))
        try FileManager.default.createSymbolicLink(at: store.appending(path: "Assets"), withDestinationURL: elsewhere)
        let durable = DurableFile(layer: PosixFileLayer(), root: store)
        #expect(throws: KnotError.self) { try durable.makeFolder(store.appending(path: "Inbox")) }
        #expect(throws: KnotError.self) { try durable.makeFolder(store.appending(path: "Assets/ab")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty, "A link was followed.")
    }
}
