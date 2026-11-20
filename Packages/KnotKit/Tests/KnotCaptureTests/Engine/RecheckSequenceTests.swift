import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// Sequences a re-check of pull request 40 wrote, which held when they were written and stay as
/// tests: re-check C's C2 to C5, around findings 34 and 38.
@Suite struct RecheckSequenceTests {
    private static func texts(_ r: Rig) async -> [String] {
        ((try? await r.stream())?.notes.flatMap(\.liveSegments).map(\.text) ?? []).sorted()
    }

    /// C2. A second capture on one surface, which goes to `Inbox/` because the store's rule 15
    /// refuses it while the first is open, ends before the first. Both texts reach the store, and
    /// no capture is left open.
    @Test func sameSurfaceCaptureEndedBeforeTheFirstIsStored() async throws {
        let r = Rig()
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "buy milk"))
        let b = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "call mom"))
        #expect(b.captureID != a.captureID)
        _ = try await r.engine.end(b.captureID)
        _ = try await r.engine.end(a.captureID)
        #expect(await eventually("both texts to be stored") { await Self.texts(r) == ["buy milk", "call mom"] })
        #expect(try await r.notes.openCaptures().isEmpty)
    }

    /// C3. Finding 34: two calls each schedule the old work while a refused discard's end waits
    /// in the store. Every call returns, the row ends once, and no capture is left open.
    @Test func twoCallsSchedulingOldWorkEndTheDiscardOnce() async throws {
        let impatient = Mutex(false)
        let r = Rig(
            deadline: StoreDeadline {
                if impatient.withLock({ $0 }) { return }
                try? await Task.sleep(for: SuiteWait.limit)
            })
        let recording = try await r.beginRecording()
        impatient.withLock { $0 = true }
        let ownEnd = await r.notes.holdNextCaptureWrite()
        let retryOne = await r.notes.holdNextCaptureWrite()
        let discarded = try await r.engine.discard(recording.captureID)
        #expect(discarded.path != .store)
        await reached(retryOne)
        // A second call schedules the old work again while the first run of it waits.
        let typed = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "t"))
        _ = try await r.engine.update(typed.captureID, with: .text("t, more"))
        ownEnd.release()
        retryOne.release()
        #expect(
            await eventually("the discarded recording's row to be ended") {
                (try? await r.notes.capture(recording.captureID))?.outcome == .discardedEmpty
            })
        _ = try await r.engine.end(typed.captureID)
        #expect(try await r.notes.openCaptures().isEmpty)
        #expect(await eventually("the typed text to be stored") { await Self.texts(r) == ["t, more"] })
    }

    /// C4. Finding 34: a conversion that fails again in the scheduled retry stays pending and
    /// keeps its working file; `retryConversions()` stores it once the recorder converts.
    @Test func scheduledRetryThatFailsAgainIsTriedOnce() async throws {
        let r = Rig()
        let recorder = WatchedRecorder(r.recorder)
        let engine = r.engine(recorder: recorder)
        let first = try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
        r.recorder.failNextConversions(with: .conversionFailed, .conversionFailed)
        _ = try await engine.end(first.captureID)
        r.clock.advance(by: 31)
        // The next call schedules the due retry, which fails again.
        let typed = try await engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "x"))
        #expect(await eventually("the scheduled retry to convert") { recorder.conversions == 2 })
        _ = try await engine.end(typed.captureID)
        #expect(try await r.notes.capture(first.captureID)?.outcome == .failed(KnotError.conversionFailed.code))
        await engine.retryConversions()
        #expect(try await r.notes.capture(first.captureID)?.outcome == .stored)
        #expect(recorder.conversions == 3)
    }

    /// C5. Finding 34: the process dies in the retry of a failed conversion, after the stored
    /// file was moved into the `AssetStore` and before the store ended the row. The next
    /// launch's recovery stores the recording once, with its transcribe job.
    @Test func deathInTheConversionRetryAfterTheMoveIsRecovered() async throws {
        let r = Rig()
        r.recorder.failNextConversions(with: .conversionFailed)
        let begun = try await r.beginRecording()
        _ = try await r.engine.end(begun.captureID)
        #expect(try await r.notes.capture(begun.captureID)?.outcome == .failed(KnotError.conversionFailed.code))
        let hold = await r.notes.holdNextCaptureWrite()
        let engine = r.engine
        let retry = Task { await engine.retryConversions() }
        // The file is converted and moved; the row's end waits in the store when the process dies.
        await reached(hold)
        let next = r.relaunch()
        let outcomes = try await next.recovery.run(ingest: next.ingest)
        #expect(outcomes[begun.captureID] == .ended(.stored))
        #expect(try await next.notes.capture(begun.captureID)?.outcome == .stored)
        #expect(try await next.notes.jobs(for: SegmentID(begun.captureID)).map(\.kind) == [.transcribe])
        #expect(try await next.stream().notes.flatMap(\.liveSegments).count == 1)
        // The dead launch's call is let go, so that nothing waits after the test.
        hold.release()
        _ = await SuiteWait.value("the dead launch's retry") { await retry.value }
    }
}

