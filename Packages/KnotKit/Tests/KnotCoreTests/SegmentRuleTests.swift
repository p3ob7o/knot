import Foundation
import KnotCore
import KnotTestSupport
import Testing

private let noteA: NoteID = id(201)

@Suite struct TextPiecesTests {
    @Test("text-past-size-limit-repeated-rule", .tags(.named))
    func textPastTheSizeLimitRepeated() {
        let capture: CaptureID = id(1)
        let line = "a line of typed text that runs on\n"
        let text = String(repeating: line, count: 20_000)
        #expect(text.utf8.count > 2 * Limits.segmentTextBytes)

        let first = TextPieces.pieces(of: text, capture: capture)
        let again = TextPieces.pieces(of: text, capture: capture)
        #expect(first == again, "A repeat gives the same pieces and the same IDs.")
        #expect(first.count == 3)
        #expect(first.map(\.text).joined() == text, "Nothing is cut.")
        #expect(first.allSatisfy { $0.text.utf8.count <= Limits.segmentTextBytes })
        #expect(first[0].segmentID == SegmentID(capture), "The first piece shares the capture's ID.")
        #expect(first.dropFirst().allSatisfy { $0.segmentID.isDerived })
        #expect(Set(first.map(\.segmentID)).count == first.count)
        #expect(first.dropLast().allSatisfy { $0.text.hasSuffix("\n") }, "A piece ends after a line break.")
        // Another capture with the same text gets other IDs.
        #expect(TextPieces.pieces(of: text, capture: id(2)).map(\.segmentID) != first.map(\.segmentID))
    }

    @Test func textWithinTheLimitIsOnePiece() {
        #expect(TextPieces.split("short") == ["short"])
        #expect(TextPieces.split("") == [""])
        let exact = String(repeating: "x", count: 64)
        #expect(TextPieces.split(exact, maxBytes: 64) == [exact])
    }

    @Test(arguments: [
        ("aaaa bbbb cccc", 10, ["aaaa bbbb ", "cccc"]),
        ("aaaa\nbbbb cccc", 12, ["aaaa\nbbbb ", "cccc"]),
        ("aaaaaa\nbb cccccc", 12, ["aaaaaa\n", "bb cccccc"]),
        ("abcdefghij", 4, ["abcd", "efgh", "ij"]),
        ("ab\ncdefghij", 4, ["ab\n", "cdef", "ghij"]),
        ("éééé", 5, ["éé", "éé"]),
        ("👩‍👩‍👧‍👦x", 25, ["👩‍👩‍👧‍👦", "x"]),
    ])
    func splitsAtABreakWithoutSplittingACharacter(text: String, limit: Int, expected: [String]) {
        let pieces = TextPieces.split(text, maxBytes: limit)
        #expect(pieces == expected)
        #expect(pieces.joined() == text)
    }

    @Test func aTitlePastItsBoundIsRefused() throws {
        try Limits.checkTitle(String(repeating: "t", count: 200))
        #expect(throws: KnotError.textTooLong) { try Limits.checkTitle(String(repeating: "t", count: 201)) }
    }
}

@Suite struct TitleRuleTests {
    @Test(arguments: [
        ("Fix the roof", true),
        ("fix THE roof", true),
        ("Roof, then stamps", true),
        ("Buy stamps", false),
        ("Fix the roof\nsoon", false),
        ("", false),
        ("   ", false),
        ("—", false),
        (String(repeating: "roof ", count: 12) + "roof", false),
        ("Call 3 people", true),
        ("Call three people", false),
    ])
    func aGeneratedTitleUsesOnlyWordsFromTheNote(title: String, fits: Bool) {
        let texts = ["We need to fix the roof, then call 3 people.", "Stamps, then the roof again."]
        #expect(TitleRule.fits(title, noteTexts: texts) == fits)
    }

