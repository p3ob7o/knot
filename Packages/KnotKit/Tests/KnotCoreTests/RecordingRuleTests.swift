import Foundation
import KnotCore
import Testing

@Suite struct RecordingPressRuleTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let press: Press
        let recorder: RecorderActivity?
        let saved: SavedRecordingState?
        let expected: PressDecision
        var testDescription: String { name }
    }

    static let orphan: CaptureID = id(50)
    static let fresh = SavedRecordingState(captureID: orphan, launchID: id(60), heartbeatAt: at("10:00:00"))
    static let stale = SavedRecordingState(captureID: orphan, launchID: id(60), heartbeatAt: at("09:59:55"))
    static let now = at("10:00:02")
    static let tapAt10 = Press(.tap, at: at("10:00:00"))
    static let holdAt10 = Press(.holdStart, at: at("10:00:00"))

    static let rows: [Row] = [
        // In the app process the recorder is the truth.
        Row(name: "idle: a tap starts", press: Press(.tap, at: now), recorder: .idle, saved: nil, expected: .start),
        Row(
            name: "idle: the hold mark starts", press: Press(.holdStart, at: now), recorder: .idle, saved: nil,
            expected: .start),
        Row(
            name: "idle: a release with nothing held does nothing", press: Press(.holdRelease, at: now),
            recorder: .idle, saved: nil, expected: .ignore),
        Row(
            name: "starting: a press is ignored", press: Press(.tap, at: now), recorder: .starting, saved: fresh,
            expected: .ignore),
        Row(
            name: "stopping: a press is ignored", press: Press(.tap, at: now), recorder: .stopping, saved: fresh,
            expected: .ignore),
        Row(
            name: "recording: a press stops what this process runs, whatever the heartbeat",
            press: Press(.tap, at: at("10:00:05")), recorder: .recording(startedBy: tapAt10), saved: stale,
            expected: .stopAndKeep),
        Row(
            name: "recording: a second press within one second discards", press: Press(.tap, at: at("10:00:00.9")),
            recorder: .recording(startedBy: tapAt10), saved: fresh, expected: .stopAndDiscard),
        Row(
            name: "recording: a second press at exactly one second keeps", press: Press(.tap, at: at("10:00:01")),
            recorder: .recording(startedBy: tapAt10), saved: fresh, expected: .stopAndKeep),
        Row(
            name: "a hold is exempt from the one-second discard", press: Press(.holdRelease, at: at("10:00:00.4")),
            recorder: .recording(startedBy: holdAt10), saved: fresh, expected: .stopAndKeep),
        Row(
            name: "a hotkey release does not end a tap-started recording",
            press: Press(.holdRelease, at: at("10:00:05")), recorder: .recording(startedBy: tapAt10), saved: fresh,
            expected: .ignore),
        Row(
            name: "another press of the hotkey stops a recording", press: Press(.holdStart, at: at("10:00:05")),
            recorder: .recording(startedBy: tapAt10), saved: fresh, expected: .stopAndKeep),
        // After a crash: a press never does nothing.
        Row(
            name: "after a crash, a fresh heartbeat of a dead launch is an orphan", press: Press(.tap, at: now),
            recorder: .idle, saved: fresh, expected: .recoverOrphanThenStart(orphan)),
        Row(
            name: "after a crash, a stale heartbeat is an orphan", press: Press(.tap, at: now), recorder: .idle,
            saved: stale, expected: .recoverOrphanThenStart(orphan)),
        // In another process, such as a control in the widget extension, the heartbeat decides.
        Row(
            name: "elsewhere: nothing saved, a tap starts", press: Press(.tap, at: now), recorder: nil, saved: nil,
            expected: .start),
        Row(
            name: "elsewhere: a fresh heartbeat, a tap asks the app to stop", press: Press(.tap, at: now),
            recorder: nil, saved: fresh, expected: .askOwnerToStop(orphan)),
        Row(
            name: "elsewhere: a stale heartbeat, a tap recovers and starts", press: Press(.tap, at: now), recorder: nil,
            saved: stale, expected: .recoverOrphanThenStart(orphan)),
        Row(
            name: "elsewhere: a stale heartbeat, a release does nothing", press: Press(.holdRelease, at: now),
            recorder: nil, saved: stale, expected: .ignore),
    ]

    @Test(arguments: rows) func pressDecisions(row: Row) {
        #expect(
            RecordingPressRule.decide(row.press, recorder: row.recorder, saved: row.saved, now: Self.now)
                == row.expected)
    }

    @Test func thePressAfterACrashNeverDoesNothing() {
        // docs/product-spec.md §4.2: if a crash cut a recording short, the next press starts a
        // new recording and the cut one is recovered beside it, fresh heartbeat or stale,
        // in the app or elsewhere.
        for saved in [Self.fresh, Self.stale] {
            #expect(
                RecordingPressRule.decide(Press(.tap, at: Self.now), recorder: .idle, saved: saved, now: Self.now)
                    != .ignore)
        }
        #expect(
            RecordingPressRule.decide(Press(.tap, at: Self.now), recorder: nil, saved: Self.stale, now: Self.now)
                == .recoverOrphanThenStart(Self.orphan))
    }

    @Test(arguments: [(0.0, false), (2.9, false), (3.0, false), (3.1, true), (-3.0, false), (-3.1, true)])
    func aHeartbeatOlderThanThreeSecondsIsStale(age: Double, stale: Bool) {
        let saved = SavedRecordingState(captureID: id(1), launchID: id(2), heartbeatAt: at("10:00"))
        #expect(saved.isStale(at: at("10:00").addingTimeInterval(age)) == stale)
    }

    @Test func theDiscardIsMeasuredBetweenThePressesNotInAudio() {
        // The microphone went live 0.6 seconds after the tap; the stop came 0.9 seconds after
        // the tap, so 0.3 seconds of audio. Measured between the presses: discarded.
        #expect(RecordingPressRule.isAccidental(start: Self.tapAt10, stop: Press(.tap, at: at("10:00:00.9"))))
        // 1.2 seconds between the presses, though the audio is shorter than a second: kept.
        #expect(!RecordingPressRule.isAccidental(start: Self.tapAt10, stop: Press(.tap, at: at("10:00:01.2"))))
        #expect(!RecordingPressRule.isAccidental(start: Self.holdAt10, stop: Press(.holdRelease, at: at("10:00:00.3"))))
    }
}

