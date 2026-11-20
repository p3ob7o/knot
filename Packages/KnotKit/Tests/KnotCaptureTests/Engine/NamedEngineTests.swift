import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// The named tests of WP-11 (docs/plan/named-tests.txt), apart from the soak's kill points,
/// which come with WP-11 PR 2, and `engine-random-interleavings`, in its own file.
@Suite struct NamedEngineTests {
    private static let notOpen = KnotError.storeNotOpen.code

    // MARK: late-draft-save-must-not-replace-newer-text

    enum LateOrder: String, CaseIterable, CustomTestStringConvertible {
        /// The late save commits while the capture is still open.
        case beforeTheEnd
        /// The late save commits after ingest stored the capture's end.
        case afterTheIngest
        var testDescription: String { rawValue }
    }

    /// A draft save that misses its deadline commits late, after newer text went to `Inbox/`.
    /// Whenever it commits, the newest text is what the store keeps, at its revision.
    @Test("late-draft-save-must-not-replace-newer-text", .tags(.named), arguments: LateOrder.allCases)
    func lateDraftSave(_ order: LateOrder) async throws {
        let r = Rig()
        let manual = ManualDeadline()
        let engine = BoundedEngine(r.engine(deadline: manual.deadline))
        let begun = try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "buy"))
        #expect(begun.path == .store)
        let id = begun.captureID
        // Revision 2 is held in the store and misses its deadline: it goes to `Inbox/`.
        let hold = await r.notes.holdNextCaptureWrite()
        let second = Task { try await engine.update(id, with: .text("buy milk")) }
        await reached(hold)
        await manual.expireNext()
        let fell = try await second.value
        #expect(fell.path == .inbox(Self.notOpen))
        #expect(fell.durableRevision == 2)
        // Revision 3, newer, is in `Inbox/` only.
        let third = try await engine.update(id, with: .text("buy milk and eggs"))
        #expect(third.durableRevision == 3)
        #expect(r.inboxText(id) == "buy milk and eggs")

        switch order {
        case .beforeTheEnd:
            hold.release()
            #expect(
                await eventually("the late save to commit") { (try? await r.notes.capture(id))?.revision == 2 })
            _ = try await engine.end(id)
        case .afterTheIngest:
            _ = try await engine.end(id)
            #expect(
                await eventually("the end to be ingested") {
                    let row = try? await r.notes.capture(id)
                    return row?.outcome == .stored && row?.revision == 3
                })
            hold.release()
            #expect(await eventually("the late save to answer") { r.logs.logged("store_answered_late", id) })
        }
        #expect(
            await eventually("the newest text to be stored") {
                (try? await r.notes.segment(SegmentID(id)))?.segment.text == "buy milk and eggs"
            })
        let row = try #require(try await r.notes.capture(id))
        #expect(row.revision == 3)
        #expect(row.outcome == .stored)
        #expect(r.inboxFiles().isEmpty)
        #expect(try await r.notesText() == [["buy milk and eggs"]])
    }

    // MARK: capture-before-open-migration-or-write-lock-engine

    /// A capture begun before the store is open, during a migration and while another process
    /// holds the write lock. A typed capture on the app takes `Inbox/`; a typed start on the Mac
    /// panel ends it (rule 15) and goes the same way; a recording on the intent surface ends that
    /// one and goes the same way too. With appending off, they are still one note: each started
    /// as it ended the one before (rules 2 and 15). Once the store answers, ingest stores each
    /// once, in the order they began.
    @Test(
        "capture-before-open-migration-or-write-lock-engine", .tags(.named),
        arguments: FallbackTests.StoreCondition.allCases)
    func beforeOpenMigrationOrWriteLock(_ condition: FallbackTests.StoreCondition) async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        let manual = ManualDeadline()
        let engine = BoundedEngine(r.engine(deadline: manual.deadline, ingests: false))
        // Only the first capture asks the store: the two that follow it go its way.
        var hold: StoreCallHold?
        switch condition {
        case .notOpen: await r.notes.failNextCaptureWrites(with: .storeNotOpen)
        case .writeLocked: await r.notes.failNextCaptureWrites(with: .storeBusy)
        case .migrating: hold = await r.notes.holdNextCaptureWrite()
        }
        let typing = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "w")) }
        if let hold {
            await reached(hold)
            await manual.expireNext()
        }
        let first = try await typing.value
        #expect(first.path == .inbox(condition.code))
        _ = try await engine.update(first.captureID, with: .text("water the plants"))

        r.clock.advance(by: 10)
        let second = try await engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "and the fern"))
        #expect(second.path == .inbox(condition.code), "It goes the way of the capture it follows.")
        r.clock.advance(by: 10)
        let recording = try await r.beginRecording(CaptureRequest(kind: .voice, surface: .intent), on: engine)
        #expect(recording.path == .inbox(condition.code))
        r.clock.advance(by: 10)
        let stopped = try await engine.end(recording.captureID)
        #expect(stopped.outcome == .stored)
        // Nothing reached the store while it did not answer.
        for capture in [first.captureID, second.captureID, recording.captureID] {
            if condition != .migrating { #expect(try await r.notes.capture(capture) == nil) }
        }
        // The rows are made once the store answers: a migration's held call commits late.
        hold?.release()
        if condition == .migrating {
            #expect(
                await eventually("the late record to commit") {
                    (try? await r.notes.capture(first.captureID)) != nil
                })
        }
        let ingested = await r.ingest.ingestAll()
        #expect(ingested.count == 3)
        #expect(r.inboxFiles().isEmpty)
        #expect(try await r.notes.openCaptures().isEmpty)
        let page = try await r.stream()
        try #require(page.notes.count == 1, "One note: each capture started as it ended the one before.")
        let segments = page.notes[0].liveSegments
        #expect(segments.map(\.id) == [first, second, recording].map { SegmentID($0.captureID) })
        #expect(segments.prefix(2).map(\.text) == ["water the plants", "and the fern"])
        let ended = try #require(try await r.notes.capture(first.captureID))
        #expect(ended.endedAt == r.clock.now().addingTimeInterval(-20), "Ended at the next capture's start.")
        #expect(try await r.notes.jobs(for: SegmentID(recording.captureID)).map(\.kind) == [.transcribe])
    }

    // MARK: disk-fills-during-draft-save

    enum DiskCase: String, CaseIterable, CustomTestStringConvertible {
        /// On the store path: the store's save fails with a full disk, and so does `Inbox/`.
        case storePath
        /// On the `Inbox/` path: the item's write fails.
        case inboxPath
        /// Through the capture session, as the surface types.
        case session
        var testDescription: String { rawValue }
    }

    /// A disk that fills during a draft save. The save is not acknowledged: the call throws
    /// `disk_full`, the durable revision stays, and the surface keeps the text. Once there is
    /// room, the next save carries the whole text, and nothing is lost.
    @Test("disk-fills-during-draft-save", .tags(.named), arguments: DiskCase.allCases)
    func diskFillsDuringDraftSave(_ diskCase: DiskCase) async throws {
        let r = Rig()
        let engine = BoundedEngine(r.engine())
        if diskCase == .inboxPath { await r.notes.failNextCaptureWrites(with: .storeNotOpen) }

        if diskCase == .session {
            let session = r.session(.app, engine: engine.engine)
            await session.type("pack")
            let begun = try await within("the first save") { try await session.flush() }
            #expect(begun?.durableRevision == 1)
            await r.notes.failNextCaptureWrites(with: .diskFull)
            r.layer.failNextWrite(with: .diskFull)
            await session.type("pack the tent")
            await expectError(.diskFull) { try await within("the failed save") { try await session.flush() } }
            // The disk has room again: the next keystroke saves the whole text.
            await session.type("pack the tent and stove")
            let saved = try await within("the next save") { try await session.flush() }
            #expect(saved?.path == .inbox(KnotError.diskFull.code))
            let ended = try await within("the end") { try await session.end() }
            #expect(ended?.outcome == .stored)
            let id = try #require(ended?.captureID)
            #expect(
                await eventually("the text to be stored") {
                    (try? await r.notes.segment(SegmentID(id)))?.segment.text == "pack the tent and stove"
                })
            return
        }

        let begun = try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "pack"))
        let id = begun.captureID
        #expect(begun.durableRevision == 1)
        if diskCase == .storePath { await r.notes.failNextCaptureWrites(with: .diskFull) }
        r.layer.failNextWrite(with: .diskFull)
        await expectError(.diskFull) { try await engine.update(id, with: .text("pack the tent")) }
        if diskCase == .inboxPath { #expect(r.inboxText(id) == "pack", "The item keeps the save before.") }
        let saved = try await engine.update(id, with: .text("pack the tent and stove"))
        #expect(saved.durableRevision == 3)
        #expect(r.inboxText(id) == "pack the tent and stove")
        _ = try await engine.end(id)
        #expect(
            await eventually("the text to be stored") {
                (try? await r.notes.segment(SegmentID(id)))?.segment.text == "pack the tent and stove"
            })
        #expect(r.inboxFiles().isEmpty)
        #expect(try await r.notes.openCaptures().isEmpty)
    }

    // MARK: store-call-commits-after-inbox-fallback-engine

    enum LateCall: String, CaseIterable, CustomTestStringConvertible {
        /// The record of a typed capture that a start on another surface then follows.
        case followedTypedCapture
        /// The record of a recording that then ends.
        case recordingThatEnds
        /// The record of a recording that is discarded after the row arrived.
        case recordingDiscardedAfterTheRow
        /// The record of a recording that is discarded before the row arrives.
        case recordingDiscardedBeforeTheRow
        var testDescription: String { rawValue }
    }

    /// A store call that commits after its capture fell back to `Inbox/`. The row is made once,
    /// by whichever arrives first; the capture stays on the file path until it ends, and ends
    /// where its item says; a discarded recording's late row is ended as empty.
    @Test("store-call-commits-after-inbox-fallback-engine", .tags(.named), arguments: LateCall.allCases)
    func storeCallCommitsAfterFallback(_ late: LateCall) async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        let manual = ManualDeadline()
        let engine = BoundedEngine(r.engine(deadline: manual.deadline, ingests: false))
        let hold = await r.notes.holdNextCaptureWrite()
        let kind: SegmentKind = late == .followedTypedCapture ? .typed : .voice
        let starting = Task {
            try await engine.begin(CaptureRequest(kind: kind, surface: .app, text: kind == .typed ? "a" : nil))
        }
        await reached(hold)
        await manual.expireNext()
        let first = try await starting.value
        let id = first.captureID
        #expect(first.path == .inbox(Self.notOpen))

        switch late {
        case .followedTypedCapture:
            r.clock.advance(by: 5)
            let next = try await engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "b"))
            #expect(next.path == .inbox(Self.notOpen), "It goes the way of the capture it follows.")
            hold.release()
            #expect(await eventually("the late row") { (try? await r.notes.capture(id))?.outcome == .open })
            _ = try await engine.end(next.captureID)
            _ = await r.ingest.ingestAll()
            #expect(try await r.notesText() == [["a", "b"]], "One note: the second ended the first.")
        case .recordingThatEnds:
            _ = try await engine.end(id)
            hold.release()
            #expect(await eventually("the late row") { (try? await r.notes.capture(id)) != nil })
            _ = await r.ingest.ingestAll()
            #expect(try await r.notes.capture(id)?.outcome == .stored)
            #expect(try await r.notes.jobs(for: SegmentID(id)).map(\.kind) == [.transcribe])
        case .recordingDiscardedAfterTheRow:
            hold.release()
            #expect(await eventually("the late row") { r.logs.logged("store_answered_late", id) })
            let discarded = try await engine.discard(id)
            #expect(discarded.outcome == .discardedEmpty)
            await engine.retryConversions()
            #expect(try await r.notes.capture(id)?.outcome == .discardedEmpty)
        case .recordingDiscardedBeforeTheRow:
            let discarded = try await engine.discard(id)
            #expect(discarded.outcome == .discardedEmpty)
            hold.release()
            #expect(
                await eventually("the late row to be ended as empty") {
                    (try? await r.notes.capture(id))?.outcome == .discardedEmpty
                })
        }
        #expect(try await r.notes.openCaptures().isEmpty)
        #expect(r.inboxFiles().isEmpty)
        if late == .recordingDiscardedAfterTheRow || late == .recordingDiscardedBeforeTheRow {
            #expect(try await r.stream().notes.isEmpty)
        }
    }

    // MARK: text-past-size-limit-repeated-engine

    /// Synthetic text a little over two segments long.
    static let longText: String = {
        let line = "the quick brown fox jumps over the lazy dog, again and again\n"
        let lines = (Limits.segmentTextBytes * 2 + 1_000) / line.utf8.count + 1
        return String(repeating: line, count: lines)
    }()

    enum LongPath: String, CaseIterable, CustomTestStringConvertible {
        /// The store takes the capture; the end repeats the same text.
        case store
        /// The record misses its deadline and commits late; ingest then repeats the capture.
        case lateRecordThenIngest
        var testDescription: String { rawValue }
    }

    /// Text that runs past the size limit, repeated. It continues in further segments of the
    /// same capture, in the same note, and nothing is cut: the first segment shares the capture's
    /// ID and each later one has the ID derived from the capture's and its position. A repeat of
    /// the capture returns the same segments, and the ledger counts the capture once.
    @Test("text-past-size-limit-repeated-engine", .tags(.named), arguments: LongPath.allCases)
    func longTextRepeated(_ path: LongPath) async throws {
        let r = Rig(engineIngests: false)
        let manual = ManualDeadline()
        let engine = BoundedEngine(r.engine(deadline: manual.deadline, ingests: false))
        let text = Self.longText
        var hold: StoreCallHold?
        if path == .lateRecordThenIngest { hold = await r.notes.holdNextCaptureWrite() }
        let starting = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: text)) }
        if let hold {
            await reached(hold)
            await manual.expireNext()
        }
        let begun = try await starting.value
        let id = begun.captureID
        _ = try await engine.end(id)
        if let hold {
            #expect(r.inboxText(id) == text, "The item holds the whole text, uncut.")
            hold.release()
            #expect(await eventually("the late row") { (try? await r.notes.capture(id)) != nil })
            _ = await r.ingest.ingestAll()
        }
        let expected = TextPieces.pieces(of: text, capture: id)
        #expect(expected.count == 3)
        let first = try await Self.pieces(of: id, in: r)
        #expect(first.map(\.id) == expected.map(\.segmentID))
        #expect(first.map(\.text).joined() == text, "Nothing is cut.")
        #expect(Set(first.map(\.noteID)).count == 1, "One note.")
        // The capture again: the end once more, and ingest of nothing new.
        _ = try await engine.end(id)
        _ = await r.ingest.ingestAll()
        let again = try await Self.pieces(of: id, in: r)
        #expect(again.map(\.id) == first.map(\.id))
        #expect(again.map(\.text) == first.map(\.text))
        #expect(try await r.notes.openCaptures().isEmpty)
        #expect(r.inboxFiles().isEmpty)
        #expect(try await r.stream().notes.flatMap(\.liveSegments).count == expected.count)
    }

    private static func pieces(of capture: CaptureID, in r: Rig) async throws -> [Segment] {
        let note = try #require(try await r.note(of: capture))
        let record = try #require(try await r.notes.note(note))
        return record.segments.filter { $0.id == SegmentID(capture) || $0.pieceOf == SegmentID(capture) }
            .sorted { $0.piece < $1.piece }
    }
}