/// Re-check G's G2 to G5, around finding 41: starts that wait on one surface's line, each
/// decided once it holds the line.
extension RecheckSequenceTests {
    /// The answer of a start a test made in a task of its own, within `SuiteWait`'s limit.
    fileprivate static func returned(
        _ what: String, _ task: Task<CaptureState, any Error>, limit: Duration = SuiteWait.limit,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Result<CaptureState, any Error>? {
        await SuiteWait.value(what, limit: limit, sourceLocation: sourceLocation) { await task.result }
    }

    /// G2. Three starts at once on one surface; the first is answered as saved. The two that
    /// waited are captures of their own, and every text is kept.
    @Test func threeStartsOnOneSurfaceKeepEveryText() async throws {
        let r = Rig()
        let engine = r.engine.engine
        let hold = await r.notes.holdNextCaptureWrite()
        let one = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "one")) }
        await reached(hold)
        let two = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "two")) }
        #expect(
            await eventually("the second start to wait") {
                r.logs.lines.filter { $0.contains("start_waits_to_retry") }.count >= 1
            })
        let three = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "three")) }
        #expect(
            await eventually("the third start to wait") {
                r.logs.lines.filter { $0.contains("start_waits_to_retry") }.count >= 2
            })
        hold.release()
        let a = try #require(try await Self.returned("one", one)?.get())
        let b = try #require(try await Self.returned("two", two)?.get())
        let c = try #require(try await Self.returned("three", three)?.get())
        #expect(Set([a.captureID, b.captureID, c.captureID]).count == 3)
        for id in [a.captureID, b.captureID, c.captureID] { _ = try await r.engine.end(id) }
        #expect(await eventually("every text to be stored") { await Self.texts(r) == ["one", "three", "two"] })
        #expect(try await r.notes.openCaptures().isEmpty)
    }

    /// G3. The first start reaches no disk while two others on its surface wait. The first to
    /// hold the line is its retry, with its ID; the other is a capture of its own. Every text
    /// the surfaces were answered with is kept.
    @Test func firstStartFailsWhileTwoWait() async throws {
        let r = Rig()
        let engine = r.engine.engine
        let hold = await r.notes.holdNextCaptureWrite()
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        r.layer.failNextWrite(with: .diskFull)
        let one = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "one")) }
        await reached(hold)
        let two = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "one, again")) }
        #expect(
            await eventually("the second start to wait") {
                r.logs.lines.filter { $0.contains("start_waits_to_retry") }.count >= 1
            })
        let three = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "three")) }
        #expect(
            await eventually("the third start to wait") {
                r.logs.lines.filter { $0.contains("start_waits_to_retry") }.count >= 2
            })
        hold.release()
        let failed = await Self.returned("one", one)
        guard case .failure(let error as KnotError)? = failed else {
            Issue.record("The first start did not fail: \(String(describing: failed))")
            return
        }
        let firstID = try #require(error.context.captureID)
        let b = try #require(try await Self.returned("two", two)?.get())
        let c = try #require(try await Self.returned("three", three)?.get())
        #expect(b.captureID == firstID, "The first start to hold the line is the retry.")
        #expect(c.captureID != firstID, "The second is a capture of its own.")
        _ = try await r.engine.end(b.captureID)
        _ = try await r.engine.end(c.captureID)
        #expect(await eventually("both texts to be stored") { await Self.texts(r) == ["one, again", "three"] })
        #expect(try await r.notes.openCaptures().isEmpty)
    }

    /// G4. A start waits for the line as the open capture's retry, and its caller cancels its
    /// task. The call still returns once the line is free, and nothing is lost.
    @Test func cancelledWaitingStartReturns() async throws {
        let r = Rig()
        let engine = r.engine.engine
        let hold = await r.notes.holdNextCaptureWrite()
        let one = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "one")) }
        await reached(hold)
        let two = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "two")) }
        #expect(await eventually("the second start to wait") { r.logs.logged("start_waits_to_retry") })
        two.cancel()
        hold.release()
        let a = try #require(try await Self.returned("one", one)?.get())
        let answered = await Self.returned("two", two)
        #expect(answered != nil, "The cancelled start never returned.")
        if case .success(let b)? = answered {
            #expect(b.captureID != a.captureID)
            _ = try await r.engine.end(b.captureID)
            _ = try await r.engine.end(a.captureID)
            #expect(await eventually("both texts to be stored") { await Self.texts(r) == ["one", "two"] })
        }
    }

    /// G5. A start waits as the retry of a capture that reached no disk, behind a discard of
    /// that capture. Once it holds the line the capture is gone, so it is a capture of its own.
    /// The discard is in the capture's line before the start begins: the test makes that order
    /// with the engine's log line, since two tasks started one after the other keep none.
    @Test func startWaitingBehindADiscardIsACaptureOfItsOwn() async throws {
        let r = Rig()
        let hooks = JobHooks()
        let bounded = r.engine(notes: HookedStore(store: r.notes, hooks: hooks))
        let engine = bounded.engine
        let hold = await r.notes.holdNextCaptureWrite()
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        r.layer.failNextWrite(with: .diskFull)
        let one = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "one")) }
        await reached(hold)
        // The capture's ID, from the store's write that waits.
        let asked = try #require(hooks.captureWrites.withLock { $0.first })
        let firstID = try #require(CaptureID(String(asked.dropFirst("record ".count))))
        let discard = Task { try await engine.discard(firstID) }
        #expect(await eventually("the discard to wait for the line") { r.logs.logged("call_waits_for_line", firstID) })
        let two = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "two")) }
        #expect(await eventually("the second start to wait") { r.logs.logged("start_waits_to_retry", firstID) })
        hold.release()
        _ = await Self.returned("one", one)
        let discarded = try #require(try await Self.returned("the discard", discard)?.get())
        #expect(discarded.outcome == .discardedEmpty)
        let b = try #require(try await Self.returned("two", two)?.get())
        try #require(b.captureID != firstID, "The start came before the discard.")
        _ = try await bounded.end(b.captureID)
        #expect(await eventually("the text to be stored") { await Self.texts(r) == ["two"] })
    }
}

