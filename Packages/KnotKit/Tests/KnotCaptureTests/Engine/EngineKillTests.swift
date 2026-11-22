import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// Text saved before a simulated kill is present after relaunch, at every kill point of the
/// engine, on the store path and on the `Inbox/` path, and after a power cut there.
///
/// The engine stops at the armed `EngineKillPoint`, as a kill would: the call that reaches it
/// never answers. The test relaunches over the same store and files, runs recovery with
/// ingest, and checks every text that a call answered as saved.
@Suite struct EngineKillTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let point: EngineKillPoint
        let kind: SegmentKind
        let inbox: Bool
        let powerCut: Bool
        /// How many reaches of the point go on before the one that stops.
        var skips = 0

        var testDescription: String {
            let at = skips == 0 ? "" : ", after \(skips) reach\(skips == 1 ? "" : "es")"
            return
                "\(kind) \(point.rawValue) on the \(inbox ? "Inbox/" : "store") path\(powerCut ? ", power cut" : "")\(at)"
        }
    }

    static let typedCases: [Case] =
        [EngineKillPoint.afterStart, .afterSave, .afterTypedEnd, .beforeEndingFollowed].flatMap { point in
            [
                Case(point: point, kind: .typed, inbox: false, powerCut: false),
                Case(point: point, kind: .typed, inbox: true, powerCut: false),
                Case(point: point, kind: .typed, inbox: true, powerCut: true),
            ]
        }
        // Between a typed item's manifest and its payload, which only `Inbox/` has: at the begin's
        // item, with nothing acknowledged, and at the update's, over the begin's payload.
        + [0, 1].flatMap { skips in
            [false, true].map { powerCut in
                Case(
                    point: .betweenTypedManifestAndPayload, kind: .typed, inbox: true, powerCut: powerCut, skips: skips)
            }
        }

    /// A recording is killed after its first manifest before any store call, so the point has one
    /// case: the path is not chosen yet.
    static let voiceCases: [Case] =
        [
            EngineKillPoint.afterStart, .beforeConversion, .afterFailedConversion, .afterRecordingMoved,
            .afterRecordingEnded,
        ]
        .flatMap { point in
            [false, true].map { inbox in Case(point: point, kind: .voice, inbox: inbox, powerCut: false) }
        } + [Case(point: .afterRecordingManifest, kind: .voice, inbox: false, powerCut: false)]

    @Test(arguments: typedCases)
    func typedTextSurvivesAKill(_ kill: Case) async throws {
        let r = Rig(engineIngests: false)
        if kill.inbox { await r.notes.failNextCaptureWrites(with: .storeBusy) }
        let killSwitch = KillSwitch()
        killSwitch.arm(kill.point, skipping: kill.skips)
        let engine = r.engine(killPoint: killSwitch.hook, stops: killSwitch.stops, ingests: false)
        let acknowledged = Mutex<[CaptureID: String]>([:])
        let clock = r.clock
        // The surface's calls, in order, until one of them stops at the kill point.
        let surface = Task {
            let first = try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "one"))
            acknowledged.withLock { $0[first.captureID] = "one" }
            clock.advance(by: 2)
            _ = try await engine.update(first.captureID, with: .text("one two"))
            acknowledged.withLock { $0[first.captureID] = "one two" }
            clock.advance(by: 2)
            if kill.point == .beforeEndingFollowed {
                let second = try await engine.begin(CaptureRequest(kind: .typed, surface: .macPanel, text: "three"))
                acknowledged.withLock { $0[second.captureID] = "three" }
            }
            _ = try await engine.end(first.captureID)
        }
        let killed = try #require(await killSwitch.untilKilled())
        if kill.point == .betweenTypedManifestAndPayload {
            // The write stopped between its two placings: the manifest is placed, and the payload
            // is not, or is still the begin's.
            #expect(r.layer.exists(r.locations.inboxManifest(killed)))
            #expect(r.inboxText(killed) == (kill.skips == 0 ? nil : "one"), "\(kill)")
        }
        if kill.powerCut { r.layer.cutPower() }
        r.clock.advance(by: 60)

        let next = r.relaunch()
        _ = try await next.recovery.run(ingest: next.ingest)
        #expect(try await r.notes.openCaptures().isEmpty)
        #expect(r.inboxFiles().isEmpty)
        // What the seam's name says is on the drive, exactly: every text a call answered, and the
        // text of the call that stopped at the seam, which was durable before it stopped.
        var expected = acknowledged.withLock { $0 }
        switch kill.point {
        case .afterStart: expected[killed] = "one"
        case .afterSave, .afterTypedEnd: expected[killed] = "one two"
        case .beforeEndingFollowed: expected[killed] = "three"
        default: break
        }
        for (capture, text) in expected {
            let stored = try await r.notes.segment(SegmentID(capture))?.segment.text
            #expect(stored == text, "\(kill): \(capture) holds \(stored?.count ?? -1) characters, not \(text.count).")
        }
        killSwitch.release()
        _ = await SuiteWait.value("the dead launch's calls") { try? await surface.value }
    }

    @Test(arguments: voiceCases)
    func recordingSurvivesAKill(_ kill: Case) async throws {
        let r = Rig(engineIngests: false)
        if kill.inbox { await r.notes.failNextCaptureWrites(with: .storeBusy) }
        let killSwitch = KillSwitch()
        killSwitch.arm(kill.point)
        // A conversion that fails, so that the engine reaches the point after it.
        if kill.point == .afterFailedConversion { r.recorder.failNextConversions(with: .conversionFailed) }
        let engine = r.engine(killPoint: killSwitch.hook, ingests: false)
        let states = engine.states()
        let watched = engine.states()
        let clock = r.clock
        let surface = Task {
            let begun = try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
            for await state in states where state.captureID == begun.captureID && state.durableRevision > 0 { break }
            clock.advance(by: 3)
            _ = try await engine.end(begun.captureID)
        }
        let killed = try #require(await killSwitch.untilKilled())
        if kill.point == .afterStart || kill.point == .afterRecordingManifest {
            // Some audio is on the drive before the kill, as for a recording that ran a moment.
            _ = await SuiteWait.value("the recording's frames to be durable") {
                for await state in watched where state.captureID == killed && state.durableRevision > 0 { return true }
                return false
            }
        }
        r.clock.advance(by: 60)

        let next = r.relaunch()
        _ = try await next.recovery.run(ingest: next.ingest)
        #expect(try await r.notes.openCaptures().isEmpty)
        #expect(r.inboxFiles().isEmpty)
        let row = try #require(try await r.notes.capture(killed))
        #expect(row.outcome == .stored, "\(kill)")
        #expect(try await r.notes.segment(SegmentID(killed))?.segment.assetID == AssetID(killed))
        #expect(try await r.notes.jobs(for: SegmentID(killed)).map(\.kind) == [.transcribe])
        #expect(try await r.stream().notes.flatMap(\.liveSegments).count == 1)
        killSwitch.release()
        _ = await SuiteWait.value("the dead launch's calls") { try? await surface.value }
    }

    struct DiscardCase: CustomTestStringConvertible, Sendable {
        let kind: SegmentKind
        let inbox: Bool
        var testDescription: String { "\(kind) on the \(inbox ? "Inbox/" : "store") path" }
    }

    static let discardCases = [SegmentKind.typed, .voice].flatMap { kind in
        [false, true].map { DiscardCase(kind: kind, inbox: $0) }
    }

    /// A kill at `afterDiscard`: a recording's audio is removed and its row not ended yet, or a
    /// typed capture's end as empty is durable. After relaunch nothing of the capture is in the
    /// stream, no row is open and `Inbox/` is empty.
    @Test(arguments: discardCases)
    func discardSurvivesAKill(_ kill: DiscardCase) async throws {
        let r = Rig(engineIngests: false)
        if kill.inbox { await r.notes.failNextCaptureWrites(with: .storeBusy) }
        let killSwitch = KillSwitch()
        killSwitch.arm(.afterDiscard)
        let engine = r.engine(killPoint: killSwitch.hook, ingests: false)
        let states = engine.states()
        let clock = r.clock
        let surface = Task {
            let begun =
                kill.kind == .typed
                ? try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "gone"))
                : try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
            if kill.kind == .voice {
                for await state in states where state.captureID == begun.captureID && state.durableRevision > 0 {
                    break
                }
            }
            clock.advance(by: 3)
            _ = try await engine.discard(begun.captureID)
        }
        let killed = try #require(await killSwitch.untilKilled())
        r.clock.advance(by: 60)

        let next = r.relaunch()
        _ = try await next.recovery.run(ingest: next.ingest)
        #expect(try await r.notes.openCaptures().isEmpty, "\(kill)")
        #expect(r.inboxFiles().isEmpty, "\(kill)")
        let segments = try await r.stream().notes.flatMap(\.liveSegments)
        #expect(!segments.contains { $0.id == SegmentID(killed) }, "\(kill): the discarded capture is in the stream.")
        killSwitch.release()
        _ = await SuiteWait.value("the dead launch's calls") { try? await surface.value }
    }

    /// A kill at `beforeLateAnswer`: a start's store call missed its deadline, the capture went to
    /// `Inbox/`, and the call then committed. The engine is killed before it takes the late
    /// answer. After relaunch the capture is stored once, from its row and its item, with what
    /// its calls answered as saved.
    struct LateCase: CustomTestStringConvertible, Sendable {
        let kind: SegmentKind
        let point: EngineKillPoint
        var testDescription: String { "\(kind) at \(point.rawValue)" }
    }

    /// The late answer's two seams: `beforeLateAnswer` for either kind, and `lateRecordingRow`,
    /// the moment between a recording's late row and its file.
    static let lateCases = [
        LateCase(kind: .typed, point: .beforeLateAnswer), LateCase(kind: .voice, point: .beforeLateAnswer),
        LateCase(kind: .voice, point: .lateRecordingRow),
    ]

    @Test(arguments: lateCases)
    func lateAnswerSurvivesAKill(_ late: LateCase) async throws {
        let kind = late.kind
        let r = Rig(engineIngests: false)
        let manual = ManualDeadline()
        let killSwitch = KillSwitch()
        killSwitch.arm(late.point)
        let engine = r.engine(deadline: manual.deadline, killPoint: killSwitch.hook, ingests: false)
        let hold = await r.notes.holdNextCaptureWrite()
        let starting = Task {
            kind == .typed
                ? try await engine.begin(CaptureRequest(kind: .typed, surface: .app, text: "late"))
                : try await engine.begin(CaptureRequest(kind: .voice, surface: .app))
        }
        await reached(hold)
        await manual.expireNext()
        let begun = try await starting.value
        #expect(begun.path == .inbox(KnotError.storeNotOpen.code))
        if kind == .voice {
            let states = engine.states()
            _ = await SuiteWait.value("the recording's frames to be durable") {
                for await state in states where state.captureID == begun.captureID && state.durableRevision > 0 {
                    return true
                }
                return false
            }
        }
        hold.release()
        let killed = try #require(await killSwitch.untilKilled())
        #expect(killed == begun.captureID)
        r.clock.advance(by: 60)

        let next = r.relaunch()
        _ = try await next.recovery.run(ingest: next.ingest)
        #expect(try await r.notes.openCaptures().isEmpty)
        #expect(r.inboxFiles().isEmpty)
        let row = try #require(try await r.notes.capture(killed))
        #expect(row.outcome == .stored)
        let segments = try await r.stream().notes.flatMap(\.liveSegments)
        #expect(segments.filter { $0.id == SegmentID(killed) }.count == 1)
        if kind == .typed {
            #expect(try await r.notes.segment(SegmentID(killed))?.segment.text == "late")
        } else {
            #expect(try await r.notes.segment(SegmentID(killed))?.segment.assetID == AssetID(killed))
        }
        killSwitch.release()
    }
}
