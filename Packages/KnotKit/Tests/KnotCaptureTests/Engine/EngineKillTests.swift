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

        var testDescription: String {
            "\(kind) \(point.rawValue) on the \(inbox ? "Inbox/" : "store") path\(powerCut ? ", power cut" : "")"
        }
    }

    static let typedCases: [Case] = [EngineKillPoint.afterStart, .afterSave, .afterTypedEnd, .beforeEndingFollowed]
        .flatMap { point in
            [
                Case(point: point, kind: .typed, inbox: false, powerCut: false),
                Case(point: point, kind: .typed, inbox: true, powerCut: false),
                Case(point: point, kind: .typed, inbox: true, powerCut: true),
            ]
        }

    static let voiceCases: [Case] = [
        Case(point: .afterStart, kind: .voice, inbox: false, powerCut: false),
        Case(point: .afterStart, kind: .voice, inbox: true, powerCut: false),
        Case(point: .afterRecordingMoved, kind: .voice, inbox: false, powerCut: false),
        Case(point: .afterRecordingMoved, kind: .voice, inbox: true, powerCut: false),
        Case(point: .afterRecordingEnded, kind: .voice, inbox: false, powerCut: false),
    ]

    @Test(arguments: typedCases)
    func typedTextSurvivesAKill(_ kill: Case) async throws {
        let r = Rig(engineIngests: false)
        if kill.inbox { await r.notes.failNextCaptureWrites(with: .storeBusy) }
        let killSwitch = KillSwitch()
        killSwitch.arm(kill.point)
        let engine = r.engine(killPoint: killSwitch.hook, ingests: false)
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
        if kill.point == .afterStart {
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
}