/// Two sequences in which two starts wait for each other's line for ever: findings 52 and 53
/// of re-check G at 91f961b3, set aside from pull request 40 as the first findings of WP-11,
/// the capture engine. Each is a known issue: when WP-11 makes every call return, the issue no
/// longer occurs, the test fails, and the mark comes out.
///
/// Each waits for its stuck calls a short time of its own, not `SuiteWait`'s ten minutes. A
/// stuck call is a task suspended on its own rig's engine, holding no thread, so it holds up no
/// other test.
@Suite struct EngineKnownIssues {
    /// How long a test waits for a start that never returns.
    static let stuckLimit: Duration = .seconds(5)

    private static func returned(
        _ what: String, _ task: Task<CaptureState, any Error>, limit: Duration = SuiteWait.limit,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Result<CaptureState, any Error>? {
        await SuiteWait.value(what, limit: limit, sourceLocation: sourceLocation) { await task.result }
    }

    /// A stuck call shows as a wait that ran out, or as an answer that never came.
    private static func isStuck(_ issue: Issue) -> Bool {
        issue.comments.contains { $0.rawValue.contains("Waited") || $0.rawValue.contains("never returned") }
    }

    /// Finding 52, re-check G's G1, set aside for WP-11. The first typed start on the app
    /// reaches no disk while two calls wait for its line: its retry on the same surface, then a
    /// typed start on the Mac panel. The retry holds the line and is the retry; rule 15 then
    /// ends, for it, the newest open capture, the panel's start, while holding its own line,
    /// and the panel's start holds its line and waits for the retry's. Neither returns.
    @Test func retryAndAnotherSurfacesStartWaitingOnOneLineBothReturn() async throws {
        let r = Rig(engineIngests: false)
        let engine = r.engine.engine
        let hold = await r.notes.holdNextCaptureWrite()
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        r.layer.failNextWrite(with: .diskFull)
        let first = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "first")) }
        await reached(hold)
        let retry = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "first")) }
        #expect(await eventually("the retry to wait for the line") { r.logs.logged("start_waits_to_retry") })
        r.clock.advance(by: 1)
        let panel = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "other")) }
        #expect(
            await eventually("the panel's start to wait for the open capture") {
                r.logs.logged("start_waits_for_open_capture")
            })
        hold.release()
        let failed = await Self.returned("the first start", first)
        if case .success? = failed { Issue.record("The first start reached disk.") }
        await withKnownIssue("Finding 52, WP-11: the retry and the panel's start wait for each other") {
            let retried = await Self.returned("the retry", retry, limit: Self.stuckLimit)
            let other = await Self.returned("the panel's start", panel, limit: Self.stuckLimit)
            #expect(retried != nil, "The retry never returned.")
            #expect(other != nil, "The panel's start never returned.")
        } matching: {
            Self.isStuck($0)
        }
    }

    /// Finding 53, re-check G's G6, set aside for WP-11. No failure at all: the open typed
    /// capture's end waits in the store; a typed start on the Mac panel waits for that
    /// capture's line; a typed start on the intent surface waits for the panel's. Once the end
    /// is stored, the panel's start plans again while it holds its own line, finds the intent's
    /// start the newest open capture and waits for its line, which the intent's start holds
    /// while it waits for the panel's. The end returns; neither start does.
    @Test func twoStartsWaitingBehindAnEndBothReturn() async throws {
        let r = Rig()
        let engine = r.engine.engine
        let a = try await r.engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "a"))
        let hold = await r.notes.holdNextCaptureWrite()
        let ending = Task { try await engine.end(a.captureID) }
        await reached(hold)
        r.clock.advance(by: 1)
        let panel = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "b")) }
        #expect(
            await eventually("the panel's start to wait") {
                r.logs.lines.filter { $0.contains("start_waits_for_open_capture") }.count >= 1
            })
        r.clock.advance(by: 1)
        let intent = Task { try await engine.begin(CaptureRequest(kind: .typed, surface: .intent, text: "c")) }
        #expect(
            await eventually("the intent's start to wait") {
                r.logs.lines.filter { $0.contains("start_waits_for_open_capture") }.count >= 2
            })
        hold.release()
        let ended = await Self.returned("the end", ending)
        #expect(ended != nil)
        await withKnownIssue("Finding 53, WP-11: two starts behind an end wait for each other") {
            let b = await Self.returned("the panel's start", panel, limit: Self.stuckLimit)
            let c = await Self.returned("the intent's start", intent, limit: Self.stuckLimit)
            #expect(b != nil, "The panel's start never returned.")
            #expect(c != nil, "The intent's start never returned.")
        } matching: {
            Self.isStuck($0)
        }
    }

    /// Finding 54 of the review of pull request 50, set aside for WP-11. Typed capture A is open
    /// on the `Inbox/` path with the window off, and recording B starts; the recorder writes a
    /// manifest that names A, the capture open at the start. While the recorder's start is
    /// held, A ends by its own call, and the store refuses B's row. Alive, rule 15 ends
    /// nothing, B's item names nothing, and B is a note of its own. After a death while B
    /// records, recovery reads the first manifest and puts B in A's note, which it would not
    /// join alive: the known issue. Nothing is lost or doubled either way.
    @Test(arguments: [false, true]) func openCaptureEndsDuringTheStart(death: Bool) async throws {
        let r = Rig(engineIngests: false)
        await r.notes.setWindow(.off)
        let recorder = WatchedRecorder(r.recorder)
        // No ingest of the engine's own: the items stay in `Inbox/` until the next launch.
        let engine = BoundedEngine(
            StandardCaptureEngine(
                notes: r.notes, assets: r.assets, recorder: recorder, queue: r.queue, clock: r.clock, ids: r.ids,
                deviceID: r.deviceID, launchID: r.launchID, locations: r.locations, layer: r.layer,
                deadline: .patient, ingest: nil, log: KnotLog(.capture, sink: r.logs)))
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let a = try await engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "draft"))
        r.clock.advance(by: 1)
        recorder.startGate.close()
        // The store refuses the recording's row.
        await r.notes.failNextCaptureWrites(with: .storeBusy)
        let inner = engine.engine
        let starting = Task { try await inner.begin(CaptureRequest(kind: .voice, surface: .app)) }
        #expect(await eventually("the recording's start to be held") { recorder.startGate.isHolding })
        _ = try await engine.end(a.captureID)
        recorder.startGate.open()
        let b = try #require(await SuiteWait.value("the recording's start") { try? await starting.value } ?? nil)
        let firstManifest = try CaptureManifest.decode(try r.layer.read(r.locations.recordingManifest(b.captureID)))
        #expect(
            firstManifest.followsCaptureID == a.captureID, "The first manifest names the capture open at the start.")
        #expect(try await r.notes.capture(b.captureID) == nil, "The store did not take the recording's row.")
        if !death {
            _ = try await engine.end(b.captureID)
            let item = try CaptureManifest.decode(try r.layer.read(r.locations.inboxManifest(b.captureID)))
            #expect(item.followsCaptureID == nil, "The item names what rule 15 ended: nothing.")
        }
        r.clock.advance(by: 5)
        let next = r.relaunch()
        _ = try await next.recovery.run(ingest: next.ingest)
        #expect(r.inboxFiles().isEmpty)
        let noteA = try #require(try await r.notes.segment(SegmentID(a.captureID))).noteID
        let noteB = try #require(try await r.notes.segment(SegmentID(b.captureID))).noteID
        if death {
            withKnownIssue("Finding 54, WP-11: after a death the recording joins a note it would not join alive") {
                #expect(noteA != noteB, "The recording joined the typed capture's note.")
            }
        } else {
            #expect(noteA != noteB, "Alive, with the window off, the recording is a note of its own.")
        }
    }
}