    @Test func aTitleIsProposedOnlyWhenTheRecordingIsTheFirstSegment() {
        let recording = segment(1, note: noteA, kind: .voice, start: at("09:00"), end: at("09:01"))
        let typed = segment(2, note: noteA, start: at("08:59"), end: at("08:59:30"))
        let deletedTyped = segment(3, note: noteA, start: at("08:58"), end: at("08:58:30"), deleted: at("10:00"))
        #expect(TitleRule.mayPropose(for: recording.id, segmentsInOrder: [recording, typed], title: nil))
        #expect(!TitleRule.mayPropose(for: recording.id, segmentsInOrder: [typed, recording], title: nil))
        #expect(TitleRule.mayPropose(for: recording.id, segmentsInOrder: [deletedTyped, recording], title: nil))
        #expect(!TitleRule.mayPropose(for: recording.id, segmentsInOrder: [recording], title: "Typed"))
        #expect(!TitleRule.mayPropose(for: recording.id, segmentsInOrder: [], title: nil))
        #expect(!TitleRule.mayPropose(for: typed.id, segmentsInOrder: [typed, recording], title: nil))
    }

    @Test func titlesDoNotMoveWithASegment() {
        // A generated title that no longer fits is dropped, and a return puts it back.
        let left = TitleRule.afterSegmentLeaves(title: "Buy stamps", origin: .generated, remainingTexts: ["The roof"])
        #expect(left == TitleRule.AfterLeave(title: nil, titleOrigin: .none, dropped: "Buy stamps"))
        let back = TitleRule.afterReturn(title: left.title, origin: left.titleOrigin, dropped: left.dropped)
        #expect(back.0 == "Buy stamps")
        #expect(back.1 == .generated)

        // One that still fits stays.
        let kept = TitleRule.afterSegmentLeaves(title: "The roof", origin: .generated, remainingTexts: ["The roof"])
        #expect(kept == TitleRule.AfterLeave(title: "The roof", titleOrigin: .generated, dropped: nil))

        // A typed title is never touched.
        let typed = TitleRule.afterSegmentLeaves(title: "Buy stamps", origin: .user, remainingTexts: ["The roof"])
        #expect(typed == TitleRule.AfterLeave(title: "Buy stamps", titleOrigin: .user, dropped: nil))

        // A return does not replace a title the note gained since.
        let since = TitleRule.afterReturn(title: "New", origin: .user, dropped: "Buy stamps")
        #expect(since.0 == "New")
        #expect(since.1 == .user)
    }
}

@Suite struct TextPrecedenceTests {
    @Test(arguments: [
        // Edited beats cleaned beats raw.
        (TextOrigin.rawTranscript, TextOrigin.cleaned, true),
        (.cleaned, .rawTranscript, false),
        (.edited, .cleaned, false),
        (.edited, .rawTranscript, false),
        (.cleaned, .edited, true),
        (.rawTranscript, .edited, true),
        (.edited, .edited, true),
        // The transcript grows range by range; cleanup replaces the raw text once.
        (.rawTranscript, .rawTranscript, true),
        (.cleaned, .cleaned, false),
        // Typed text belongs to a person.
        (.typed, .cleaned, false),
        (.typed, .rawTranscript, false),
        (.typed, .typed, true),
        (.typed, .edited, true),
        (.recognised, .recognised, true),
        (.edited, .recognised, false),
        (.unknown("summarised"), .cleaned, false),
        (.cleaned, .unknown("summarised"), false),
    ])
    func whichTextMayReplaceWhich(current: TextOrigin, new: TextOrigin, allowed: Bool) {
        #expect(TextPrecedence.mayReplace(current, with: new) == allowed)
    }
}

@Suite struct SettledRuleTests {
    let note = Note(id: noteA, createdAt: at("09:00"), lastCaptureEndedAt: at("09:01"))

