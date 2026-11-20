import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@Suite struct IngestTests {
    enum Save: String, CaseIterable, CustomTestStringConvertible {
        case update
        case end
        var testDescription: String { rawValue }
    }

    /// A death between two writes of a save into `Inbox/`, at every file operation of it, then
    /// a power cut: at the next launch the store holds what was acknowledged, or the save that
    /// reached the drive whole, and never less.
    @Test(arguments: Save.allCases)
    func deathAtEveryPointOfAnInboxSave(_ save: Save) async throws {
        // How many file operations one save takes.
        let probe = try await Self.capture(on: Rig(engineIngests: false))
        let before = probe.rig.layer.operationCount
        try await Self.perform(save, of: probe.id, on: probe.rig)
        let operations = probe.rig.layer.operationCount - before
        #expect(operations > 2)

        for point in 0...operations {
            let (rig, id) = try await Self.capture(on: Rig(engineIngests: false))
            rig.layer.die(afterOperations: point)
            var acknowledged = "one"
            do {
                try await Self.perform(save, of: id, on: rig)
                acknowledged = "one two"
            } catch {}
            rig.layer.cutPower()

            let next = rig.relaunch()
            _ = await next.ingest.ingestAll()
            _ = try await next.recovery.finishOpenCaptures(recovered: [])
            let text = try await next.notes.segment(SegmentID(id))?.text
            #expect(
                text == acknowledged || text == "one two",
                "A death after operation \(point) of \(operations) left \(String(describing: text)).")
            #expect(try await next.notes.capture(id)?.outcome == .stored, "After operation \(point).")
            #expect(next.inboxFiles().isEmpty, "After operation \(point): \(next.inboxFiles()).")
        }
    }

    /// A typed capture on the `Inbox/` path, with its first save acknowledged.
    private static func capture(on rig: Rig) async throws -> (rig: Rig, id: CaptureID) {
        await rig.notes.failNextCaptureWrites(with: .storeBusy)
        let begun = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "one"))
        #expect(begun.durableRevision == 1)
        return (rig, begun.captureID)
    }

    private static func perform(_ save: Save, of id: CaptureID, on rig: Rig) async throws {
        _ = try await rig.engine.update(id, with: .text("one two"))
        if save == .end { _ = try await rig.engine.end(id) }
    }

    /// An item whose capture is still open in this launch belongs to the engine.
    @Test func itemOfAnOpenCaptureOfThisLaunchIsLeftAlone() async throws {
        let rig = Rig(engineIngests: false)
        await rig.notes.failNextCaptureWrites(with: .storeBusy)
        let begun = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "h"))
        let outcomes = await rig.ingest.ingestAll()
        #expect(outcomes[begun.captureID] == .leftOpen)
        #expect(try await rig.notes.capture(begun.captureID) == nil)
        #expect(rig.inboxText(begun.captureID) == "h")
    }

    /// When the store does not answer, ingest keeps the item and stops; the next run stores
    /// everything, in the order the captures started.
    @Test func ingestStopsWhileTheStoreDoesNotAnswer() async throws {
        let rig = Rig(engineIngests: false)
        await rig.notes.failNextCaptureWrites(with: .storeBusy, .storeBusy)
        var ids: [CaptureID] = []
        for text in ["first", "second"] {
            let begun = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: text))
            _ = try await rig.engine.end(begun.captureID)
            ids.append(begun.captureID)
            rig.clock.advance(by: 10)
        }
        await rig.notes.failNextCaptureWrites(with: .storeNotOpen)
        let stopped = await rig.ingest.ingestAll()
        #expect(stopped == [ids[0]: .kept(KnotError.storeNotOpen.code)])
        #expect(rig.inboxFiles().count == 4)

        let stored = await rig.ingest.ingestAll()
        #expect(stored.count == 2)
        let page = try await rig.stream()
        #expect(page.notes.flatMap { $0.liveSegments.map(\.text) } == ["first", "second"])
        #expect(rig.inboxFiles().isEmpty)
        // Ingested again, nothing changes.
        #expect(await rig.ingest.ingestAll().isEmpty)
    }

    /// An item of this launch caught between its two writes, the manifest of an end placed and
    /// its text not yet, is left for the engine: ingest neither stores the older text nor
    /// removes the manifest. A death there leaves it to the next launch, which stores the text
    /// that was acknowledged.
    @Test func halfWrittenItemOfThisLaunchIsLeftAlone() async throws {
        let rig = Rig(engineIngests: false)
        await rig.notes.failNextCaptureWrites(with: .storeBusy)
        let begun = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "a"))
        let id = begun.captureID
        _ = try await rig.engine.update(id, with: .text("ab"))
        // The end's manifest is on the drive; its text is not.
        var manifest = try CaptureManifest.decode(try rig.layer.read(rig.locations.inboxManifest(id)))
        manifest.endedAt = rig.clock.now()
        manifest.revision = 3
        manifest.payloadSHA256 = String(repeating: "0", count: 64)
        try rig.locations.durableFiles(layer: rig.layer).place(
            try manifest.encoded(), at: rig.locations.inboxManifest(id))

        #expect(await rig.ingest.ingestAll() == [id: .leftOpen])
        #expect(try await rig.notes.capture(id) == nil)
        #expect(rig.inboxFiles().count == 2)

        let next = rig.relaunch()
        #expect(await next.ingest.ingestAll() == [id: .stored(revision: 3)])
        #expect(try await next.notes.segment(SegmentID(id))?.text == "ab")
        #expect(next.inboxFiles().isEmpty)
    }

    /// A manifest with no text beside it named nothing that reached the drive: it is removed,
    /// and the store is not touched.
    @Test func manifestWithoutItsTextIsRemoved() async throws {
        let rig = Rig(engineIngests: false)
        let id: CaptureID = rig.ids.make()
        let manifest = CaptureManifest(
            captureID: id, kind: .typed, origin: CaptureOrigin(source: .device(rig.deviceID), surface: .app),
            launchID: rig.ids.make(), startedAt: rig.clock.now(), placement: .window, revision: 1)
        try rig.locations.durableFiles(layer: rig.layer).place(
            try manifest.encoded(), at: rig.locations.inboxManifest(id))
        #expect(await rig.ingest.ingestAll() == [id: .removedEmpty])
        #expect(rig.inboxFiles().isEmpty)
        #expect(try await rig.notes.capture(id) == nil)
    }
}

