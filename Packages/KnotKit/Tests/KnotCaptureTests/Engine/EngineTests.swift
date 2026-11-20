import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@Suite struct EngineTests {
    /// On the store path a typed capture's row is its first durable write: nothing waits in
    /// `Inbox/`, and every later save is a checkpoint by revision.
    @Test func typedCaptureWritesItsRowFirst() async throws {
        let rig = Rig()
        let begun = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "c"))
        let row = try #require(try await rig.notes.capture(begun.captureID))
        #expect(row.outcome == .open)
        #expect(row.launchID == rig.launchID)
        #expect(row.revision == 1)
        #expect(row.origin == CaptureOrigin(source: .device(rig.deviceID), surface: .macPanel))
        #expect(rig.inboxFiles().isEmpty)
        #expect(begun.path == .store)
        #expect(begun.noteID != nil)

        let updated = try await rig.engine.update(begun.captureID, with: .text("call the bank"))
        #expect(updated.durableRevision == 2)
        #expect(try await rig.notes.capture(begun.captureID)?.revision == 2)
        #expect(try await rig.notes.segment(SegmentID(begun.captureID))?.text == "call the bank")

        let ended = try await rig.engine.end(begun.captureID)
        #expect(ended.outcome == .stored)
        #expect(try await rig.notes.capture(begun.captureID)?.outcome == .stored)
        // Ending again changes nothing and says how it ended.
        #expect(try await rig.engine.end(begun.captureID) == ended)
        await expectError(.illegalTransition) {
            try await rig.engine.update(begun.captureID, with: .text("more"))
        }
    }

    /// A recording writes its manifest first, through the recorder, and its row when the store
    /// answers: a store held at the start still finds the recording on the drive.
    @Test func recordingWritesItsManifestFirst() async throws {
        let rig = Rig(deadline: .immediate, engineIngests: false)
        let hold = await rig.notes.holdNextCaptureWrite()
        let begun = try await rig.engine.begin(CaptureRequest(kind: .voice, surface: .app))
        await reached(hold)
        #expect(rig.layer.entryKind(rig.locations.recordingManifest(begun.captureID)) == .file)
        #expect(try await rig.notes.capture(begun.captureID) == nil)
        #expect(begun.path == .inbox(KnotError.storeNotOpen.code))
        hold.release()
        #expect(await eventually("the late row") { (try? await rig.notes.capture(begun.captureID)) != nil })
    }

    /// An empty typed capture leaves nothing in the stream, and a discarded recording keeps
    /// nothing either.
    @Test func emptyAndDiscardedCapturesKeepNothing() async throws {
        let rig = Rig()
        let typed = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "x"))
        _ = try await rig.engine.update(typed.captureID, with: .text("  \n"))
        #expect(try await rig.engine.end(typed.captureID).outcome == .discardedEmpty)

        let discarded = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "y"))
        #expect(try await rig.engine.discard(discarded.captureID).outcome == .discardedEmpty)

        let recording = try await rig.beginRecording()
        #expect(try await rig.engine.discard(recording.captureID).outcome == .discardedEmpty)
        #expect(rig.layer.entryKind(rig.locations.recordingAudio(recording.captureID, format: .caf)) == nil)

        #expect(try await rig.stream().notes.isEmpty)
        #expect(try await rig.notes.openCaptures().isEmpty)
    }

    // MARK: Rule 15

    /// A capture begun twice (finding 38): a second typed start on the surface of an open typed
    /// capture that has reached disk is a capture of its own. The store's rule 15 refuses it, so
    /// it goes to `Inbox/`, and the open capture keeps its text: a start never replaces text that
    /// was acknowledged.
    @Test func secondTypedStartOnTheSameSurfaceIsACaptureOfItsOwn() async throws {
        let rig = Rig()
        let first = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "a"))
        let again = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "ab"))
        #expect(again.captureID != first.captureID)
        #expect(again.path == .inbox(KnotError.segmentCaptureOpen.code))
        #expect(try await rig.notes.segment(SegmentID(first.captureID))?.text == "a")
        #expect(rig.inboxText(again.captureID) == "ab")
    }

    /// While a recording runs, typing does not start, and a second press of record does not
    /// start another recording.
    @Test func recordingBlocksOtherStarts() async throws {
        let rig = Rig()
        let recording = try await rig.beginRecording()
        await expectError(.captureBlockedByRecording) {
            try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "t"))
        }
        await expectError(.segmentCaptureOpen) {
            try await rig.engine.begin(CaptureRequest(kind: .voice, surface: .app))
        }
        #expect(try await rig.notes.openCaptures().map(\.id) == [recording.captureID])
    }

    /// A recording started while a typed capture is open ends the typed capture as it stands,
    /// and becomes the next segment of its note, even with appending off.
    @Test func recordingStartEndsTheOpenTypedCapture() async throws {
        let rig = Rig()
        await rig.notes.setWindow(.off)
        let typed = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "l"))
        _ = try await rig.engine.update(typed.captureID, with: .text("look up the train times"))
        let recording = try await rig.beginRecording()
        #expect(recording.path == .store)
        #expect(recording.noteID == typed.noteID)
        let row = try #require(try await rig.notes.capture(typed.captureID))
        #expect(row.outcome == .stored)
        #expect(try await rig.notes.segment(SegmentID(typed.captureID))?.text == "look up the train times")
        // The engine knows the typed capture ended.
        #expect(try await rig.engine.end(typed.captureID).outcome == .stored)
        _ = try await rig.engine.end(recording.captureID)
        #expect(try await rig.stream().notes.count == 1)
    }

    /// A typed capture on the `Inbox/` path is ended by the engine itself when a recording
    /// starts, and the recording goes the same way, into its note; nothing of it is lost.
    @Test func recordingStartEndsAnOpenCaptureOffTheStorePath() async throws {
        let rig = Rig()
        await rig.notes.failNextCaptureWrites(with: .storeBusy)
        let typed = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "p"))
        _ = try await rig.engine.update(typed.captureID, with: .text("pay the plumber"))
        let recording = try await rig.beginRecording()
        #expect(recording.path == .inbox(KnotError.storeBusy.code))
        _ = try await rig.engine.end(recording.captureID)
        #expect(
            await eventually("the recording's item to be ingested") {
                (try? await rig.notes.capture(recording.captureID))?.outcome == .stored
            })
        let notes = try await rig.stream().notes
        #expect(notes.count == 1)
        #expect(
            await eventually("the typed capture's item to be ingested") {
                (try? await rig.notes.capture(typed.captureID))?.outcome == .stored
            })
        #expect(try await rig.notes.segment(SegmentID(typed.captureID))?.text == "pay the plumber")
        #expect(rig.inboxFiles().isEmpty)
    }

    /// Two starts on two other surfaces at the same moment, while a capture is open: rule 15
    /// leaves one capture open, and every other one stored with its text.
    @Test func simultaneousStartsLeaveOneCaptureOpen() async throws {
        let rig = Rig()
        let first = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "first"))
        let engine = rig.engine
        let started = await withTaskGroup(of: CaptureState?.self) { group in
            for (surface, text) in [(CaptureSurface.macPanel, "panel"), (.macWindow, "window")] {
                group.addTask {
                    try? await engine.begin(CaptureRequest(kind: .typed, surface: surface, text: text))
                }
            }
            return await group.reduce(into: [CaptureState]()) { if let state = $1 { $0.append(state) } }
        }
        #expect(started.count == 2)
        let open = try await rig.notes.openCaptures()
        #expect(open.count == 1)
        for id in [first.captureID] + started.map(\.captureID) where !open.map(\.id).contains(id) {
            #expect(try await rig.notes.capture(id)?.outcome == .stored)
        }
        #expect(try await rig.stream().notes.count == 1)
    }

    // MARK: Neither path

    /// When neither the store nor `Inbox/` takes a begin, it throws and nothing is durable: the
    /// surface keeps the text and says that it could not save (docs/product-spec.md §4.4). Its
    /// next begin on the same surface is the same capture, and saves the whole text.
    @Test func beginThatReachesNoDiskThrows() async throws {
        let rig = Rig()
        await rig.notes.failNextCaptureWrites(with: .storeBusy)
        rig.layer.failNextWrite(with: .diskFull)
        let failed = await expectError(.diskFull) {
            try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "f"))
        }
        #expect(try await rig.notes.openCaptures().isEmpty)
        #expect(rig.inboxFiles().isEmpty)
        let retried = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "fix the gate"))
        #expect(retried.captureID == failed?.context.captureID)
        #expect(retried.path == .inbox(KnotError.storeBusy.code))
        #expect(rig.inboxText(retried.captureID) == "fix the gate")
    }

    /// A save that neither path takes is not acknowledged: the update throws, the durable
    /// revision stays, and the next save carries the whole text.
    @Test func updateThatReachesNoDiskIsNotAcknowledged() async throws {
        let rig = Rig(engineIngests: false)
        await rig.notes.failNextCaptureWrites(with: .storeBusy)
        let begun = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "s"))
        rig.layer.failNextWrite(with: .diskFull)
        await expectError(.diskFull) {
            try await rig.engine.update(begun.captureID, with: .text("send"))
        }
        #expect(rig.inboxText(begun.captureID) == "s")
        let saved = try await rig.engine.update(begun.captureID, with: .text("send the form"))
        #expect(saved.durableRevision == 3)
        _ = try await rig.engine.end(begun.captureID)
        _ = await rig.ingest.ingestAll()
        #expect(try await rig.notes.segment(SegmentID(begun.captureID))?.text == "send the form")
        #expect(try await rig.notes.capture(begun.captureID)?.revision == 3)
    }

    /// An end that neither path takes leaves the capture open, so that the surface can end it
    /// again.
    @Test func endThatReachesNoDiskLeavesTheCaptureOpen() async throws {
        let rig = Rig(engineIngests: false)
        await rig.notes.failNextCaptureWrites(with: .storeBusy)
        let begun = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "r"))
        rig.layer.failNextWrite(with: .diskFull)
        await expectError(.diskFull) { try await rig.engine.end(begun.captureID) }
        let ended = try await rig.engine.end(begun.captureID)
        #expect(ended.outcome == .stored)
        _ = await rig.ingest.ingestAll()
        #expect(try await rig.notes.capture(begun.captureID)?.outcome == .stored)
    }

    /// A recording that ends by itself, at its limit, ends its capture as a stop would.
    @Test func recordingThatEndsByItselfIsStored() async throws {
        let rig = Rig()
        rig.recorder.setScript(ScriptedRecorder.Script(buffers: 3, endsBySelf: .limitReached))
        let begun = try await rig.engine.begin(CaptureRequest(kind: .voice, surface: .app))
        #expect(
            await eventually("the recording to be stored") {
                (try? await rig.notes.capture(begun.captureID))?.outcome == .stored
            })
        #expect(try await rig.notes.jobs(for: SegmentID(begun.captureID)).map(\.kind) == [.transcribe])
    }

    /// A recording that cannot start says why, and nothing is written for it.
    @Test func recordingThatCannotStartThrows() async throws {
        let rig = Rig()
        rig.recorder.failNextStarts(with: .microphonePermissionRefused)
        await expectError(.microphonePermissionRefused) {
            try await rig.engine.begin(CaptureRequest(kind: .voice, surface: .app))
        }
        #expect(try await rig.notes.openCaptures().isEmpty)
        // Typing still starts: the failed recording holds nothing open.
        _ = try await rig.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "ok"))
    }

    /// A recording whose conversion fails is kept as failed, with its working file, and is not
    /// lost.
    @Test func recordingWhoseConversionFailsIsKept() async throws {
        let rig = Rig()
        rig.recorder.failNextConversions(with: .conversionFailed)
        let begun = try await rig.beginRecording()
        let ended = try await rig.engine.end(begun.captureID)
        #expect(ended.outcome == .failed(KnotError.conversionFailed.code))
        #expect(try await rig.notes.capture(begun.captureID)?.outcome == .failed(KnotError.conversionFailed.code))
        #expect(rig.layer.entryKind(rig.locations.recordingAudio(begun.captureID, format: .caf)) == .file)
    }
}
