import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// The sequences the review of pull request 40 found, each a witness first shown failing.
@Suite struct ReviewEngineTests {
    /// Finding 1. A begin that reached no disk keeps its capture: the surface's retry of the
    /// text is the same capture, with the same ID, so a row the store made late and the retry
    /// reconcile into one segment.
    @Test(arguments: [false, true])
    func retryOfABeginThatReachedNoDiskIsTheSameCapture(lateRowFirst: Bool) async throws {
        let r = Rig(deadline: .immediate)
        let pending = await r.notes.holdNextCaptureWrite()
        r.layer.failNextWrite(with: .diskFull)
        let request = CaptureRequest(kind: .typed, surface: .app, text: "book the room")
        let error = await expectError(.diskFull) { try await r.engine.begin(request) }
        let id = try #require(error?.context.captureID)
        await reached(pending)
        if lateRowFirst {
            pending.release()
            #expect(await eventually("the late row") { r.logs.logged("store_answered_late", id) })
        }
        // The surface sends the text it kept again.
        let retry = try await r.engine.begin(request)
        #expect(retry.captureID == id)
        #expect(retry.durableRevision == 2)
        _ = try await r.engine.end(id)
        if !lateRowFirst { pending.release() }
        #expect(await eventually("the capture to be stored") { (try? await r.notes.capture(id))?.outcome == .stored })

        let next = r.relaunch()
        _ = try await next.recovery.run(ingest: next.ingest)
        let copies = try await next.stream().notes.flatMap(\.liveSegments).filter { $0.text == "book the room" }
        #expect(copies.map(\.id) == [SegmentID(id)])
        #expect(try await next.notes.openCaptures().isEmpty)
    }