@Suite struct RecoveryTests {
    /// A typed capture an earlier launch left open ends at the last durable save the store
    /// wrote on its row, with the text that save holds.
    @Test func openTypedCaptureEndsAtItsLastSave() async throws {
        let rig = Rig()
        let begun = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "d"))
        rig.clock.advance(by: 4)
        _ = try await rig.engine.update(begun.captureID, with: .text("dentist on friday"))
        let savedAt = rig.clock.now()
        rig.clock.advance(by: 600)

        let next = rig.relaunch()
        let outcomes = try await next.recovery.run(ingest: next.ingest)
        #expect(outcomes[begun.captureID] == .ended(.stored))
        let row = try #require(try await next.notes.capture(begun.captureID))
        #expect(row.endedAt == savedAt)
        #expect(try await next.notes.segment(SegmentID(begun.captureID))?.text == "dentist on friday")
        #expect(try await next.notes.openCaptures().isEmpty)
    }

    /// Recovery never touches a capture of the current launch.
    @Test func captureOfTheCurrentLaunchIsNotRecovered() async throws {
        let rig = Rig()
        let begun = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "n"))
        let outcomes = try await rig.recovery.run(ingest: rig.ingest)
        #expect(outcomes.isEmpty)
        #expect(try await rig.notes.capture(begun.captureID)?.outcome == .open)
    }

    /// A recording an earlier launch left ends at the end of the audio its file holds, as its
    /// stored asset, and goes on to transcription.
    @Test func orphanedRecordingIsStoredAndTranscribed() async throws {
        let rig = Rig()
        rig.transcriber.scriptUnscriptedFiles(pieces: ScriptedTranscriber.defaultScript)
        let begun = try await rig.beginRecording()
        rig.clock.advance(by: 120)

        let next = rig.relaunch()
        let outcomes = try await next.recovery.run(ingest: next.ingest)
        #expect(outcomes[begun.captureID] == .ended(.stored))
        let row = try #require(try await next.notes.capture(begun.captureID))
        let segment = try #require(try await next.notes.segment(SegmentID(begun.captureID)))
        let duration = try #require(segment.duration)
        let (seconds, attoseconds) = duration.components
        #expect(
            row.endedAt == row.startedAt.addingTimeInterval(TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18))
        #expect(segment.assetID == AssetID(begun.captureID))
        #expect(next.layer.entryKind(next.locations.recordingAudio(begun.captureID, format: .caf)) == nil)
        try await next.queue.resume()
        #expect(await next.drain() == .idle)
        #expect(try await next.notes.segment(SegmentID(begun.captureID))?.state == .voice(.ready))
        #expect(
            try await next.notes.segment(SegmentID(begun.captureID))?.text == "a scripted transcript of a recording")
    }

    /// A recording whose row the store never took is made from its recorder's manifest.
    @Test func orphanedRecordingWithoutARowIsStored() async throws {
        let rig = Rig(engineIngests: false)
        await rig.notes.failNextCaptureWrites(with: .storeBusy)
        let begun = try await rig.beginRecording(CaptureRequest(kind: .voice, surface: .control, placement: .newNote))
        #expect(try await rig.notes.capture(begun.captureID) == nil)

        let next = rig.relaunch()
        let outcomes = try await next.recovery.run(ingest: next.ingest)
        #expect(outcomes[begun.captureID] == .ended(.stored))
        let row = try #require(try await next.notes.capture(begun.captureID))
        #expect(row.placement == .newNote)
        #expect(row.origin.surface == .control)
        #expect(row.launchID == rig.launchID)
        #expect(try await next.notes.jobs(for: SegmentID(begun.captureID)).map(\.kind) == [.transcribe])
    }

    /// Ingest comes before recovery: an item a crash left in `Inbox/` ends its open row with
    /// the item's content, which is newer than what the row holds.
    @Test func ingestRunsBeforeRecovery() async throws {
        let rig = Rig(engineIngests: false)
        let begun = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "draft"))
        await rig.notes.failNextCaptureWrites(with: .storeBusy)
        _ = try await rig.engine.update(begun.captureID, with: .text("draft, then more"))
        #expect(rig.inboxText(begun.captureID) == "draft, then more")
        #expect(try await rig.notes.segment(SegmentID(begun.captureID))?.text == "draft")

        let next = rig.relaunch()
        _ = try await next.recovery.run(ingest: next.ingest)
        #expect(try await next.notes.segment(SegmentID(begun.captureID))?.text == "draft, then more")
        #expect(try await next.notes.capture(begun.captureID)?.outcome == .stored)
        #expect(next.inboxFiles().isEmpty)
    }
}
