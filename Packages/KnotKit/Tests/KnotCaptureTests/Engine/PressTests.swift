import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

/// The engine as the one applier of a press where there is an engine (`CaptureEngine.press`,
/// pull request 81): `RecordingPressRule` against the engine's own recordings and the saved
/// state, carried out, with the cues that are the recorder's caller's. The scripted recorder
/// gives no cue, so every cue here is the engine's.
@Suite struct PressTests {
    private struct Parts {
        let r: Rig
        let engine: BoundedEngine
        let cues: RecordingCueEmitter
        let saved: InMemoryRecordingStateStore
    }

    private static func parts() -> Parts {
        let r = Rig()
        let cues = RecordingCueEmitter()
        let saved = InMemoryRecordingStateStore()
        return Parts(r: r, engine: r.engine(recordingState: saved, cues: cues), cues: cues, saved: saved)
    }

    /// Waits until a recording's frames are durable, as a person's would be after a moment.
    private static func durable(_ capture: CaptureID, _ engine: BoundedEngine, states: AsyncStream<CaptureState>)
        async
    {
        _ = await SuiteWait.value("the recording's frames to be durable") {
            for await state in states where state.captureID == capture && state.durableRevision > 0 { return true }
            return false
        }
    }

    /// The files in `Recording/` and `Assets/`, by their place under the store.
    private static func files(_ r: Rig) throws -> [String] {
        var found: [String] = []
        if r.layer.exists(r.locations.recording) {
            found += try r.layer.contents(of: r.locations.recording).map { "Recording/\($0)" }
        }
        guard r.layer.exists(r.locations.assets) else { return found }
        for folder in try r.layer.contents(of: r.locations.assets) {
            let url = r.locations.assets.appending(path: folder, directoryHint: .isDirectory)
            guard r.layer.entryKind(url) == .folder else { continue }
            found += try r.layer.contents(of: url).map { "Assets/\(folder)/\($0)" }
        }
        return found.sorted()
    }

    // MARK: The rule's table

    @Test func aTapStartsARecording() async throws {
        let p = Self.parts()
        let state = try #require(try await p.engine.press(p.r.press(.tap)).started)
        #expect(state.kind == .voice)
        #expect(state.outcome == .open)
        #expect(p.cues.cues.isEmpty, "The live cue is the recorder's.")
        #expect(p.r.logs.logged("press_started", state.captureID))
    }

    @Test func aTapWithinASecondDiscardsTheRecording() async throws {
        let p = Self.parts()
        let states = p.engine.states()
        let state = try #require(try await p.engine.press(p.r.press(.tap)).started)
        await Self.durable(state.captureID, p.engine, states: states)
        p.r.clock.advance(by: 0.5)
        let stopped = try #require(try await p.engine.press(p.r.press(.tap)).stopped)
        #expect(stopped.outcome == .discardedEmpty)
        #expect(p.cues.cues == [.discarded])
        #expect(try await p.r.stream().notes.isEmpty)
    }

    @Test func aTapAfterASecondKeepsTheRecording() async throws {
        let p = Self.parts()
        let states = p.engine.states()
        let state = try #require(try await p.engine.press(p.r.press(.tap)).started)
        await Self.durable(state.captureID, p.engine, states: states)
        p.r.clock.advance(by: 2)
        let stopped = try #require(try await p.engine.press(p.r.press(.tap)).stopped)
        #expect(stopped.captureID == state.captureID)
        #expect(stopped.outcome == .stored)
        #expect(p.cues.cues == [.saved])
        #expect(try await p.r.notes.segment(SegmentID(state.captureID))?.segment.assetID == AssetID(state.captureID))
    }

    @Test func aHoldIsExemptFromTheAccidentalPressWindow() async throws {
        let p = Self.parts()
        let states = p.engine.states()
        let state = try #require(try await p.engine.press(p.r.press(.holdStart)).started)
        await Self.durable(state.captureID, p.engine, states: states)
        p.r.clock.advance(by: 0.5)
        let stopped = try #require(try await p.engine.press(p.r.press(.holdRelease)).stopped)
        #expect(stopped.outcome == .stored)
        #expect(p.cues.cues == [.saved])
    }

