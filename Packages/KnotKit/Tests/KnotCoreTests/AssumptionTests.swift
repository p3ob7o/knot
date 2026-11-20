import Foundation
import KnotCore
import Testing

// The assumptions of docs/product-spec.md §16, which the owner answered on 2026-11-19, as
// tests. Each test carries its ID, and a costly one replays its worked example. The ones
// whose rule lives in a later part of the build are listed at the end, with where they are
// tested.

private let iPhoneNote: NoteID = id(301)
private let macNote: NoteID = id(302)
private let roofNote: NoteID = id(303)
private let stampsNote: NoteID = id(304)

private func capture(_ number: Int, _ note: NoteID, _ start: String, _ end: String?) -> PriorCapture {
    PriorCapture(segmentID: id(number), noteID: note, startedAt: at(start), endedAt: end.map(at))
}

@Suite struct AssumptionTests {
    @Test("A2: a late capture is placed by its timestamps, and notes are never regrouped")
    func a2() {
        // 09:58 a typed line on the iPhone, 10:00 a recording on the Watch away from the
        // phone, 10:02 a line on the Mac. The recording reaches the phone at 11:00.
        let known = [capture(1, iPhoneNote, "09:58", "09:58"), capture(2, macNote, "10:02", "10:02")]
        let late = AppendRequest(startedAt: at("10:00"), arrival: .late, source: fromDevice)
        #expect(
            AppendRule.decide(late, in: AppendContext(window: .default, captures: known))
                == .join(iPhoneNote, .insideWindow))
        // Had there been no 09:58 line, it would be its own note dated 10:00.
        #expect(
            AppendRule.decide(late, in: AppendContext(window: .default, captures: [known[1]]))
                == .newNote(.noEarlierCapture))
    }

    @Test("A3: notes made on two offline devices are not merged")
    func a3() {
        // On a flight, a line on the iPhone at 14:00 and one on the iPad at 14:02. Each
        // device applies the rule to what it knows, so each starts a note.
        let onIPhone = AppendRule.decide(
            AppendRequest(startedAt: at("14:00"), source: fromDevice), in: AppendContext(window: .default, captures: [])
        )
        let onIPad = AppendRule.decide(
            AppendRequest(startedAt: at("14:02"), source: .device(otherDevice)),
            in: AppendContext(window: .default, captures: []))
        #expect(onIPhone == .newNote(.noEarlierCapture))
        #expect(onIPad == .newNote(.noEarlierCapture))
    }

    @Test("A5: a recording stops after 30 minutes")
    func a5() {
        #expect(Limits.longestRecording == 30 * 60)
    }

    @Test("A7: deleted items stay recoverable for 30 days")
    func a7() {
        #expect(Limits.keptForDays == 30)
    }

    @Test("A10: a title is generated only when the note's first segment is a recording")
    func a10() {
        let typed = segment(1, note: roofNote, start: at("10:00"), end: at("10:00:10"))
        let voice = segment(2, note: roofNote, kind: .voice, start: at("10:01"), end: at("10:02"))
        #expect(!TitleRule.mayPropose(for: voice.id, segmentsInOrder: [typed, voice], title: nil))
        #expect(TitleRule.mayPropose(for: voice.id, segmentsInOrder: [voice, typed], title: nil))
    }

    @Test("A14: a tap stopped within one second of its tap is discarded; a hold is exempt")
    func a14() {
        let tap = Press(.tap, at: at("10:00"))
        #expect(RecordingPressRule.isAccidental(start: tap, stop: Press(.tap, at: at("10:00:00.99"))))
        #expect(!RecordingPressRule.isAccidental(start: tap, stop: Press(.tap, at: at("10:00:01"))))
        #expect(
            !RecordingPressRule.isAccidental(
                start: Press(.holdStart, at: at("10:00")), stop: Press(.holdRelease, at: at("10:00:00.5"))))
    }

    @Test("A15: stream order, late captures, emptied notes and recovered drafts follow rules 9 to 12")
    func a15() throws {
        // You edit yesterday's note, and it stays where it was. A watch recording from
        // yesterday that arrives today appears under yesterday's time.
        var yesterday = Note(id: roofNote, createdAt: at("09:00"), lastCaptureEndedAt: at("09:01"))
        let today = Note(id: stampsNote, createdAt: at("12:00"), lastCaptureEndedAt: at("12:01"))
        yesterday.updatedAt = at("13:00")
        let lateRecording = segment(5, note: roofNote, kind: .voice, start: at("09:02"), end: at("09:03"))
        yesterday.lastCaptureEndedAt = StreamRule.lastCaptureTime(
            of: [segment(4, note: roofNote, start: at("09:00"), end: at("09:01")), lateRecording],
            fallback: yesterday.lastCaptureEndedAt)
        #expect([yesterday, today].sorted(by: StreamRule.precedes).map(\.id) == [stampsNote, roofNote])
        // An emptied note is hidden, and a draft found after a crash becomes a finished segment.
        #expect(!StreamRule.isShown(today, segments: []))
        #expect(try TypedMachine.reduce(.draft, .recoverAtRelaunch(isEmpty: false)) == .ready)
    }

    @Test("A16: the microphone opens at the 250 ms mark of a hold, never on a tap")
    func a16() {
        let down = ContinuousClock.now
        let tap = HotkeyMachine.reduce(.pressed(since: down), .keyUp)
        #expect(!tap.1.contains(.startHoldRecording))
        let hold = HotkeyMachine.reduce(.pressed(since: down), .markReached(forKeyDownAt: down))
        #expect(hold.1 == [.startHoldRecording])
        #expect(HotkeyMachine.markDeadline(after: down) - down == .milliseconds(250))
    }

    @Test("A17: a typed capture starts at its first keystroke")
    func a17() {
        // You open the Mac panel at 10:00 and type at 10:07: a new note, because the capture
        // began at 10:07, more than five minutes after the previous one ended.
        let previous = [capture(1, roofNote, "09:59", "10:00")]
        let decision = AppendRule.decide(
            AppendRequest(startedAt: at("10:07"), source: fromDevice),
            in: AppendContext(window: .default, captures: previous))
        #expect(decision == .newNote(.outsideWindow))
        // Holding the hotkey while typing ends the typed capture and records into the same note.
        let open = OpenCapture(captureID: id(2), noteID: roofNote, kind: .typed, surface: .macPanel)
        let hold = CaptureStart(kind: .voice, origin: CaptureOrigin(source: fromDevice, surface: .macPanel))
        #expect(OpenCaptureRule.decide(open: open, start: hold) == .endOpenAndAppend(ended: id(2), note: roofNote))
    }

    @Test("A18: sync is on by default when the device is signed in to iCloud")
    func a18() {
        #expect(
            Settings.defaults.syncIsOn(signedInToICloud: true, gates: MilestoneGates(level: nil), syncAvailable: true))
    }

    @Test("A19: work made elsewhere shows as being made elsewhere")
    func a19() {
        // You record on the iPhone and close Knot. On the Mac the segment is pending and is
        // not transcribed there.
        let recording = segment(
            1, note: roofNote, kind: .voice, start: at("10:00"), end: at("10:01"), text: "", state: .voice(.recorded),
            owner: otherDevice)
        #expect(
            VisibleState.of(recording, thisDevice: thisDevice, speech: .ready)
                == .savedTextBeingMadeElsewhere)
        #expect(VisibleState.of(recording, thisDevice: otherDevice, speech: .ready) == .savedTextOnItsWay)
    }

    @Test("A20: edited beats cleaned beats raw")
    func a20() {
        // A recording is cleaned on the iPhone while you correct a word of its raw
        // transcript on the Mac. Your correction stays.
        #expect(!TextPrecedence.mayReplace(.edited, with: .cleaned))
        #expect(TextPrecedence.mayReplace(.rawTranscript, with: .cleaned))
        #expect(!TextPrecedence.mayReplace(.cleaned, with: .rawTranscript))
    }

    @Test("A22: the window, the cleanup switch and the English variant sync; the rest do not")
    func a22() {
        #expect(
            Set(SettingKey.allCases.filter { $0.scope == .synced }) == [
                .appendWindow, .cleanupEnabled, .englishVariant,
            ])
    }

    @Test("A23: the window ignores deleted captures, and a hotkey needs a modifier or a function key")
    func a23() {
        let captures = [
            capture(1, roofNote, "10:00", "10:01"),
            PriorCapture(
                segmentID: id(2), noteID: stampsNote, startedAt: at("10:02"), endedAt: at("10:03"), isDeleted: true),
        ]
        #expect(
            AppendRule.decide(
                AppendRequest(startedAt: at("10:05"), source: fromDevice),
                in: AppendContext(window: .default, captures: captures))
                == .join(roofNote, .insideWindow))
        #expect(throws: KnotError.hotkeyInvalid) {
            try Hotkey(keyCode: 0, modifiers: [], isFunctionKey: false, takenByAnotherApp: false)
        }
    }

    @Test(
        "A24: what Knot does when a capture cannot start or cannot be saved follows §4.4",
        arguments: CaptureFailureRuleCases.rows)
    func a24(row: CaptureFailureRuleCases.Row) {
        #expect(
            CaptureFailureRule.response(
                to: row.error, kind: row.kind, moment: row.moment, inboxWritable: row.inboxWritable) == row.expected)
    }

    @Test("A25: one capture is open at a time, and a running recording blocks typing and Pencil")
    func a25() {
        // You type in the capture surface and press the Action Button. The typed line is
        // saved as it stands, and the recording becomes the next segment of the same note.
        let typing = OpenCapture(captureID: id(1), noteID: roofNote, kind: .typed, surface: .app)
        let actionButton = CaptureStart(kind: .voice, origin: CaptureOrigin(source: fromDevice, surface: .control))
        #expect(
            OpenCaptureRule.decide(open: typing, start: actionButton) == .endOpenAndAppend(ended: id(1), note: roofNote)
        )
        // While the recording runs, the text field does not accept typing.
        let recording = OpenCapture(captureID: id(2), noteID: roofNote, kind: .voice, surface: .control)
        let typed = CaptureStart(kind: .typed, origin: CaptureOrigin(source: fromDevice, surface: .app))
        #expect(
            OpenCaptureRule.decide(open: recording, start: typed)
                == .refused(KnotError.captureBlockedByRecording.about(capture: id(2))))
    }

    @Test("A28: a finished drawing is not reopened")
    func a28() {
        // You sketch, end the capture, and draw again a minute later: the arrow is a second
        // sketch, because the first one refuses another stroke.
        #expect(throws: IllegalTransition(from: InkState.ready, event: InkEvent.stroke)) {
            try InkMachine.reduce(.ready, .stroke)
        }
        let decision = AppendRule.decide(
            AppendRequest(startedAt: at("10:02"), source: fromDevice),
            in: AppendContext(window: .default, captures: [capture(1, roofNote, "10:00", "10:01")]))
        #expect(decision == .join(roofNote, .insideWindow))
    }

    @Test("A31: a capture by an agent follows the window unless it asks for a new note")
    func a31() {
        let earlier = [capture(1, roofNote, "10:00", "10:01")]
        #expect(
            AppendRule.decide(
                AppendRequest(startedAt: at("10:03"), source: .mcp),
                in: AppendContext(window: .default, captures: earlier)) == .join(roofNote, .insideWindow))
        #expect(
            AppendRule.decide(
                AppendRequest(startedAt: at("10:03"), placement: .newNote, source: .cli),
                in: AppendContext(window: .default, captures: earlier)) == .newNote(.newNoteAsked))
    }

    @Test("A34: a note is settled when its window has closed and nothing is pending")
    func a34() {
        let note = Note(id: roofNote, createdAt: at("10:00"), lastCaptureEndedAt: at("10:01"))
        let ready = segment(1, note: roofNote, start: at("10:00"), end: at("10:01"))
        #expect(
            SettledRule.evaluate(
                note: note, segments: [ready], window: .default, now: at("10:06"), thisDevice: thisDevice,
                speech: .ready) == .settled)
        #expect(
            SettledRule.evaluate(
                note: note, segments: [ready], window: .default, now: at("10:05"), thisDevice: thisDevice,
                speech: .ready)
                == .unsettled(settlesAt: at("10:06")))
    }

    @Test("A35: a generated title uses only words from the note")
    func a35() {
        #expect(TitleRule.fits("Roof repair", noteTexts: ["The roof needs a repair."]))
        #expect(!TitleRule.fits("Roof fix", noteTexts: ["The roof needs a repair."]))
    }

    @Test("A37: a segment moved to its own note takes the window with it")
    func a37() {
        // 10:00 a recording about the roof; 10:03 "buy stamps" joins the same note. You move
        // that line to its own note, dated 10:03. At 10:05 you record again: it joins the
        // stamps note, because that line is now the most recent capture.
        let afterMove = [capture(1, roofNote, "10:00", "10:01"), capture(2, stampsNote, "10:03", "10:03")]
        let decision = AppendRule.decide(
            AppendRequest(startedAt: at("10:05"), source: fromDevice),
            in: AppendContext(window: .default, captures: afterMove))
        #expect(decision == .join(stampsNote, .insideWindow))
        // The roof note's generated title, if it named the stamps, is dropped.
        let left = TitleRule.afterSegmentLeaves(title: "Buy stamps", origin: .generated, remainingTexts: ["The roof"])
        #expect(left.title == nil)
    }

    /// Where the assumptions not tested here are tested: each belongs to the part of the
    /// build that carries its rule.
    static let testedElsewhere: [String: String] = [
        "A6": "the Watch app shows no note content (WP-32)",
        "A8": "Remove recording keeps the text (WP-02 PR 2, the NoteStore contract)",
        "A9": "both versions of a text edited on two devices are kept (WP-16)",
        "A12": "widgets never show note text (WP-31)",
        "A13": "the Mac's Dock icon (WP-33)",
        "A21": "a deleted note stays deleted, and a later segment moves to a new note (WP-16)",
        "A26": "notes removed from iCloud (WP-16)",
        "A27": "a selection does not cross segments (WP-21, WP-30, WP-33)",
        "A29": "the first-run stream (WP-21)",
        "A30": "the Mac's microphone control (WP-33)",
        "A32": "the change counter and revisions (WP-02 PR 2, the NoteStore contract)",
        "A33": "replaced text kept for 30 days (WP-02 PR 2, the NoteStore contract)",
        "A36": "one window on the iPad (WP-30)",
    ]

    @Test func everyAssumptionIsTestedHereOrNamedElsewhere() {
        let here = [
            "A2", "A3", "A5", "A7", "A10", "A14", "A15", "A16", "A17", "A18", "A19", "A20", "A22", "A23", "A24", "A25",
            "A28", "A31", "A34", "A35", "A37",
        ]
        let all = Set(here).union(Self.testedElsewhere.keys)
        // docs/product-spec.md §16 answers A2 to A37; A1, A4 and A11 became decisions earlier.
        let expected = Set((2...37).map { "A\($0)" }).subtracting(["A4", "A11"])
        #expect(all == expected)
        #expect(Set(here).isDisjoint(with: Self.testedElsewhere.keys))
    }
}
