import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
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
        await pending.untilReached()
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
        await pending.untilReached()
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
}
