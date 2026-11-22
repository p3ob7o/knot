import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// A stored recording keeps its level peaks (`NoteStore.setPeaks(_:of:)`, pull request 86).
/// Whoever stores the recording, the engine, ingest or recovery, keeps the peaks the recorder
/// left beside it, held to the audio's frames, once the row points to the stored file and before
/// the working file goes. A refusal never fails, ends or holds the capture.
///
/// The scripted recorder writes no peaks file, so each test writes one where the recorder would,
/// with more values than the audio covers, as peaks that ran a sync ahead of it.
@Suite struct PeaksTests {
    /// Peaks of 800 frames a value, 20 values: twice what the scripted recorder's longest
    /// recording covers, five buffers of 1,600 frames.
    static let written = RecordingPeaks(framesPerValue: 800, values: (0..<20).map { UInt8($0 * 10) })

    /// What a store keeps of `written` for a capture: held to the frames its stored row says its
    /// audio has. The scripted recorder writes its buffers on a timer, so a recording ended at
    /// once may hold fewer than five, and the test reads how many it holds.
    private static func kept(_ r: Rig, _ capture: CaptureID) async throws -> Data? {
        guard let frames = try await r.notes.capture(capture)?.revision else { return nil }
        return RecordingPeaks(framesPerValue: written.framesPerValue, values: written.held(toFrames: frames)).encoded()
    }

    /// The peaks the store keeps with a capture's segment, read on the in-memory store itself, so
    /// that the suite fails if its two peaks operations ever stop being its own: a synchronous
    /// member beside the port's `async` default resolves to the default on a concrete call.
    private static func peaks(_ r: Rig, _ capture: CaptureID) async throws -> Data? {
        try await r.notes.peaks(of: SegmentID(capture))
    }

    private static func writePeaks(_ r: Rig, _ capture: CaptureID) throws {
        try r.layer.write(written.encoded(), to: r.locations.recordingPeaks(capture))
        try r.layer.syncFile(r.locations.recordingPeaks(capture))
    }

    @Test func aStoredEndOnTheStorePathKeepsThePeaksHeldToTheAudio() async throws {
        let r = Rig()
        let recording = try await r.beginRecording()
        try Self.writePeaks(r, recording.captureID)
        r.clock.advance(by: 2)
        let ended = try await r.engine.end(recording.captureID)
        #expect(ended.path == .store)
        #expect(ended.outcome == .stored)
        let peaks = try #require(try await Self.peaks(r, recording.captureID))
        #expect(peaks == (try await Self.kept(r, recording.captureID)))
        #expect((RecordingPeaks(reading: peaks)?.values.count ?? 20) < 20, "Held to the frames the audio has.")
        #expect(!r.layer.exists(r.locations.recordingPeaks(recording.captureID)), "The peaks file went.")
        #expect(r.logs.logged("recording_peaks_kept", recording.captureID))
    }