    @Test func aReleaseEndsOnlyTheHoldThatStartedTheRecording() async throws {
        let p = Self.parts()
        #expect(try await p.engine.press(p.r.press(.holdRelease)) == .ignored, "Nothing records.")
        let state = try #require(try await p.engine.press(p.r.press(.tap)).started)
        p.r.clock.advance(by: 2)
        #expect(try await p.engine.press(p.r.press(.holdRelease)) == .ignored, "A tap started it.")
        #expect(try await p.r.notes.capture(state.captureID)?.outcome == .open)
        #expect(p.cues.cues.isEmpty)
    }

    // MARK: Presses at once

    /// A press while the recording is still starting is ignored: its row's store call is held.
    @Test func aPressWhileTheRecordingStartsIsIgnored() async throws {
        let p = Self.parts()
        let hold = await p.r.notes.holdNextCaptureWrite()
        let first = Task { try await p.engine.press(p.r.press(.tap)) }
        await reached(hold)
        p.r.clock.advance(by: 2)
        #expect(try await p.engine.press(p.r.press(.tap)) == .ignored)
        hold.release()
        let state = try #require(try await first.value.started)
        #expect(try await p.r.notes.capture(state.captureID)?.outcome == .open)
    }

    /// A press while the recording is stopping is ignored: its end's store call is held.
    @Test func aPressWhileTheRecordingStopsIsIgnored() async throws {
        let p = Self.parts()
        let states = p.engine.states()
        let state = try #require(try await p.engine.press(p.r.press(.tap)).started)
        await Self.durable(state.captureID, p.engine, states: states)
        p.r.clock.advance(by: 2)
        let hold = await p.r.notes.holdNextCaptureWrite()
        let stopping = Task { try await p.engine.press(p.r.press(.tap)) }
        await reached(hold)
        #expect(try await p.engine.press(p.r.press(.tap)) == .ignored, "No second recording starts.")
        hold.release()
        let stopped = try #require(try await stopping.value.stopped)
        #expect(stopped.outcome == .stored)
        #expect(p.cues.cues == [.saved])
        #expect(try await p.r.notes.openCaptures().isEmpty)
    }

    /// The review of pull request 91, N2. Two presses in the same moment on an idle engine: the
    /// rule's decision and its first step are taken with no suspension between, so one starts a
    /// recording and the other finds it starting and is ignored. No error, no cue of the engine's,
    /// one open capture.
    @Test(arguments: 0..<20)
    func twoPressesAtOnceStartOneRecording(round: Int) async throws {
        let p = Self.parts()
        let tap = p.r.press(.tap)
        async let first = Self.outcome(of: tap, on: p.engine)
        async let second = Self.outcome(of: tap, on: p.engine)
        let outcomes = await [first, second]
        let started = outcomes.filter { (try? $0.get())?.started != nil }.count
        let ignored = outcomes.filter { (try? $0.get()) == .ignored }.count
        let failed = outcomes.compactMap { outcome -> KnotError? in
            if case .failure(let error) = outcome { return error }
            return nil
        }
        #expect(started == 1)
        #expect(ignored == 1)
        #expect(failed.isEmpty, "\(failed.map(\.code))")
        #expect(p.cues.cues.isEmpty)
        #expect(try await p.r.notes.openCaptures().count == 1)
    }

    private static func outcome(of press: Press, on engine: BoundedEngine) async
        -> Result<RecordingPressOutcome, KnotError>
    {
        do throws(KnotError) {
            return .success(try await engine.press(press))
        } catch {
            return .failure(error)
        }
    }

    // MARK: Whose recording