@Suite struct HotkeyMachineTests {
    static let down = at("10:00:00")

    @Test func aTapNeverOpensTheMicrophone() {
        var (state, effects) = HotkeyMachine.reduce(.idle, .keyDown(at: Self.down))
        #expect(state == .pressed(since: Self.down))
        #expect(effects == [.prepareMicrophone])
        (state, effects) = HotkeyMachine.reduce(state, .keyUp(at: at("10:00:00.2")))
        #expect(state == .idle)
        #expect(effects == [.releaseMicrophone, .tap])
        // A timer that fires late after the release changes nothing.
        (state, effects) = HotkeyMachine.reduce(state, .markReached(at: at("10:00:00.25")))
        #expect(state == .idle)
        #expect(effects.isEmpty)
    }

    @Test func theMicrophoneOpensAtTheMarkOfAHold() {
        var (state, effects) = HotkeyMachine.reduce(.idle, .keyDown(at: Self.down))
        // A timer that fires early is ignored.
        (state, effects) = HotkeyMachine.reduce(state, .markReached(at: at("10:00:00.2")))
        #expect(state == .pressed(since: Self.down))
        #expect(effects.isEmpty)
        (state, effects) = HotkeyMachine.reduce(state, .markReached(at: at("10:00:00.25")))
        #expect(state == .holding(since: Self.down))
        #expect(effects == [.startHoldRecording])
        (state, effects) = HotkeyMachine.reduce(state, .keyUp(at: at("10:00:03")))
        #expect(state == .idle)
        #expect(effects == [.stopRecording])
    }

    @Test func aReleaseAtTheMarkIsNotATap() {
        let (state, effects) = HotkeyMachine.reduce(.pressed(since: Self.down), .keyUp(at: at("10:00:00.25")))
        #expect(state == .idle)
        #expect(effects == [.releaseMicrophone])
    }

    @Test(arguments: [HotkeyEvent.keyFoundUp, .escape, .keyDown(at: at("10:00:09"))])
    func aMissedReleaseIsStoppedByTheCheckEscOrAnotherPress(event: HotkeyEvent) {
        let (state, effects) = HotkeyMachine.reduce(.holding(since: Self.down), event)
        #expect(state == .idle)
        #expect(effects == [.stopRecording])
    }

    @Test func eventsThatMeanNothingChangeNothing() {
        #expect(HotkeyMachine.reduce(.idle, .keyUp(at: Self.down)) == (.idle, []))
        #expect(HotkeyMachine.reduce(.idle, .escape) == (.idle, []))
        #expect(HotkeyMachine.reduce(.idle, .keyFoundUp) == (.idle, []))
        #expect(HotkeyMachine.reduce(.pressed(since: Self.down), .escape) == (.idle, [.releaseMicrophone]))
        #expect(
            HotkeyMachine.reduce(.holding(since: Self.down), .markReached(at: Self.down)) == (
                .holding(since: Self.down), []
            ))
    }
}
