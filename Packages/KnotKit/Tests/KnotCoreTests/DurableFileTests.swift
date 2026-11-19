import Foundation
import KnotCore
import KnotTestSupport
import Testing

@Suite struct DurableFileTests {
    let folder = URL(fileURLWithPath: "/store/Inbox", isDirectory: true)
    var target: URL { folder.appending(path: "capture.json") }
    let old = Data("old content".utf8)
    let new = Data("new content, longer".utf8)

    /// A layer whose folder exists and whose target holds `old`, all synced.
    func layerWithOldFile() throws -> PowerCutFileLayer {
        let layer = PowerCutFileLayer()
        try DurableFile(layer: layer).makeFolder(folder)
        try DurableFile(layer: layer).place(old, at: target)
        return layer
    }

    @Test("file-layer-drops-unsynced-writes", .tags(.named))
    func theFileLayerDropsUnsyncedWritesAndRecoveryHolds() throws {
        // The layer drops what was not synced: a plain write, and a synced file whose name
        // the folder never synced.
        let plain = PowerCutFileLayer()
        try plain.createFolder(folder)
        try plain.write(new, to: target)
        plain.cutPower()
        #expect(!plain.exists(target))
        try plain.write(new, to: target)
        try plain.syncFile(target)
        plain.cutPower()
        #expect(!plain.exists(target))

        // A file placed by DurableFile survives.
        let placed = try layerWithOldFile()
        try DurableFile(layer: placed).place(new, at: target)
        placed.cutPower()
        #expect(try placed.read(target) == new)

        // Cut the power after each operation of a placement in turn. The target holds the old
        // content or the new, whole, and once the call returned, and the row that points to
        // the file could be committed, it holds the new.
        let probe = try layerWithOldFile()
        let start = probe.operationCount
        try DurableFile(layer: probe).place(new, at: target)
        let steps = probe.operationCount - start
        #expect(steps == 4, "write, sync, rename, sync the folder")
        for cut in 0...steps {
            let layer = try layerWithOldFile()
            layer.die(afterOperations: cut)
            var rowCommitted = false
            do {
                try DurableFile(layer: layer).place(new, at: target)
                rowCommitted = true
            } catch {
                #expect(error == .writeFailed)
            }
            layer.cutPower()
            let content = try layer.read(target)
            #expect(content == old || content == new, "Cut after \(cut) operations: a part of a file.")
            if rowCommitted { #expect(content == new, "Cut after \(cut) operations: a committed row lost its file.") }
            // What a crash left beside the target is cleared at relaunch.
            try DurableFile(layer: layer).removePartials(in: folder)
            #expect(try layer.contents(of: folder) == ["capture.json"])
        }
    }

    @Test func aMoveIsDurableToo() throws {
        let received = URL(fileURLWithPath: "/store/Received", isDirectory: true)
        for cut in 0...4 {
            let layer = PowerCutFileLayer()
            let durable = DurableFile(layer: layer)
            try durable.makeFolder(folder)
            try durable.makeFolder(received)
            try durable.place(new, at: received.appending(path: "file.m4a"))
            layer.die(afterOperations: cut)
            var acknowledged = false
            do {
                try durable.move(received.appending(path: "file.m4a"), to: folder.appending(path: "file.m4a"))
                acknowledged = true
            } catch {}
            layer.cutPower()
            let there = layer.exists(folder.appending(path: "file.m4a"))
            let left = layer.exists(received.appending(path: "file.m4a"))
            #expect(there || left, "Cut after \(cut): the file is in neither folder.")
            if acknowledged { #expect(there && !left) }
            if there { #expect(try layer.read(folder.appending(path: "file.m4a")) == new) }
        }
    }

    @Test func aFullDiskLeavesTheOldFile() throws {
        let layer = try layerWithOldFile()
        layer.failNextWrite(with: .diskFull)
        #expect(throws: KnotError.diskFull) { try DurableFile(layer: layer).place(new, at: target) }
        layer.cutPower()
        #expect(try layer.read(target) == old)
    }

    @Test func aRemovalStays() throws {
        let layer = try layerWithOldFile()
        try DurableFile(layer: layer).remove(target)
        layer.cutPower()
        #expect(!layer.exists(target))
    }

    @Test func thePosixLayerPlacesReadsMovesAndRemoves() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "knot-durable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let durable = DurableFile(layer: PosixFileLayer())
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
        #expect(throws: KnotError.self) { try durable.place(new, at: root.appending(path: "missing/c.json")) }
        do {
            try durable.place(new, at: root.appending(path: "missing/c.json"))
        } catch {
            #expect(error.code == KnotError.writeFailed.code)
            #expect(error.context.posixError == ENOENT)
        }
    }
}