    /// A recording that an intent started is stopped by a press from the app: the recorder in
    /// this process is the truth, whoever started it.
    @Test func aRecordingAnIntentStartedStopsByAPressFromTheApp() async throws {
        let p = Self.parts()
        let states = p.engine.states()
        let state = try #require(
            try await p.engine.press(p.r.press(.tap), recording: CaptureRequest(kind: .voice, surface: .intent)).started
        )
        await Self.durable(state.captureID, p.engine, states: states)
        p.r.clock.advance(by: 2)
        let stopped = try #require(
            try await p.engine.press(p.r.press(.tap), recording: CaptureRequest(kind: .voice, surface: .app)).stopped)
        #expect(stopped.captureID == state.captureID)
        #expect(stopped.outcome == .stored)
    }

    /// A recording that `begin` started counts as started by a tap at its start.
    @Test func aRecordingBegunThroughBeginStopsByAPress() async throws {
        let p = Self.parts()
        let begun = try await p.r.beginRecording(on: p.engine)
        p.r.clock.advance(by: 2)
        let stopped = try #require(try await p.engine.press(p.r.press(.tap)).stopped)
        #expect(stopped.captureID == begun.captureID)
        #expect(stopped.outcome == .stored)
        #expect(p.cues.cues == [.saved])
    }

    /// A saved state with no recording here is an orphan: a press starts a new recording at once,
    /// and the orphan is left to launch recovery.
    @Test func aPressAfterACrashStartsANewRecording() async throws {
        let p = Self.parts()
        let orphan: CaptureID = p.r.ids.make()
        let otherLaunch: LaunchID = p.r.ids.make()
        p.saved.write(
            RecordingStateSnapshot(
                phase: .recording, captureID: orphan, startedAt: p.r.clock.now(), heartbeat: p.r.clock.now(),
                ownerLaunch: otherLaunch))
        let state = try #require(try await p.engine.press(p.r.press(.tap)).started)
        #expect(state.captureID != orphan)
        #expect(p.r.logs.logged("press_found_orphan", orphan))
        #expect(try await p.r.notes.capture(state.captureID)?.outcome == .open)
    }

    /// A press right after a recording of this launch stopped, while the saved state still reads
    /// "recording" for that very capture, by this launch and this process, with a fresh
    /// heartbeat, and the recorder is idle: a read that gives back the process's own write from
    /// before the stop's two (row 11f). The rule decides `recoverOrphanThenStart`, and the
    /// engine starts a new recording at once. The stopped capture's row, segment and file stay
    /// exactly as they were, nothing is stored twice, no file of it is touched or looked for,
    /// and the one line that names it is `press_found_orphan`: the engine names it an orphan,
    /// and does nothing to it. The new recording then stops and is stored, as a press, a stop
    /// and a press again would have it.
    @Test func aPressAfterAStopThatMeetsItsOwnStaleStateStartsANewRecording() async throws {
        let p = Self.parts()
        let states = p.engine.states()
        let first = try #require(try await p.engine.press(p.r.press(.tap)).started)
        let a = first.captureID
        await Self.durable(a, p.engine, states: states)
        p.r.clock.advance(by: 2)
        let stopped = try #require(try await p.engine.press(p.r.press(.tap)).stopped)
        #expect(stopped.captureID == a && stopped.outcome == .stored && stopped.path == .store)
        // What the stop left: the row, its segment, its file in `Assets/`, and nothing else.
        let row = try #require(try await p.r.notes.capture(a))
        let segment = try #require(try await p.r.notes.segment(SegmentID(a))).segment
        let asset = try #require(try await p.r.notes.asset(AssetID(a)))
        let file = try #require(try await p.r.assets.find(AssetID(a), kind: .audio))
        let filesBefore = try Self.files(p.r)
        #expect(filesBefore == ["Assets/\(AssetID(a).folderName)/\(a).\(AssetKind.audio.fileExtension)"])
        // The stale read: this launch's own write from while it recorded.
        p.saved.write(
            RecordingStateSnapshot(
                phase: .recording, captureID: a, startedAt: row.startedAt, heartbeat: p.r.clock.now(),
                ownerLaunch: p.r.launchID, ownerPID: ProcessInfo.processInfo.processIdentifier))
        let linesBefore = p.r.logs.lines.count
        p.r.clock.advance(by: 1)
        let second = try #require(try await p.engine.press(p.r.press(.tap)).started, "The press starts a recording.")
        let b = second.captureID
        #expect(b != a)
        #expect(second.kind == .voice && second.outcome == .open)
        #expect(try await p.r.notes.capture(b)?.outcome == .open)
        // The stopped capture, exactly as the stop left it.
        #expect(try await p.r.notes.capture(a) == row)
        #expect(try await p.r.notes.segment(SegmentID(a))?.segment == segment)
        #expect(try await p.r.notes.asset(AssetID(a)) == asset)
        #expect(try await p.r.assets.find(AssetID(a), kind: .audio) == file)
        #expect(try Self.files(p.r).filter { $0.contains(a.description) } == filesBefore)
        // The one line that names it.
        let named = p.r.logs.lines.dropFirst(linesBefore).filter { $0.contains("capture=\(a)") }
        #expect(named == ["press_found_orphan capture=\(a)"], "Every line after the press that names it: \(named).")
        #expect(p.r.logs.logged("press_started", b))
        // A press, a stop and a press again: the new recording stops and is stored, and each
        // recording is in the stream once.
        await Self.durable(b, p.engine, states: states)
        p.r.clock.advance(by: 2)
        let again = try #require(try await p.engine.press(p.r.press(.tap)).stopped)
        #expect(again.captureID == b && again.outcome == .stored)
        let segments = try await p.r.stream().notes.flatMap(\.liveSegments).map(\.id)
        #expect(segments.filter { $0 == SegmentID(a) }.count == 1)
        #expect(segments.filter { $0 == SegmentID(b) }.count == 1)
        #expect(segments.count == 2)
        #expect(try await p.r.notes.capture(a) == row)
        #expect(p.r.logs.lines.dropFirst(linesBefore).filter { $0.contains("capture=\(a)") }.count == 1)
    }

    /// A saved state that names another capture while this engine records: the press stops the
    /// recording here, which is the truth.
    @Test func aPressStopsTheRecordingHereWhateverTheSavedStateSays() async throws {
        let p = Self.parts()
        let states = p.engine.states()
        let state = try #require(try await p.engine.press(p.r.press(.tap)).started)
        await Self.durable(state.captureID, p.engine, states: states)
        p.saved.write(
            RecordingStateSnapshot(
                phase: .recording, captureID: p.r.ids.make(), heartbeat: p.r.clock.now().addingTimeInterval(-60)))
        p.r.clock.advance(by: 2)
        let stopped = try #require(try await p.engine.press(p.r.press(.tap)).stopped)
        #expect(stopped.captureID == state.captureID)
        #expect(stopped.outcome == .stored)
    }

    // MARK: One cue starts, one ends

    /// The recorder and the engine share the app's emitter, as the composition gives it to both:
    /// exactly one cue starts a recording and exactly one ends it. The recorder gives the live
    /// cue and a refused start's; the engine gives the end's.
    @Test(arguments: [false, true])
    func oneCueStartsARecordingAndOneEndsIt(accidental: Bool) async throws {
        let r = Rig()
        let cues = RecordingCueEmitter()
        let recorder = ScriptedRecorder(locations: r.locations, layer: r.layer, clock: r.clock, cues: cues)
        let engine = r.engine(recorder: recorder, recordingState: InMemoryRecordingStateStore(), cues: cues)
        let states = engine.states()
        let state = try #require(try await engine.press(r.press(.tap)).started)
        #expect(cues.cues == [.recordingLive])
        await Self.durable(state.captureID, engine, states: states)
        r.clock.advance(by: accidental ? 0.5 : 2)
        _ = try #require(try await engine.press(r.press(.tap)).stopped)
        #expect(cues.cues == [.recordingLive, accidental ? .discarded : .saved])
    }

    @Test func aRefusedStartGivesOneCue() async throws {
        let r = Rig()
        let cues = RecordingCueEmitter()
        let recorder = ScriptedRecorder(locations: r.locations, layer: r.layer, clock: r.clock, cues: cues)
        recorder.failNextStarts(with: .audioSessionBusy)
        let engine = r.engine(recorder: recorder, recordingState: InMemoryRecordingStateStore(), cues: cues)
        await expectError(.audioSessionBusy) { try await engine.press(r.press(.tap)) }
        #expect(cues.cues == [.couldNotStart])
    }

    // MARK: Could not start

    /// A start the engine could not hand to the recorder: the engine gives `couldNotStart`.
    @Test func aStartThatNeverReachedTheRecorderGivesTheEnginesCue() async throws {
        let p = Self.parts()
        await expectError(.illegalTransition) {
            try await p.engine.press(p.r.press(.tap), recording: CaptureRequest(kind: .typed, surface: .app))
        }
        #expect(p.cues.cues == [.couldNotStart])
    }

    /// A start that the recorder refused: the recorder gave the cue, and the engine gives none.
    @Test func aStartTheRecorderRefusedGivesNoCueOfTheEngines() async throws {
        let p = Self.parts()
        p.r.recorder.failNextStarts(with: .audioSessionBusy)
        await expectError(.audioSessionBusy) { try await p.engine.press(p.r.press(.tap)) }
        #expect(p.cues.cues.isEmpty)
        #expect(try await p.engine.press(p.r.press(.tap)).started != nil, "The next press starts one.")
    }
}
