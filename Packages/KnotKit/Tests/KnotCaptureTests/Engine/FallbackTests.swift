import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// The engine never waits for the store (docs/architecture.md §6, rule 6).
@Suite struct FallbackTests {
    /// Why the store does not take a capture, as the in-memory store plays each case.
    enum StoreCondition: String, CaseIterable, CustomTestStringConvertible {
        /// The store is not open yet: it answers `store_not_open`.
        case notOpen
        /// The store is migrating: it does not answer within its deadline.
        case migrating
        /// Another process holds the write lock: it answers `store_busy`.
        case writeLocked

        var testDescription: String { rawValue }

        /// The code the capture's state carries.
        var code: ErrorCode {
            switch self {
            case .notOpen, .migrating: KnotError.storeNotOpen.code
            case .writeLocked: KnotError.storeBusy.code
            }
        }
    }

    /// A capture begun before the store is open, during a migration and while another process
    /// holds the write lock: a typed capture and a recording each take `Inbox/` and stay on
    /// it until they end, and the store takes both once it answers, each once, where their
    /// items say.
    @Test("capture-before-open-migration-or-write-lock-tracer", .tags(.named), arguments: StoreCondition.allCases)
    func beforeOpenMigrationOrWriteLock(_ condition: StoreCondition) async throws {
        // Ingest runs only when the test says the store answers again.
        let rig = Rig(deadline: condition == .migrating ? .immediate : .patient, engineIngests: false)
        // The store is unavailable for the two starts.
        var holds: [StoreCallHold] = []
        switch condition {
        case .notOpen:
            await rig.notes.failNextCaptureWrites(with: .storeNotOpen, .storeNotOpen)
        case .writeLocked:
            await rig.notes.failNextCaptureWrites(with: .storeBusy, .storeBusy)
        case .migrating:
            for _ in 0..<2 { holds.append(await rig.notes.holdNextCaptureWrite()) }
        }

        // A typed capture.
        let typed = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "w"))
        #expect(typed.path == .inbox(condition.code))
        #expect(typed.noteID == nil)
        #expect(typed.durableRevision == 1, "The first keystroke is durable in Inbox/.")
        #expect(rig.inboxText(typed.captureID) == "w")
        _ = try await rig.engine.update(typed.captureID, with: .text("water the plants"))
        #expect(rig.inboxText(typed.captureID) == "water the plants")

        // A recording, begun after the typed capture ended: its manifest is written first.
        rig.clock.advance(by: 5)
        let ended = try await rig.engine.end(typed.captureID)
        #expect(ended.path == .inbox(condition.code), "A capture that fell back stays on that path until it ends.")
        #expect(ended.outcome == .stored)
        rig.clock.advance(by: 5)
        let recording = try await rig.beginRecording()
        #expect(recording.path == .inbox(condition.code))
        #expect(rig.layer.entryKind(rig.locations.recordingManifest(recording.captureID)) == .file)
        rig.clock.advance(by: 5)
        let stopped = try await rig.engine.end(recording.captureID)
        #expect(stopped.outcome == .stored)
        #expect(stopped.durableRevision > 0)
        // The recording waits as its stored asset and its item; its working file stays until a
        // row points to the asset.
        #expect(try await rig.assets.find(AssetID(recording.captureID), kind: .audio) != nil)
        #expect(rig.layer.entryKind(rig.locations.inboxManifest(recording.captureID)) == .file)

        // Nothing reached the store while it was unavailable.
        if condition != .migrating {
            #expect(try await rig.notes.capture(typed.captureID) == nil)
            #expect(try await rig.notes.capture(recording.captureID) == nil)
        }

        // The store answers now. The migration's held calls commit late, in the order the
        // captures began; then ingest stores each capture once, where its item says.
        for (hold, capture) in zip(holds, [typed.captureID, recording.captureID]) {
            await reached(hold)
            hold.release()
            #expect(await eventually("the late record to commit") { (try? await rig.notes.capture(capture)) != nil })
        }
        let ingested = await rig.ingest.ingestAll()
        #expect(ingested.count == 2)
        #expect(
            await eventually("both captures to be stored") {
                let rows = [
                    try? await rig.notes.capture(typed.captureID), try? await rig.notes.capture(recording.captureID),
                ]
                return rows.allSatisfy { $0?.outcome == .stored }
            })
        #expect(rig.inboxFiles().isEmpty)
        let page = try await rig.stream()
        try #require(page.notes.count == 1)
        let segments = page.notes[0].liveSegments
        #expect(segments.map(\.id) == [SegmentID(typed.captureID), SegmentID(recording.captureID)])
        #expect(segments.first?.text == "water the plants")
        #expect(segments.last?.assetID == AssetID(recording.captureID))
        #expect(try await rig.notes.jobs(for: SegmentID(recording.captureID)).map(\.kind) == [.transcribe])
        #expect(rig.layer.entryKind(rig.locations.recordingAudio(recording.captureID, format: .caf)) == nil)
    }

    /// A store call that commits after its capture fell back to `Inbox/`: the row is made
    /// once, by whichever arrives first, the late call changes nothing that a later save made,
    /// and the capture ends where its item says.
    @Test(
        "store-call-commits-after-inbox-fallback-tracer", .tags(.named),
        arguments: [LateOrder.commitBeforeIngest, .ingestBeforeCommit])
    func storeCallCommitsAfterFallback(_ order: LateOrder) async throws {
        let rig = Rig(deadline: .immediate)
        let hold = await rig.notes.holdNextCaptureWrite()
        let begun = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "t"))
        let id = begun.captureID
        #expect(begun.path == .inbox(KnotError.storeNotOpen.code))
        await reached(hold)
        _ = try await rig.engine.update(id, with: .text("tell the neighbour"))

        switch order {
        case .commitBeforeIngest:
            // The record call commits now: an open row with the first keystroke.
            hold.release()
            #expect(
                await eventually("the late record to commit") {
                    (try? await rig.notes.capture(id))?.outcome == .open
                })
            // Later saves stay on the file path, and the store is not sent them.
            _ = try await rig.engine.update(id, with: .text("tell the neighbour about the keys"))
            #expect(try await rig.notes.segment(SegmentID(id))?.text == "t")
            let ended = try await rig.engine.end(id)
            #expect(ended.path == .inbox(KnotError.storeNotOpen.code))
        case .ingestBeforeCommit:
            _ = try await rig.engine.update(id, with: .text("tell the neighbour about the keys"))
            _ = try await rig.engine.end(id)
            // The end's ingest runs while the record call still waits, and makes the row.
            #expect(
                await eventually("the item to be ingested") {
                    (try? await rig.notes.capture(id))?.outcome == .stored
                })
            hold.release()
            // The late record is a repeat of an older save: it changes nothing.
            #expect(await eventually("the late record to answer") { rig.logs.logged("store_answered_late", id) })
        }

        #expect(
            await eventually("the capture to be stored") {
                (try? await rig.notes.capture(id))?.outcome == .stored
            })
        let row = try #require(try await rig.notes.capture(id))
        #expect(row.revision == 3)
        #expect(row.launchID == rig.launchID)
        #expect(rig.inboxFiles().isEmpty)
        let page = try await rig.stream()
        #expect(page.notes.count == 1)
        #expect(page.notes.first?.liveSegments.map(\.text) == ["tell the neighbour about the keys"])
        #expect(try await rig.notes.openCaptures().isEmpty)
    }

    enum LateOrder: String, CustomTestStringConvertible {
        case commitBeforeIngest
        case ingestBeforeCommit
        var testDescription: String { rawValue }
    }
}