    /// Finding 1. A row the store made late for a begin that reached no disk holds the text:
    /// the engine says it is durable then, and does not end it as empty.
    @Test func lateRowOfABeginThatReachedNoDiskIsAcknowledged() async throws {
        let r = Rig(deadline: .immediate)
        let states = r.engine.states()
        let pending = await r.notes.holdNextCaptureWrite()
        r.layer.failNextWrite(with: .diskFull)
        let error = await expectError(.diskFull) {
            try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "g"))
        }
        let id = try #require(error?.context.captureID)
        await reached(pending)
        pending.release()
        let acknowledged = await SuiteWait.value("the late row to be acknowledged") {
            for await state in states where state.captureID == id && state.durableRevision == 1 { return true }
            return false
        }
        #expect(acknowledged == true)
        #expect(try await r.notes.capture(id)?.outcome == .open)
        #expect(try await r.notes.segment(SegmentID(id))?.text == "g")
    }

    /// Finding 2. A checkpoint the store did not apply, because it holds a higher revision of
    /// other content, is not durable: the engine saves the text again above the stored
    /// revision, and acknowledges it only then.
    @Test func checkpointBelowTheStoredRevisionIsSavedAgainAboveIt() async throws {
        let r = Rig()
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "first"))
        _ = try await r.notes.checkpoint(CaptureCheckpoint(captureID: a.captureID, text: "other", revision: 8))
        let acknowledged = try await r.engine.update(a.captureID, with: .text("mine"))
        #expect(acknowledged.path == .store)
        #expect(acknowledged.durableRevision == 9)
        #expect(try await r.notes.segment(SegmentID(a.captureID))?.text == "mine")
        #expect(try await r.notes.capture(a.captureID)?.revision == 9)
        // The engine's revisions go on from there.
        #expect(try await r.engine.update(a.captureID, with: .text("mine too")).durableRevision == 10)
    }

    /// An end with nothing new keeps the higher revision the store holds (the second opinion's
    /// `lowerRevisionEndKeepsWinningText`, which held already).
    @Test func endWithNothingNewKeepsTheStoredText() async throws {
        let r = Rig()
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "old"))
        _ = try await r.notes.checkpoint(CaptureCheckpoint(captureID: a.captureID, text: "winner", revision: 9))
        _ = try await r.engine.end(a.captureID)
        #expect(try await r.notes.segment(SegmentID(a.captureID))?.text == "winner")
    }

    /// Finding 4. With appending off, typing on the `Inbox/` path and then a recording are one
    /// note (product spec §3, rules 2 and 15): the recording goes the same way, the typed
    /// capture ends at its start, and ingest takes both in the order they began.
    @Test(arguments: [false, true])
    func handoffFromACaptureOnTheInboxPathStaysInOneNote(engineIngests: Bool) async throws {
        let r = Rig(engineIngests: engineIngests)
        await r.notes.setWindow(.off)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "draft"))
        r.clock.advance(by: 1)
        let b = try await r.beginRecording()
        #expect(b.path == .inbox(KnotError.storeBusy.code), "The later capture goes the same way.")
        _ = try await r.engine.end(b.captureID)
        _ = await r.ingest.ingestAll()
        #expect(
            await eventually("both to be stored") {
                let first = try? await r.notes.capture(a.captureID)
                let second = try? await r.notes.capture(b.captureID)
                return first?.outcome == .stored && second?.outcome == .stored
            })
        let first = try #require(try await r.notes.segment(SegmentID(a.captureID)))
        let second = try #require(try await r.notes.segment(SegmentID(b.captureID)))
        #expect(first.noteID == second.noteID)
        let endedAt = try await r.notes.capture(a.captureID)?.endedAt
        let startedAt = try await r.notes.capture(b.captureID)?.startedAt
        #expect(endedAt == startedAt)
    }

    /// Finding 6. A discard the store refused does not say the store took it, and the engine
    /// ends the row as empty when the store next answers, so no capture stays active.
    @Test func discardTheStoreRefusedEndsTheRowLater() async throws {
        let r = Rig()
        let a = try await r.beginRecording()
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let discarded = try await r.engine.discard(a.captureID)
        #expect(discarded.outcome == .discardedEmpty)
        #expect(discarded.path == .inbox(KnotError.storeBusy.code))
        _ = await r.ingest.ingestAll()
        _ = try await r.engine.discard(a.captureID)
        #expect(
            await eventually("the row to be ended") {
                (try? await r.notes.capture(a.captureID))?.outcome == .discardedEmpty
            })
        #expect(try await r.notes.openCaptures().isEmpty)
    }

    /// Finding 6, with finding 34. The discard the store refused is ended after the call, not
    /// ahead of the next start's own write, and its row does not stay open.
    @Test func refusedDiscardIsEndedAfterTheCall() async throws {
        let r = Rig()
        let a = try await r.beginRecording()
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        _ = try await r.engine.discard(a.captureID)
        let typed = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "t"))
        #expect(typed.durableRevision == 1)
        #expect(
            await eventually("the discarded recording's row to be ended") {
                (try? await r.notes.capture(a.captureID))?.outcome == .discardedEmpty
            })
    }

    /// Finding 6. After a relaunch, recovery ends the row of a refused discard as empty: its
    /// audio is gone, so nothing is kept.
    @Test func recoveryEndsTheRowOfARefusedDiscard() async throws {
        let r = Rig()
        let a = try await r.beginRecording()
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        _ = try await r.engine.discard(a.captureID)
        let next = r.relaunch()
        _ = try await next.recovery.run(ingest: next.ingest)
        #expect(try await next.notes.capture(a.captureID)?.outcome == .discardedEmpty)
        #expect(try await next.stream().notes.isEmpty)
    }

    /// Finding 8. A recording whose microphone is refused never starts, so the open draft is
    /// not ended: rule 15 ends the open capture only once the new one has started.
    @Test(arguments: [false, true])
    func refusedMicrophoneLeavesTheDraftOpen(draftOffTheStorePath: Bool) async throws {
        let r = Rig(engineIngests: false)
        if draftOffTheStorePath { await r.notes.failNextCaptureWrites(with: .storeBusy) }
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "before"))
        r.recorder.failNextStarts(with: .microphonePermissionRefused)
        await expectError(.microphonePermissionRefused) {
            try await r.engine.begin(CaptureRequest(kind: .voice, surface: .macPanel))
        }
        if !draftOffTheStorePath { #expect(try await r.notes.capture(a.captureID)?.outcome == .open) }
        let typed = try await r.engine.update(a.captureID, with: .text("before and after"))
        #expect(typed.outcome == .open)
        #expect(typed.durableRevision == 2)
    }

    /// Finding 9. A conversion that failed is tried again: by `retryConversions()`, which the
    /// composition calls when the app comes forward, and after the engine's next call once 30
    /// seconds have passed (finding 34: after the call, never ahead of its own write). The
    /// capture is then stored and goes on to transcription.
    @Test(arguments: [false, true])
    func failedConversionIsTriedAgain(byTheNextCall: Bool) async throws {
        let r = Rig()
        let a = try await r.beginRecording()
        r.recorder.failNextConversions(with: .conversionFailed)
        let ended = try await r.engine.end(a.captureID)
        #expect(ended.outcome == .failed(KnotError.conversionFailed.code))
        if byTheNextCall {
            _ = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "soon"))
            #expect(try await r.notes.capture(a.captureID)?.outcome == .failed(KnotError.conversionFailed.code))
            r.clock.advance(by: 30)
            _ = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "later"))
        } else {
            await r.engine.retryConversions()
        }
        #expect(
            await eventually("the recording to be stored and its working file gone") {
                let row = try? await r.notes.capture(a.captureID)
                return row?.outcome == .stored
                    && r.layer.entryKind(r.locations.recordingAudio(a.captureID, format: .caf)) == nil
            })
        #expect(try await r.notes.jobs(for: SegmentID(a.captureID)).map(\.kind) == [.transcribe])
    }

    /// Finding 15. A capture on the `Inbox/` path names no note: the file path has not
    /// confirmed where it lands, even when the store placed its start.
    @Test func captureOffTheStorePathNamesNoNote() async throws {
        let r = Rig(engineIngests: false)
        let begun = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "n"))
        #expect(begun.noteID != nil)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let fell = try await r.engine.update(begun.captureID, with: .text("no"))
        #expect(fell.path == .inbox(KnotError.storeBusy.code))
        #expect(fell.noteID == nil)
        #expect(try await r.engine.end(begun.captureID).noteID == nil)
    }

    /// Finding 16. The store has 100 ms to answer before a capture takes `Inbox/`
    /// (docs/architecture.md §6, rule 6), and the standard deadline waits that long.
    @Test func standardDeadlineIsAHundredMilliseconds() async {
        #expect(StoreDeadline.standardLimit == .milliseconds(100))
        let clock = ContinuousClock()
        let started = clock.now
        await StoreDeadline.standard.wait()
        #expect(clock.now - started >= .milliseconds(100))
    }

    /// The second opinion's `repeatedEndAndLateUpdate`, which held: a repeated end returns the
    /// same state, and an update after the end is refused and changes nothing.
    @Test func repeatedEndAndLateUpdate() async throws {
        let r = Rig()
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "first"))
        let ended = try await r.engine.end(a.captureID)
        #expect(try await r.engine.end(a.captureID) == ended)
        await expectError(.illegalTransition) { try await r.engine.update(a.captureID, with: .text("later")) }
        #expect(try await r.notes.segment(SegmentID(a.captureID))?.text == "first")
    }

    /// Finding 17, the second review's R1: rule 15 off the store path keeps one note, with
    /// the engine's own ingest on and off. A typed capture the store refused, then a recording
    /// with appending off: the recording goes the same way (finding 4), and is the next
    /// segment of the typed capture's note.
    @Test(arguments: [false, true])
    func ruleFifteenOffTheStorePathKeepsOneNote(engineIngests: Bool) async throws {
        let rig = Rig(engineIngests: engineIngests)
        await rig.notes.setWindow(.off)
        await rig.notes.failNextCaptureWrites(with: .storeBusy)
        let typed = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "p"))
        #expect(typed.path == .inbox(KnotError.storeBusy.code))
        _ = try await rig.engine.update(typed.captureID, with: .text("pay the plumber"))
        rig.clock.advance(by: 3)
        let recording = try await rig.beginRecording()
        #expect(recording.path == .inbox(KnotError.storeBusy.code))
        _ = try await rig.engine.end(recording.captureID)
        _ = await rig.ingest.ingestAll()
        #expect(
            await eventually("both captures to be stored") {
                let first = try? await rig.notes.capture(typed.captureID)
                let second = try? await rig.notes.capture(recording.captureID)
                return first?.outcome == .stored && second?.outcome == .stored
            })
        #expect(try await rig.stream().notes.count == 1)
    }

    /// Finding 30. A recording discarded before the store answered its record: the row the
    /// late answer makes is ended as empty, so no capture stays active.
    @Test func lateRowOfADiscardedRecordingIsEndedAsEmpty() async throws {
        let r = Rig(deadline: .immediate)
        let hold = await r.notes.holdNextCaptureWrite()
        let begun = try await r.beginRecording()
        #expect(begun.path == .inbox(KnotError.storeNotOpen.code))
        _ = await SuiteWait.value("the record call to reach the hold") { await reached(hold) }
        #expect(try await r.engine.discard(begun.captureID).outcome == .discardedEmpty)
        #expect(try await r.notes.capture(begun.captureID) == nil)
        hold.release()
        #expect(
            await eventually("the late row to be ended as empty") {
                (try? await r.notes.capture(begun.captureID))?.outcome == .discardedEmpty
            })
        #expect(try await r.notes.openCaptures().isEmpty)
        #expect(try await r.stream().notes.isEmpty)
    }

    /// Finding 34. A start does no old work ahead of its own write: while the conversion of an
    /// old recording whose conversion failed is held, a new recording still starts and its
    /// begin returns; the old one is stored once the conversion goes on.
    @Test func startWaitsForNoOldConversion() async throws {
        let r = Rig()
        let recorder = WatchedRecorder(r.recorder)
        let engine = r.engine(recorder: recorder)
        let first = try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
        r.recorder.failNextConversions(with: .conversionFailed)
        #expect(try await engine.end(first.captureID).outcome == .failed(KnotError.conversionFailed.code))
        recorder.conversionGate.close()
        r.clock.advance(by: 31)
        let second = try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
        #expect(second.outcome == .open)
        #expect(recorder.calls.contains("start"))
        #expect(try await r.notes.capture(first.captureID)?.outcome == .failed(KnotError.conversionFailed.code))
        recorder.conversionGate.open()
        #expect(
            await eventually("the old recording to be stored") {
                (try? await r.notes.capture(first.captureID))?.outcome == .stored
            })
        _ = try await engine.discard(second.captureID)
    }

    /// Finding 34, and finding 42. A start does no old work ahead of its own write: while an old
    /// discard's end and its retry after the call both wait in the store, a start writes its
    /// own row before the store is asked to end the old row again, and the old row is ended
    /// once the store answers.
    @Test func startWaitsForNoOldDiscard() async throws {
        let impatient = Mutex(false)
        let r = Rig()
        let hooks = JobHooks()
        let engine = r.engine(
            notes: HookedStore(store: r.notes, hooks: hooks),
            deadline: StoreDeadline {
                if impatient.withLock({ $0 }) { return }
                try? await Task.sleep(for: SuiteWait.limit)
            })
        let recording = try await r.beginRecording(on: engine)
        #expect(recording.path == .store)
        impatient.withLock { $0 = true }
        let ownEnd = await r.notes.holdNextCaptureWrite()
        let retry = await r.notes.holdNextCaptureWrite()
        _ = try await engine.discard(recording.captureID)
        // The discard's end did not answer in time; its retry, after the call, waits too.
        await reached(retry)
        let typed = try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "t"))
        #expect(typed.durableRevision == 1)
        let writes = hooks.captureWrites.withLock { $0 }
        let ownWrite = try #require(writes.firstIndex(of: "record \(typed.captureID)"))
        #expect(
            writes[..<ownWrite].filter { $0 == "end \(recording.captureID)" }.count == 2,
            "The start asked the store to end the old row again before its own write: \(writes)")
        ownEnd.release()
        retry.release()
        #expect(
            await eventually("the discarded recording's row to be ended") {
                (try? await r.notes.capture(recording.captureID))?.outcome == .discardedEmpty
            })
    }

    /// Finding 44. `retryConversions()`, which the composition calls when the app comes forward,
    /// ends the rows of discards the store refused: here the discard's end and the retry after
    /// the call are both refused, and the hook ends the row at once.
    @Test func comingForwardEndsARefusedDiscard() async throws {
        let r = Rig()
        let recording = try await r.beginRecording()
        #expect(recording.path == .store)
        await r.notes.failNextCaptureWrites(with: .storeBusy, .storeBusy)
        let discarded = try await r.engine.discard(recording.captureID)
        #expect(discarded.path == .inbox(KnotError.storeBusy.code))
        #expect(
            await eventually("the retry after the call to be refused") {
                r.logs.logged("discard_end_not_taken", recording.captureID)
            })
        #expect(try await r.notes.capture(recording.captureID)?.outcome == .open)
        await r.engine.retryConversions()
        #expect(try await r.notes.capture(recording.captureID)?.outcome == .discardedEmpty)
    }

    /// Finding 45. An update answers a capture as saved, as a begin does: after a begin that
    /// reached no disk and an update saved by the capture's ID, a typed start on the same surface
    /// is a capture of its own, and the updated text stays.
    @Test func updateAnswersTheCaptureAsSaved() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        r.layer.failNextWrite(with: .diskFull)
        let failed = await expectError(.diskFull) {
            try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "first"))
        }
        let a = try #require(failed?.context.captureID)
        let updated = try await r.engine.update(a, with: .text("first, updated"))
        #expect(updated.durableRevision > 0)
        let b = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "second"))
        #expect(b.captureID != a, "The start took the updated capture as its retry.")
        #expect(r.inboxText(a) == "first, updated")
    }

    /// Finding 35, the re-check's N5. A typed start on another surface that reached no disk
    /// leaves the open capture going on (finding 8); once its retry reaches disk, rule 15 ends
    /// the open capture as a first start does, so one capture is open.
    @Test func retryOfAStartEndsTheOpenCaptureOnceItHasStarted() async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "first"))
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        r.layer.failNextWrite(with: .diskFull)
        let request = CaptureRequest(kind: .typed, surface: .app, text: "second")
        await expectError(.diskFull) { try await r.engine.begin(request) }
        #expect(try await r.notes.capture(a.captureID)?.outcome == .open)
        let retry = try await r.engine.begin(request)
        #expect(retry.durableRevision > 0)
        #expect(try await r.notes.capture(a.captureID)?.outcome == .stored)
        await expectError(.illegalTransition) { try await r.engine.update(a.captureID, with: .text("more")) }
    }

    /// Finding 38, the re-check's N7. Two Shortcuts in a row through the intent surface, the
    /// first still open: the second is a capture of its own, and the first keeps the text that
    /// was acknowledged.
    @Test func sameSurfaceStartKeepsTheAcknowledgedText() async throws {
        let r = Rig()
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "buy milk"))
        #expect(a.durableRevision == 1)
        let b = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "call mom"))
        #expect(b.captureID != a.captureID)
        _ = try await r.engine.end(a.captureID)
        _ = try await r.engine.end(b.captureID)
        #expect(
            await eventually("both texts to be stored") {
                let texts = (try? await r.stream())?.notes.flatMap(\.liveSegments).map(\.text) ?? []
                return Set(texts) == ["buy milk", "call mom"]
            })
    }

    // MARK: Finding 39: wrong engines the tests let through

    /// Finding 39, n02. A start that waited for an open capture, which then ended, finds an
    /// older start of its own kind on its surface that reached no disk: it becomes that one's
    /// retry, and leaves no entry of its own open behind.
    @Test func startThatBecomesARetryLeavesNoEntryOpen() async throws {
        let r = Rig()
        let x = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "x"))
        // P starts before X by the clock, and reaches no disk: X goes on (finding 8).
        r.clock.advance(by: -10)
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        r.layer.failNextWrite(with: .diskFull)
        let failed = await expectError(.diskFull) {
            try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "p"))
        }
        let p = try #require(failed?.context.captureID)
        r.clock.advance(by: 20)
        // X's end waits in the store; a typed start on P's surface waits for X's line.
        let hold = await r.notes.holdNextCaptureWrite()
        let engine = r.engine
        let ending = Task { try? await engine.end(x.captureID) }
        await reached(hold)
        let starting = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "c")) }
        #expect(await eventually("the start to wait for X") { r.logs.logged("start_waits_for_open_capture") })
        hold.release()
        _ = await SuiteWait.value("X's end") { await ending.value }
        let started = await SuiteWait.value("the start") { try? await starting.value }
        let c = try #require(started ?? nil)
        #expect(c.captureID == p, "The start became P's retry.")
        // No entry of the start's own is left open: once P ends, a start on that surface is a
        // capture of its own, at its first revision, and not the retry of a leftover entry.
        _ = try await engine.end(p)
        let again = try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "again"))
        #expect(again.captureID != p)
        #expect(again.durableRevision == 1)
    }

    /// Finding 41, the re-check's C1. Two starts on one surface overlap: the second comes
    /// while the first one's begin is still in the store, and waits for its line as its retry.
    /// The first is answered as saved meanwhile, so the second is a capture of its own, and the
    /// acknowledged text stays.
    @Test func overlappingSameSurfaceStartsKeepTheAcknowledgedText() async throws {
        let r = Rig()
        let engine = r.engine
        let hold = await r.notes.holdNextCaptureWrite()
        let first = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "buy milk")) }
        await reached(hold)
        let second = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "call mom")) }
        #expect(
            await eventually("the second start to wait for the first one's line") {
                r.logs.logged("start_waits_to_retry")
            })
        hold.release()
        let a = try #require(await SuiteWait.value("the first start") { try? await first.value } ?? nil)
        #expect(a.durableRevision == 1, "The first start was answered as saved.")
        let b = try #require(await SuiteWait.value("the second start") { try? await second.value } ?? nil)
        try #require(b.captureID != a.captureID, "The second start is a capture of its own.")
        _ = try await engine.end(a.captureID)
        _ = try await engine.end(b.captureID)
        #expect(
            await eventually("both texts to be stored") {
                let first = try? await r.notes.segment(SegmentID(a.captureID))
                let second = try? await r.notes.segment(SegmentID(b.captureID))
                return first?.text == "buy milk" && second?.text == "call mom"
            })
        #expect(try await r.notes.openCaptures().isEmpty)
    }

    /// Finding 39, n05 and n06. A typed start that reaches no disk ends nothing: the open
    /// capture, on the store path or on the `Inbox/` path, goes on and takes saves.
    @Test(arguments: [false, true])
    func startThatReachesNoDiskEndsNothing(openOffTheStorePath: Bool) async throws {
        let r = Rig(engineIngests: false)
        if openOffTheStorePath { await r.notes.failNextCaptureWrites(with: .storeBusy) }
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "a"))
        #expect((a.path == .store) != openOffTheStorePath)
        if !openOffTheStorePath { await r.notes.failNextCaptureWrites(with: .storeBusy) }
        r.layer.failNextWrite(with: .diskFull)
        await expectError(.diskFull) {
            try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "b"))
        }
        let goesOn = try await r.engine.update(a.captureID, with: .text("a, then more"))
        #expect(goesOn.outcome == .open)
        if !openOffTheStorePath { #expect(try await r.notes.capture(a.captureID)?.outcome == .open) }
    }

    /// Finding 39, n07. A conversion tried again and stored is no longer pending: a later retry
    /// converts nothing.
    @Test func storedConversionIsNoLongerPending() async throws {
        let r = Rig()
        let recorder = WatchedRecorder(r.recorder)
        let engine = r.engine(recorder: recorder)
        let first = try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
        r.recorder.failNextConversions(with: .conversionFailed)
        _ = try await engine.end(first.captureID)
        await engine.retryConversions()
        #expect(try await r.notes.capture(first.captureID)?.outcome == .stored)
        #expect(recorder.conversions == 2)
        await engine.retryConversions()
        #expect(recorder.conversions == 2)
    }

    /// Finding 39, n08. Two retries at once: the second waits for the recording's line, looks
    /// again, finds it no longer pending, and converts nothing.
    @Test func secondRetryLooksAgainAfterWaiting() async throws {
        let r = Rig()
        let recorder = WatchedRecorder(r.recorder)
        let engine = r.engine(recorder: recorder)
        let first = try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
        r.recorder.failNextConversions(with: .conversionFailed)
        _ = try await engine.end(first.captureID)
        recorder.conversionDelay.withLock { $0 = .milliseconds(200) }
        let one = Task { await engine.retryConversions() }
        #expect(await eventually("the first retry to convert") { recorder.conversions == 2 })
        let two = Task { await engine.retryConversions() }
        _ = await SuiteWait.value("the retries") {
            await one.value
            await two.value
        }
        #expect(recorder.conversions == 2)
        #expect(try await r.notes.capture(first.captureID)?.outcome == .stored)
    }
}