    /// On the `Inbox/` path the item carries the peaks, and ingest keeps them.
    @Test func onTheInboxPathThePeaksGoThroughTheItem() async throws {
        let r = Rig()
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let recording = try await r.beginRecording()
        #expect(recording.path == .inbox(KnotError.storeBusy.code))
        try Self.writePeaks(r, recording.captureID)
        r.clock.advance(by: 2)
        _ = try await r.engine.end(recording.captureID)
        #expect(
            await eventually("ingest to store the recording") {
                (try? await r.notes.capture(recording.captureID))?.outcome == .stored
            })
        #expect(
            await eventually("the peaks to be kept") {
                guard let kept = try? await Self.kept(r, recording.captureID) else { return false }
                return (try? await Self.peaks(r, recording.captureID)) == .some(kept)
            })
    }

    /// A store that refuses the peaks: the recording is stored all the same, its working file
    /// goes, and the refusal is logged by its code.
    @Test func aRefusalOfThePeaksNeverHoldsTheRecording() async throws {
        let r = Rig()
        var store = ChaosStore(store: r.notes) {}
        store.refusePeaks = { _ throws(KnotError) in throw KnotError.storeBusy }
        let engine = BoundedEngine(
            StandardCaptureEngine(
                notes: store, assets: r.assets, recorder: r.recorder, queue: r.queue, clock: r.clock, ids: r.ids,
                deviceID: r.deviceID, launchID: r.launchID, locations: r.locations, layer: r.layer, deadline: .patient,
                ingest: r.ingest, log: KnotLog(.capture, sink: r.logs)))
        let recording = try await r.beginRecording(on: engine)
        try Self.writePeaks(r, recording.captureID)
        r.clock.advance(by: 2)
        let ended = try await engine.end(recording.captureID)
        #expect(ended.outcome == .stored)
        #expect(try await Self.peaks(r, recording.captureID) == nil)
        #expect(r.logs.lines.contains("recording_peaks_not_kept capture=\(recording.captureID) code=store_busy"))
        #expect(!r.layer.exists(r.locations.recordingAudio(recording.captureID, format: .caf)), "The file went.")
    }

    /// The review of pull request 91, N1. A store that holds `setPeaks` and nothing else: the
    /// engine's call of it races the engine's deadline, as its every other store call does, and a
    /// miss is what a refusal is. So `end`, and a press that stops, return with the row stored, the
    /// working file gone and, for the press, one `saved` cue. The held call lands once the store
    /// lets it go, and the peaks are with the segment then. The test runs the deadline out by hand.
    @Test(arguments: [false, true])
    func aHeldSetOfThePeaksNeverHoldsTheEnd(byPress: Bool) async throws {
        let r = Rig()
        let gate = Gate()
        gate.close()
        var store = ChaosStore(store: r.notes) {}
        store.holdPeaks = { await gate.pass() }
        let manual = ManualDeadline()
        let cues = RecordingCueEmitter()
        let engine = BoundedEngine(
            StandardCaptureEngine(
                notes: store, assets: r.assets, recorder: r.recorder, queue: r.queue, clock: r.clock, ids: r.ids,
                deviceID: r.deviceID, launchID: r.launchID, locations: r.locations, layer: r.layer,
                deadline: manual.deadline, ingest: r.ingest, recordingState: InMemoryRecordingStateStore(), cues: cues,
                log: KnotLog(.capture, sink: r.logs)))
        let id: CaptureID
        if byPress {
            let states = engine.states()
            let started = try #require(try await engine.press(r.press(.tap)).started)
            id = started.captureID
            _ = await SuiteWait.value("the recording's frames to be durable") {
                for await state in states where state.captureID == id && state.durableRevision > 0 { return true }
                return false
            }
        } else {
            id = try await r.beginRecording(on: engine).captureID
        }
        try Self.writePeaks(r, id)
        r.clock.advance(by: 2)
        let clock = r.clock
        let ending = Task { () throws -> CaptureState? in
            if byPress { return try await engine.press(Press(.tap, at: clock.now())).stopped }
            return try await engine.end(id)
        }
        #expect(await eventually("setPeaks to be held") { gate.isHolding })
        await manual.expireNext()
        let ended = try #require(try await ending.value)
        #expect(ended.outcome == .stored)
        #expect(try await r.notes.capture(id)?.outcome == .stored)
        #expect(!r.layer.exists(r.locations.recordingAudio(id, format: .caf)), "The working file went.")
        #expect(cues.cues == (byPress ? [.saved] : []))
        #expect(r.logs.lines.contains("recording_peaks_not_kept capture=\(id) code=store_not_open"))
        gate.open()
        #expect(
            await eventually("the held call to land") {
                guard let kept = try? await Self.kept(r, id) else { return false }
                return (try? await Self.peaks(r, id)) == .some(kept)
            })
    }

    /// A death between the stored end and its peaks: recovery keeps them before the working file
    /// goes.
    @Test func aDeathBeforeThePeaksLeavesThemForRecovery() async throws {
        let r = Rig(engineIngests: false)
        let kill = KillSwitch()
        kill.arm(.afterRecordingEnded)
        let engine = r.engine(killPoint: kill.hook, ingests: false)
        let states = engine.states()
        let begun = try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
        _ = await SuiteWait.value("the recording's frames to be durable") {
            for await state in states where state.captureID == begun.captureID && state.durableRevision > 0 {
                return true
            }
            return false
        }
        try Self.writePeaks(r, begun.captureID)
        r.clock.advance(by: 2)
        let ending = Task { try await engine.end(begun.captureID) }
        #expect(try #require(await kill.untilKilled()) == begun.captureID)
        #expect(try await Self.peaks(r, begun.captureID) == nil, "The end came, not the peaks.")
        let next = r.relaunch()
        _ = try await next.recovery.run(ingest: next.ingest)
        #expect(try await Self.peaks(r, begun.captureID) == (try await Self.kept(r, begun.captureID)))
        #expect(!r.layer.exists(r.locations.recordingPeaks(begun.captureID)))
        kill.release()
        _ = await SuiteWait.value("the dead launch's end") { try? await ending.value }
    }

    /// An orphan that recovery converts and stores keeps its peaks too.
    @Test func aRecoveredOrphanKeepsItsPeaks() async throws {
        let r = Rig(engineIngests: false)
        let kill = KillSwitch()
        kill.arm(.beforeConversion)
        let engine = r.engine(killPoint: kill.hook, ingests: false)
        let states = engine.states()
        let begun = try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
        _ = await SuiteWait.value("the recording's frames to be durable") {
            for await state in states where state.captureID == begun.captureID && state.durableRevision > 0 {
                return true
            }
            return false
        }
        try Self.writePeaks(r, begun.captureID)
        r.clock.advance(by: 2)
        let ending = Task { try await engine.end(begun.captureID) }
        #expect(try #require(await kill.untilKilled()) == begun.captureID)
        let next = r.relaunch()
        _ = try await next.recovery.run(ingest: next.ingest)
        #expect(try await r.notes.capture(begun.captureID)?.outcome == .stored)
        #expect(try await Self.peaks(r, begun.captureID) == (try await Self.kept(r, begun.captureID)))
        kill.release()
        _ = await SuiteWait.value("the dead launch's end") { try? await ending.value }
    }

    /// No peaks file: nothing is set, and nothing is logged of peaks.
    @Test func noPeaksFileSetsNothing() async throws {
        let r = Rig()
        let recording = try await r.beginRecording()
        r.clock.advance(by: 2)
        _ = try await r.engine.end(recording.captureID)
        #expect(try await Self.peaks(r, recording.captureID) == nil)
        #expect(!r.logs.lines.contains { $0.contains("recording_peaks") })
    }
}