    @Test func aNoteSettlesWhenItsWindowCloses() {
        let ready = segment(1, note: noteA, start: at("09:00"), end: at("09:01"))
        #expect(
            SettledRule.evaluate(note: note, segments: [ready], window: .default, now: at("09:03"))
                == .unsettled(settlesAt: at("09:06")))
        #expect(SettledRule.evaluate(note: note, segments: [ready], window: .default, now: at("09:06")) == .settled)
        #expect(SettledRule.evaluate(note: note, segments: [ready], window: .off, now: at("09:01")) == .settled)
        var closed = note
        closed.closedAt = at("09:02")
        #expect(SettledRule.evaluate(note: closed, segments: [ready], window: .default, now: at("09:02")) == .settled)
    }

    @Test func pendingWorkKeepsANoteUnsettledWithNoTime() {
        let pending: [SegmentState] = [
            .typed(.draft), .voice(.recording), .voice(.recorded), .voice(.transcribing), .voice(.transcribed),
            .voice(.cleaning), .voice(.recovered), .ink(.drawing), .ink(.recognising),
        ]
        for state in pending {
            let busy = segment(2, note: noteA, kind: .voice, start: at("09:00"), end: at("09:01"), state: state)
            #expect(
                SettledRule.evaluate(note: note, segments: [busy], window: .default, now: at("12:00"))
                    == .unsettled(settlesAt: nil), "\(state)")
        }
        // A download in progress holds it too.
        var withAsset = segment(3, note: noteA, kind: .voice, start: at("09:00"), end: at("09:01"))
        withAsset.assetID = id(4)
        #expect(
            SettledRule.evaluate(
                note: note, segments: [withAsset], downloadingAssets: [id(4)], window: .default, now: at("12:00"))
                == .unsettled(settlesAt: nil))
        // A failed segment waits for a person, and a deleted one does not count.
        let failed = segment(
            5, note: noteA, kind: .voice, start: at("09:00"), end: at("09:01"),
            state: .voice(.failed(.transcribe, "transcription_failed")))
        let deletedBusy = segment(
            6, note: noteA, kind: .voice, start: at("09:00"), end: nil, state: .voice(.recording), deleted: at("09:30"))
        #expect(
            SettledRule.evaluate(note: note, segments: [failed, deletedBusy], window: .default, now: at("12:00"))
                == .settled)
    }
}

@Suite struct VisibleStateTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let state: SegmentState
        let owner: DeviceID?
        let text: String
        let expected: VisibleState?
        var testDescription: String {
            "\(state.rawValue) owner=\(owner == otherDevice ? "other" : "here") text=\(text.isEmpty ? "none" : "some")"
        }
    }

    static let rows: [Row] = [
        Row(state: .voice(.onWatch), owner: nil, text: "", expected: .savedOnWatch),
        Row(state: .voice(.recording), owner: thisDevice, text: "", expected: .savedTextOnItsWay),
        Row(state: .voice(.delivered), owner: thisDevice, text: "", expected: .savedTextOnItsWay),
        Row(state: .voice(.recorded), owner: thisDevice, text: "", expected: .savedTextOnItsWay),
        Row(state: .voice(.recorded), owner: nil, text: "", expected: .savedTextOnItsWay),
        Row(state: .voice(.transcribing), owner: thisDevice, text: "part", expected: .savedTextOnItsWay),
        Row(state: .voice(.recovered), owner: thisDevice, text: "", expected: .savedTextOnItsWay),
        Row(state: .voice(.recorded), owner: otherDevice, text: "", expected: .savedTextBeingMadeElsewhere),
        Row(state: .voice(.transcribing), owner: otherDevice, text: "", expected: .savedTextBeingMadeElsewhere),
        Row(state: .voice(.transcribed), owner: thisDevice, text: "raw", expected: .ready),
        Row(state: .voice(.cleaning), owner: otherDevice, text: "raw", expected: .ready),
        Row(state: .voice(.ready), owner: thisDevice, text: "clean", expected: .ready),
        Row(state: .voice(.ready), owner: thisDevice, text: "", expected: .keptNoText),
        Row(
            state: .voice(.failed(.transcribe, KnotError.transcriptionFailed.code)), owner: thisDevice, text: "",
            expected: .needsYou),
        Row(
            state: .voice(.failed(.clean, KnotError.writeFailed.code)), owner: thisDevice, text: "raw",
            expected: .needsYou),
        Row(
            state: .voice(.failed(.transcribe, KnotError.audioUnreadable.code)), owner: thisDevice, text: "",
            expected: .keptNoText),
        Row(state: .voice(.discarded), owner: thisDevice, text: "", expected: nil),
        Row(state: .typed(.ready), owner: nil, text: "line", expected: .ready),
        Row(state: .typed(.draft), owner: nil, text: "lin", expected: .ready),
        Row(state: .typed(.discarded), owner: nil, text: "", expected: nil),
        Row(state: .ink(.drawing), owner: nil, text: "", expected: .savedTextOnItsWay),
        Row(state: .ink(.recognising), owner: nil, text: "", expected: .savedTextOnItsWay),
        Row(state: .ink(.ready), owner: nil, text: "", expected: .ready),
        Row(state: .ink(.failed(KnotError.recognitionFailed.code)), owner: nil, text: "", expected: .needsYou),
        Row(state: .unknown("photo.developing"), owner: nil, text: "", expected: .madeByNewerKnot),
    ]

    @Test(arguments: rows) func theSixStatesAPersonSees(row: Row) {
        var voice = segment(
            1, note: noteA, kind: .voice, start: at("09:00"), end: at("09:01"), text: row.text, state: row.state,
            owner: row.owner)
        voice.kind = .voice
        #expect(VisibleState.of(voice, thisDevice: thisDevice) == row.expected)
    }

    @Test func theNamesAreThoseOfTheProductSpec() {
        #expect(
            VisibleState.allCases.map(\.name) == [
                "Saved on the Watch", "Saved, text on its way", "Saved, text being made elsewhere", "Ready",
                "Needs you",
                "Kept, no text", "Made by a newer Knot",
            ])
    }
}

@Suite struct OversizedCharacterTests {
    /// The letter a with 131,072 combining accents: one character of 262,145 bytes.
    static let giant = "a" + String(repeating: "\u{0301}", count: 131_072)

    @Test func aCharacterLargerThanTheLimitIsSplitAtScalarBoundaries() {
        #expect(Self.giant.count == 1)
        #expect(Self.giant.utf8.count == 262_145)
        let pieces = TextPieces.split(Self.giant)
        #expect(pieces.allSatisfy { $0.utf8.count <= Limits.segmentTextBytes })
        #expect(pieces.joined() == Self.giant, "Nothing is cut.")
        #expect(pieces.count == 2)
        let family = TextPieces.split("👩‍👩‍👧‍👦x", maxBytes: 4)
        #expect(family.allSatisfy { $0.utf8.count <= 4 })
        #expect(family.joined().unicodeScalars.elementsEqual("👩‍👩‍👧‍👦x".unicodeScalars))
        let small = TextPieces.split("x" + String(repeating: "\u{0301}", count: 5), maxBytes: 4)
        #expect(small.allSatisfy { $0.utf8.count <= 4 })
        #expect(
            small.joined().unicodeScalars.elementsEqual(("x" + String(repeating: "\u{0301}", count: 5)).unicodeScalars))
    }
}

@Suite struct TitleWordBoundaryTests {
    @Test(arguments: [
        ("can", ["can't"], false),
        ("can't", ["I can't stop"], true),
        ("Can’t stop", ["I can't stop"], true),
        ("東京", ["東京で会う"], true),
        ("京都", ["東京で会う"], false),
        ("会う", ["東京で会う"], true),
        ("3.5 litres", ["Buy 3.5 litres of paint"], true),
        ("3 litres", ["Buy 3.5 litres of paint"], false),
        ("e-mail Anna", ["Send an e-mail to Anna"], true),
    ])
    func wordsFollowUnicodeWordBoundaries(title: String, note: [String], fits: Bool) {
        #expect(TitleRule.fits(title, noteTexts: note) == fits)
    }
}

@Suite struct NewerKnotVisibleStateTests {
    @Test func aSegmentThisBuildCannotReadShowsAsMadeByANewerKnot() {
        let base = segment(1, note: id(9), kind: .voice, start: at("09:00"), end: at("09:01"))
        var unknownState = base
        unknownState.state = .unknown("voice.summarising")
        var unknownKind = base
        unknownKind.kind = .unknown("photo")
        var unknownOrigin = base
        unknownOrigin.origin = .unknown("car_play")
        var unknownText = base
        unknownText.textOrigin = .unknown("summarised")
        for segment in [unknownState, unknownKind, unknownOrigin, unknownText] {
            #expect(VisibleState.of(segment, thisDevice: thisDevice) == .madeByNewerKnot)
        }
        #expect(VisibleState.madeByNewerKnot.rawValue == "made_by_newer_knot")
        #expect(VisibleState.madeByNewerKnot.name == "Made by a newer Knot")
        #expect(VisibleState.allCases.contains(.madeByNewerKnot))
    }
}
