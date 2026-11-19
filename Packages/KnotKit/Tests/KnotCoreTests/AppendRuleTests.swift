import Foundation
import KnotCore
import KnotTestSupport
import Testing

// The append rule of docs/product-spec.md §3, one table for each small rule, then tables
// for the whole rule. Times are on one day, and the window is five minutes unless a row
// says otherwise.

private let noteA: NoteID = id(101)
private let noteB: NoteID = id(102)
private let noteC: NoteID = id(103)
private let fiveMinutes = AppendWindow.default

private func prior(
    _ number: Int, _ note: NoteID, _ start: String, _ end: String?, deleted: Bool = false, copy: Bool = false,
    noteDeleted: String? = nil, noteClosed: String? = nil, noteEmpty: Bool = false
) -> PriorCapture {
    PriorCapture(
        segmentID: id(number), noteID: note, startedAt: at(start), endedAt: end.map(at), isDeleted: deleted,
        isConflictCopy: copy, noteDeletedAt: noteDeleted.map(at), noteClosedAt: noteClosed.map(at),
        noteHasLiveSegment: !noteEmpty)
}

private func request(
    _ start: String, _ placement: CapturePlacement = .window, _ arrival: Arrival = .live,
    source: SegmentOrigin = fromDevice
) -> AppendRequest {
    AppendRequest(startedAt: at(start), placement: placement, arrival: arrival, source: source)
}

/// One row of a table: what is asked, what the device knows, and what the rule must decide.
struct AppendRow: Sendable, CustomTestStringConvertible {
    let name: String
    let request: AppendRequest
    let context: AppendContext
    let expected: AppendDecision?

    init(
        _ name: String, _ request: AppendRequest, _ captures: [PriorCapture], open: PriorCapture? = nil,
        window: AppendWindow = fiveMinutes, namedDeleted: String? = nil, _ expected: AppendDecision?
    ) {
        self.name = name
        self.request = request
        self.context = AppendContext(
            window: window, captures: captures, openCapture: open, namedNoteDeletedAt: namedDeleted.map(at))
        self.expected = expected
    }

    var testDescription: String { name }
}

@Suite struct AppendRuleStepTests {
    static let namedNoteRows: [AppendRow] = [
        AppendRow(
            "rule 5: inside an open note, outside the window", request("12:00", .named(noteA)),
            [prior(1, noteB, "09:00", "09:01")], .join(noteA, .namedNote)),
        AppendRow(
            "rule 5: with appending off", request("12:00", .named(noteA)), [], window: .off, .join(noteA, .namedNote)),
        AppendRow(
            "a deleted note takes nothing", request("12:00", .named(noteA)), [], namedDeleted: "11:00",
            .refused(KnotError.noteDeleted.with(.init(noteID: noteA)))),
        AppendRow("following the window is not this rule's", request("12:00"), [], nil),
    ]

    @Test(arguments: namedNoteRows) func namedNote(row: AppendRow) {
        #expect(AppendRule.namedNote.decide(row.request, row.context) == row.expected)
    }

    static let newNoteAskedRows: [AppendRow] = [
        AppendRow(
            "rule 4: new note inside the window", request("09:02", .newNote), [prior(1, noteA, "09:00", "09:01")],
            .newNote(.newNoteAsked)),
        AppendRow(
            "following the window is not this rule's", request("09:02"), [prior(1, noteA, "09:00", "09:01")], nil),
    ]

    @Test(arguments: newNoteAskedRows) func newNoteAsked(row: AppendRow) {
        #expect(AppendRule.newNoteAsked.decide(row.request, row.context) == row.expected)
    }

    static let openCaptureRows: [AppendRow] = [
        AppendRow(
            "rule 15: a capture on this device joins the open capture's note", request("09:30"), [],
            open: prior(1, noteA, "09:00", nil), .join(noteA, .openCaptureOnDevice)),
        AppendRow(
            "rule 15: with appending off too", request("09:30"), [], open: prior(1, noteA, "09:00", nil), window: .off,
            .join(noteA, .openCaptureOnDevice)),
        AppendRow(
            "the command line does not end it", request("09:30", source: .cli), [], open: prior(1, noteA, "09:00", nil),
            nil),
        AppendRow("MCP does not end it", request("09:30", source: .mcp), [], open: prior(1, noteA, "09:00", nil), nil),
        AppendRow(
            "a late capture is placed by its timestamps", request("08:00", .window, .late), [],
            open: prior(1, noteA, "09:00", nil), nil),
        AppendRow("nothing open", request("09:30"), [prior(1, noteA, "09:00", "09:01")], nil),
    ]

    @Test(arguments: openCaptureRows) func openCaptureOnDevice(row: AppendRow) {
        #expect(AppendRule.openCaptureOnDevice.decide(row.request, row.context) == row.expected)
    }

    static let appendingOffRows: [AppendRow] = [
        AppendRow(
            "rule 2: zero turns appending off", request("09:01"), [prior(1, noteA, "09:00", "09:00:30")], window: .off,
            .newNote(.appendingOff)),
        AppendRow("a window of five minutes is on", request("09:01"), [prior(1, noteA, "09:00", "09:00:30")], nil),
    ]

    @Test(arguments: appendingOffRows) func appendingOff(row: AppendRow) {
        #expect(AppendRule.appendingOff.decide(row.request, row.context) == row.expected)
    }

    static let noEarlierCaptureRows: [AppendRow] = [
        AppendRow("rule 1: the first capture", request("09:00"), [], .newNote(.noEarlierCapture)),
        AppendRow(
            "rule 14: only deleted captures", request("09:02"), [prior(1, noteA, "09:00", "09:01", deleted: true)],
            .newNote(.noEarlierCapture)),
        AppendRow(
            "a conflict copy is not a capture", request("09:02"), [prior(1, noteA, "09:00", "09:01", copy: true)],
            .newNote(.noEarlierCapture)),
        AppendRow(
            "rule 7: a late capture with only later ones", request("08:00", .window, .late),
            [prior(1, noteA, "09:00", "09:01")], .newNote(.noEarlierCapture)),
        AppendRow("an earlier capture exists", request("09:02"), [prior(1, noteA, "09:00", "09:01")], nil),
    ]

    @Test(arguments: noEarlierCaptureRows) func noEarlierCapture(row: AppendRow) {
        #expect(AppendRule.noEarlierCapture.decide(row.request, row.context) == row.expected)
    }

    static let latestNoteDeletedRows: [AppendRow] = [
        AppendRow(
            "rule 14: the most recent note was deleted", request("09:02"),
            [prior(1, noteA, "09:00", "09:01", noteDeleted: "09:01:30")], .newNote(.latestNoteDeleted)),
        AppendRow(
            "rule 10: a late capture never joins a deleted note", request("09:00:30", .window, .late),
            [prior(1, noteA, "09:00", "09:00:10", noteDeleted: "09:30")], .newNote(.latestNoteDeleted)),
        AppendRow(
            "rule 14: the window passes over a deleted segment to a live note", request("09:04"),
            [prior(1, noteA, "09:00", "09:01"), prior(2, noteA, "09:02", "09:03", deleted: true)], nil),
    ]

    @Test(arguments: latestNoteDeletedRows) func latestNoteDeleted(row: AppendRow) {
        #expect(AppendRule.latestNoteDeleted.decide(row.request, row.context) == row.expected)
    }

    static let latestNoteClosedRows: [AppendRow] = [
        AppendRow(
            "rule 4: a note closed by New note takes no more", request("09:02"),
            [prior(1, noteA, "09:00", "09:01", noteClosed: "09:01:30")], .newNote(.latestNoteClosed)),
        AppendRow(
            "rule 10: a late capture recorded before the close may join", request("09:01:10", .window, .late),
            [prior(1, noteA, "09:00", "09:01", noteClosed: "09:01:30")], nil),
        AppendRow(
            "rule 10: a late capture recorded after the close may not", request("09:01:40", .window, .late),
            [prior(1, noteA, "09:00", "09:01", noteClosed: "09:01:30")], .newNote(.latestNoteClosed)),
        AppendRow("an open note", request("09:02"), [prior(1, noteA, "09:00", "09:01")], nil),
    ]

    @Test(arguments: latestNoteClosedRows) func latestNoteClosed(row: AppendRow) {
        #expect(AppendRule.latestNoteClosed.decide(row.request, row.context) == row.expected)
    }

    static let windowRows: [AppendRow] = [
        AppendRow(
            "rule 1: two minutes after", request("09:03"), [prior(1, noteA, "09:00", "09:01")],
            .join(noteA, .insideWindow)),
        AppendRow(
            "rule 1: just inside", request("09:05:59"), [prior(1, noteA, "09:00", "09:01")], .join(noteA, .insideWindow)
        ),
        AppendRow(
            "rule 1: exactly X minutes is outside", request("09:06"), [prior(1, noteA, "09:00", "09:01")],
            .newNote(.outsideWindow)),
        AppendRow(
            "rule 3: the gap runs from the end, so a long recording keeps its note", request("09:33"),
            [prior(1, noteA, "09:00", "09:30")], .join(noteA, .insideWindow)),
        AppendRow(
            "rule 3: an open capture is an open window", request("10:30", source: .cli), [],
            open: prior(1, noteA, "09:00", nil), .join(noteA, .insideWindow)),
        AppendRow(
            "rule 3: negative by less than X", request("08:57"), [prior(1, noteA, "08:58", "09:00")],
            .join(noteA, .insideWindow)),
        AppendRow(
            "rule 3: negative by exactly X", request("08:55"), [prior(1, noteA, "08:58", "09:00")],
            .newNote(.outsideWindow)),
        AppendRow(
            "rule 10: the receiving device's window applies to a late capture", request("09:03", .window, .late),
            [prior(1, noteA, "09:00", "09:01")], window: try! AppendWindow(minutes: 1), .newNote(.outsideWindow)),
    ]

    @Test(arguments: windowRows) func window(row: AppendRow) {
        #expect(AppendRule.window.decide(row.request, row.context) == row.expected)
    }

    @Test func theStepsRunInTheirOrder() {
        #expect(
            AppendRule.steps.map(\.name) == [
                "named-note", "new-note-asked", "open-capture-on-device", "appending-off", "no-earlier-capture",
                "latest-note-deleted", "latest-note-closed", "window",
            ])
    }
}

@Suite struct AppendRuleTests {
    static let wholeRuleRows: [AppendRow] = [
        // Rule 1 and docs/product-spec.md §16, A17: opening the panel did not count.
        AppendRow(
            "A17: the panel opened at 10:00 and the first keystroke came at 10:07", request("10:07"),
            [prior(1, noteA, "09:59", "10:00")], .newNote(.outsideWindow)),
        // Rule 6: modes mix.
        AppendRow(
            "rule 6: a recording after a typed line", request("09:02"), [prior(1, noteA, "09:00", "09:01")],
            .join(noteA, .insideWindow)),
        // Rule 7 and A2.
        AppendRow(
            "A2: the watch recording joins the 09:58 note, not the 10:02 one", request("10:00", .window, .late),
            [prior(1, noteA, "09:58", "09:58"), prior(2, noteB, "10:02", "10:02")], .join(noteA, .insideWindow)),
        AppendRow(
            "A2: with no 09:58 line it is its own note, dated 10:00", request("10:00", .window, .late),
            [prior(2, noteB, "10:02", "10:02")], .newNote(.noEarlierCapture)),
        AppendRow(
            "rule 7: a late capture far from any other", request("07:00", .window, .late),
            [prior(1, noteA, "06:00", "06:01"), prior(2, noteB, "10:02", "10:02")], .newNote(.outsideWindow)),
        // Rule 9: placing a capture never depends on edits.
        AppendRow(
            "rule 9: an edited old note is not the most recent capture", request("12:00"),
            [prior(1, noteA, "09:00", "09:01"), prior(2, noteB, "11:58", "11:59")], .join(noteB, .insideWindow)),
        // Rule 10.
        AppendRow(
            "rule 10: a late capture never joins a deleted note", request("09:02", .window, .late),
            [prior(1, noteA, "09:00", "09:01", noteDeleted: "09:30")], .newNote(.latestNoteDeleted)),
        AppendRow(
            "rule 10: a late capture joins a closed note it predates", request("09:01:10", .window, .late),
            [prior(1, noteA, "09:00", "09:01", noteClosed: "09:01:30")], .join(noteA, .insideWindow)),
        // Rule 11: a note with no segments left is treated as deleted: no live capture is in it.
        AppendRow(
            "rule 11: an emptied note takes nothing", request("09:02"),
            [prior(1, noteA, "09:00", "09:01", deleted: true)], .newNote(.noEarlierCapture)),
        // Rule 13: the typed capture starts at its first keystroke.
        AppendRow(
            "rule 13: the destination is fixed at the first keystroke", request("09:05:30"),
            [prior(1, noteA, "09:00", "09:01")], .join(noteA, .insideWindow)),
        // Rule 14.
        // The orchestrator's ruling on rules 11 and 14: the most recent note is the note of
        // the most recent capture, deleted captures counted.
        AppendRow(
            "rule 14: B's only segment is deleted, so the most recent note counts as deleted",
            request("09:05"),
            [prior(1, noteA, "09:00", "09:01"), prior(2, noteB, "09:02", "09:03", deleted: true, noteEmpty: true)],
            .newNote(.latestNoteDeleted)),
        AppendRow(
            "rule 14: a deleted capture in a note that keeps a live segment elsewhere", request("09:05"),
            [prior(1, noteA, "09:00", "09:01"), prior(2, noteB, "09:02", "09:03", deleted: true)],
            .join(noteA, .insideWindow)),
        AppendRow(
            "rule 14: N keeps n1 when n2 is deleted, and the capture joins N through n1", request("09:03"),
            [prior(1, noteA, "09:00", "09:00"), prior(2, noteA, "09:02", "09:02", deleted: true)],
            .join(noteA, .insideWindow)),
        AppendRow(
            "rule 14: the most recent note was deleted", request("09:04"),
            [prior(1, noteA, "09:00", "09:01"), prior(2, noteB, "09:02", "09:03", noteDeleted: "09:03:30")],
            .newNote(.latestNoteDeleted)),
        // Rule 15.
        AppendRow(
            "rule 15: the command line may ask for a new note while a capture is open",
            request("09:10", .newNote, source: .cli), [], open: prior(1, noteA, "09:00", nil), .newNote(.newNoteAsked)),
        AppendRow(
            "rule 15: with appending off, the command line starts its own note", request("09:10", source: .mcp), [],
            open: prior(1, noteA, "09:00", nil), window: .off, .newNote(.appendingOff)),
    ]

    @Test(arguments: wholeRuleRows) func wholeRule(row: AppendRow) {
        #expect(AppendRule.decide(row.request, in: row.context) == row.expected)
    }

    /// Rule 7 for a late capture, read with rule 3: a capture still running when the late one
    /// started keeps its note open (the orchestrator's ruling on pull request 22).
    static let lateCaptureRows: [AppendRow] = [
        AppendRow(
            "B records from 09:58 to 10:20; a Watch capture made at 10:00 joins B's note",
            request("10:00", .window, .late), [prior(1, noteB, "09:58", "10:20")], .join(noteB, .insideWindow)),
        AppendRow(
            "a capture still open when the late one started", request("10:00", .window, .late),
            [prior(1, noteB, "09:58", nil)], .join(noteB, .insideWindow)),
        AppendRow(
            "of two running, the one that started last", request("10:00", .window, .late),
            [prior(1, noteA, "09:50", "10:30"), prior(2, noteB, "09:58", "10:20")], .join(noteB, .insideWindow)),
        AppendRow(
            "a running capture wins over one that ended since it began", request("10:00", .window, .late),
            [prior(1, noteB, "09:40", "10:20"), prior(2, noteC, "09:55", "09:59")], .join(noteB, .insideWindow)),
        AppendRow(
            "a capture that ends exactly at the start is not running, and its gap is zero",
            request("10:00", .window, .late), [prior(1, noteB, "09:58", "10:00")], .join(noteB, .insideWindow)),
        AppendRow(
            "none running: the latest end, inside the window", request("10:00", .window, .late),
            [prior(1, noteA, "09:50", "09:58"), prior(2, noteC, "09:40", "09:59")], .join(noteC, .insideWindow)),
        AppendRow(
            "none running: the latest end, outside the window", request("10:00", .window, .late),
            [prior(1, noteA, "09:00", "09:30")], .newNote(.outsideWindow)),
        AppendRow(
            "a capture that started at the same instant is not earlier", request("10:00", .window, .late),
            [prior(1, noteB, "10:00", "10:20")], .newNote(.noEarlierCapture)),
        AppendRow(
            "rule 10: the running capture's note was closed before the late one started",
            request("10:00", .window, .late), [prior(1, noteB, "09:58", "10:20", noteClosed: "09:59")],
            .newNote(.latestNoteClosed)),
        AppendRow(
            "rule 10: the running capture's note was closed after the late one started",
            request("10:00", .window, .late), [prior(1, noteB, "09:58", "10:20", noteClosed: "10:05")],
            .join(noteB, .insideWindow)),
        AppendRow(
            "rule 10: the running capture's note is deleted", request("10:00", .window, .late),
            [prior(1, noteB, "09:58", "10:20", noteDeleted: "11:00")], .newNote(.latestNoteDeleted)),
        AppendRow(
            "a live capture keeps the negative gap of rule 3", request("09:40"),
            [prior(1, noteB, "09:58", "10:20")], .newNote(.outsideWindow)),
        // The wording of rule 7 in pull request 27.
        AppendRow(
            "with the window at zero a late capture is its own note, beside a running capture",
            request("10:00", .window, .late), [prior(1, noteB, "09:58", "10:20")], window: .off,
            .newNote(.appendingOff)),
        AppendRow(
            "two captures running in different notes: the one that started last decides",
            request("10:00", .window, .late),
            [
                prior(1, noteB, "09:59", "10:20"), prior(2, noteA, "09:58", "10:30"),
                prior(3, noteC, "09:50", "09:59:30"),
            ],
            .join(noteB, .insideWindow)),
        AppendRow(
            "the running capture's note is deleted: a new note, and no other candidate is tried",
            request("10:00", .window, .late),
            [prior(1, noteA, "09:50", "09:58"), prior(2, noteB, "09:58", "10:20", noteDeleted: "10:30")],
            .newNote(.latestNoteDeleted)),
        AppendRow(
            "the running capture's note was closed before: a new note, and no other candidate is tried",
            request("10:00", .window, .late),
            [prior(1, noteA, "09:50", "09:58"), prior(2, noteB, "09:58", "10:20", noteClosed: "09:59")],
            .newNote(.latestNoteClosed)),
        AppendRow(
            "the capture that ended last has a deleted note: a new note, no fallback to an older one",
            request("10:00", .window, .late),
            [prior(1, noteA, "09:55", "09:57"), prior(2, noteC, "09:56", "09:59", noteDeleted: "10:30")],
            .newNote(.latestNoteDeleted)),
        AppendRow(
            "the capture that ended last has a note closed before: a new note, no fallback",
            request("10:00", .window, .late),
            [prior(1, noteA, "09:55", "09:57"), prior(2, noteC, "09:56", "09:59", noteClosed: "09:59:30")],
            .newNote(.latestNoteClosed)),
        AppendRow(
            "the capture that ended last is outside the window: Knot looks no further back",
            request("10:00", .window, .late),
            [prior(1, noteA, "09:30", "09:58"), prior(2, noteC, "09:20", "09:50")],
            window: try! AppendWindow(minutes: 1),
            .newNote(.outsideWindow)),
    ]

    @Test(arguments: lateCaptureRows) func lateCapture(row: AppendRow) {
        #expect(AppendRule.decide(row.request, in: row.context) == row.expected)
    }

    static let ruleSixteenRows: [AppendRow] = [
        // docs/product-spec.md §16, A37: the roof note R, the stamps line moved out to note S.
        AppendRow(
            "the recording at 10:05 joins the stamps note", request("10:05"),
            [prior(1, noteA, "10:00", "10:01"), prior(2, noteC, "10:03", "10:03:10")], .join(noteC, .insideWindow)),
        AppendRow(
            "before the move it would have joined the roof note", request("10:05"),
            [prior(1, noteA, "10:00", "10:01"), prior(2, noteA, "10:03", "10:03:10")], .join(noteA, .insideWindow)),
        AppendRow(
            "a move does not reset the window", request("10:09"),
            [prior(1, noteA, "10:00", "10:01"), prior(2, noteC, "10:03", "10:03:10")], .newNote(.outsideWindow)),
        AppendRow(
            "New note still starts afresh", request("10:05", .newNote),
            [prior(1, noteA, "10:00", "10:01"), prior(2, noteC, "10:03", "10:03:10")], .newNote(.newNoteAsked)),
        AppendRow(
            "a late capture made just after the moved one joins its new note", request("10:04", .window, .late),
            [
                prior(1, noteA, "10:00", "10:01"), prior(2, noteC, "10:03", "10:03:10"),
                prior(3, noteA, "10:06", "10:07"),
            ], .join(noteC, .insideWindow)),
    ]

    @Test("rule-sixteen-capture-inside-window-of-moved-segment", .tags(.named), arguments: ruleSixteenRows)
    func ruleSixteen(row: AppendRow) {
        #expect(AppendRule.decide(row.request, in: row.context) == row.expected)
    }

    static let negativeGapsRows: [AppendRow] = [
        AppendRow(
            "negative by one minute", request("09:59"), [prior(1, noteA, "09:58", "10:00")], .join(noteA, .insideWindow)
        ),
        AppendRow(
            "negative by 4:59", request("09:55:01"), [prior(1, noteA, "09:50", "10:00")], .join(noteA, .insideWindow)),
        AppendRow(
            "negative by exactly five minutes", request("09:55"), [prior(1, noteA, "09:50", "10:00")],
            .newNote(.outsideWindow)),
        AppendRow(
            "negative by six minutes", request("09:54"), [prior(1, noteA, "09:50", "10:00")], .newNote(.outsideWindow)),
        AppendRow(
            "negative by an hour", request("09:00"), [prior(1, noteA, "09:50", "10:00")], .newNote(.outsideWindow)),
        AppendRow(
            "a one-minute window: negative by 59 seconds", request("09:59:01"), [prior(1, noteA, "09:50", "10:00")],
            window: try! AppendWindow(minutes: 1), .join(noteA, .insideWindow)),
    ]

    @Test("negative-gap-less-than-window-counts-inside", .tags(.named), arguments: negativeGapsRows)
    func negativeGap(row: AppendRow) {
        #expect(AppendRule.decide(row.request, in: row.context) == row.expected)
    }
}

@Suite struct OpenCaptureRuleTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let open: OpenCapture?
        let start: CaptureStart
        let expected: OpenCaptureDecision
        var testDescription: String { name }
    }

    static func open(_ kind: SegmentKind, _ surface: CaptureSurface) -> OpenCapture {
        OpenCapture(captureID: id(1), noteID: noteA, kind: kind, surface: surface)
    }

    static func start(_ kind: SegmentKind, _ surface: CaptureSurface, source: SegmentOrigin = fromDevice)
        -> CaptureStart
    {
        CaptureStart(kind: kind, origin: CaptureOrigin(source: source, surface: surface))
    }

    static let ends = OpenCaptureDecision.endOpenAndAppend(ended: id(1), note: noteA)

    static let rows: [Row] = [
        Row(
            name: "typed in the app, then typed in the Mac panel", open: open(.typed, .app),
            start: start(.typed, .macPanel), expected: ends),
        Row(
            name: "typed in the Mac window, then typed in the panel", open: open(.typed, .macWindow),
            start: start(.typed, .macPanel), expected: ends),
        Row(
            name: "typed, then the Pencil on the same surface", open: open(.typed, .app), start: start(.ink, .app),
            expected: ends),
        Row(
            name: "drawing, then typing on the same surface", open: open(.ink, .app), start: start(.typed, .app),
            expected: ends),
        Row(
            name: "A25: typing, then the Action Button", open: open(.typed, .app), start: start(.voice, .control),
            expected: ends),
        Row(
            name: "rule 13: typing in the panel, then the hotkey held", open: open(.typed, .macPanel),
            start: start(.voice, .macPanel), expected: ends),
        Row(
            name: "drawing, then a recording from Siri", open: open(.ink, .app), start: start(.voice, .intent),
            expected: ends),
        Row(
            name: "drawing in the app, then drawing from the Sketch control", open: open(.ink, .app),
            start: start(.ink, .control), expected: ends),
        // The exception: while a recording runs, no surface of the device takes typing or Pencil.
        Row(
            name: "a recording in the app, then typing on the same surface", open: open(.voice, .app),
            start: start(.typed, .app), expected: .refused(blocked)),
        Row(
            name: "a recording from a control, then typing in the app", open: open(.voice, .control),
            start: start(.typed, .app), expected: .refused(blocked)),
        Row(
            name: "a recording in the app, then the Pencil on the same surface", open: open(.voice, .app),
            start: start(.ink, .app), expected: .refused(blocked)),
        Row(
            name: "a hold in the Mac panel, then typing in the Mac window", open: open(.voice, .macPanel),
            start: start(.typed, .macWindow), expected: .refused(blocked)),
        // Text from the command line does not end an open capture.
        Row(
            name: "typing in the app, then text from the command line", open: open(.typed, .app),
            start: start(.typed, .commandLine, source: .cli), expected: .leaveOpen(id(1))),
        Row(
            name: "a recording, then text from MCP", open: open(.voice, .app), start: start(.typed, .mcp, source: .mcp),
            expected: .leaveOpen(id(1))),
    ]

    static let blocked = KnotError.captureBlockedByRecording.about(capture: id(1))

    @Test("capture-on-another-surface-ends-open-one", .tags(.named), arguments: rows)
    func anotherSurfaceOrKindEndsTheOpenOne(row: Row) {
        #expect(OpenCaptureRule.decide(open: row.open, start: row.start) == row.expected)
        let decision = AppendRule.decide(
            AppendRequest(startedAt: at("12:00"), source: row.start.origin.source),
            in: AppendContext(window: .off, captures: [], openCapture: prior(1, noteA, "09:00", nil)))
        switch row.expected {
        case .endOpenAndAppend:
            // The new capture is the next segment of the same note, whatever the window says.
            #expect(decision == .join(noteA, .openCaptureOnDevice))
        case .leaveOpen:
            // Placed by the window like any capture: with appending off, a note of its own.
            #expect(decision == .newNote(.appendingOff))
        default:
            break
        }
    }

    static let otherRows: [Row] = [
        Row(name: "nothing open", open: nil, start: start(.typed, .app), expected: .nothingOpen),
        Row(
            name: "the same kind on the same surface goes on", open: open(.typed, .app), start: start(.typed, .app),
            expected: .continueOpen(id(1))),
        Row(
            name: "a recording blocks typing", open: open(.voice, .app), start: start(.typed, .app),
            expected: .refused(KnotError.captureBlockedByRecording.about(capture: id(1)))),
        Row(
            name: "a recording blocks the Pencil", open: open(.voice, .control), start: start(.ink, .app),
            expected: .refused(KnotError.captureBlockedByRecording.about(capture: id(1)))),
        Row(
            name: "a record press while recording is the recorder's", open: open(.voice, .app),
            start: start(.voice, .control), expected: .recordingPress(id(1))),
        Row(
            name: "the command line leaves it open", open: open(.typed, .app),
            start: start(.typed, .commandLine, source: .cli), expected: .leaveOpen(id(1))),
        Row(
            name: "MCP leaves a recording open", open: open(.voice, .app), start: start(.typed, .mcp, source: .mcp),
            expected: .leaveOpen(id(1))),
    ]

    @Test(arguments: otherRows) func otherCases(row: Row) {
        #expect(OpenCaptureRule.decide(open: row.open, start: row.start) == row.expected)
    }
}

@Suite struct CaptureTextTests {
    @Test(
        "text-only-spaces-and-line-breaks-is-empty", .tags(.named),
        arguments: [
            ("", true), (" ", true), ("   ", true), ("\n", true), ("\r\n", true), (" \n \n ", true),
            ("\t", true), ("\u{00A0}", true), ("\u{2028}", true), ("\u{3000}", true),
            ("a", false), (" a ", false), ("\n.\n", false), ("\u{200B}", false), ("-", false),
        ])
    func textOnlySpacesAndLineBreaksIsEmpty(text: String, empty: Bool) {
        #expect(CaptureText.isEmpty(text) == empty)
    }
}

@Suite struct StreamRuleTests {
    @Test func theStreamIsOrderedByEachNotesLatestCapture() {
        let older = Note(id: noteA, createdAt: at("09:00"), lastCaptureEndedAt: at("09:01"))
        var edited = older
        edited.updatedAt = at("12:00")
        let newer = Note(id: noteB, createdAt: at("10:00"), lastCaptureEndedAt: at("10:01"))
        let tie = Note(id: noteC, createdAt: at("10:00"), lastCaptureEndedAt: at("10:01"))
        #expect([older, newer].sorted(by: StreamRule.precedes).map(\.id) == [noteB, noteA])
        // Rule 9: editing a note does not move it.
        #expect([edited, newer].sorted(by: StreamRule.precedes).map(\.id) == [noteB, noteA])
        #expect([newer, tie].sorted(by: StreamRule.precedes).map(\.id) == [noteC, noteB])
    }

    @Test func aLateCaptureSortsByItsOwnTime() {
        // A15: a watch recording from yesterday that arrives today sorts under yesterday.
        let segments = [
            segment(1, note: noteA, start: at("09:00"), end: at("09:01")),
            segment(2, note: noteA, kind: .voice, start: at("09:03"), end: at("09:04")),
            segment(3, note: noteA, start: at("09:10"), end: at("09:11"), deleted: at("12:00")),
            segment(4, note: noteA, start: at("09:20"), end: at("09:21"), conflictOf: id(1)),
        ]
        #expect(StreamRule.lastCaptureTime(of: segments, fallback: at("08:00")) == at("09:04"))
        #expect(StreamRule.lastCaptureTime(of: [], fallback: at("08:00")) == at("08:00"))
        let open = segment(5, note: noteA, start: at("09:30"), end: nil)
        #expect(StreamRule.lastCaptureTime(of: segments + [open], fallback: at("08:00")) == at("09:30"))
    }

    @Test func rule11ANoteWithNoSegmentsIsHidden() {
        let note = Note(id: noteA, createdAt: at("09:00"))
        let live = segment(1, note: noteA, start: at("09:00"), end: at("09:01"))
        let gone = segment(2, note: noteA, start: at("09:00"), end: at("09:01"), deleted: at("10:00"))
        #expect(StreamRule.isShown(note, segments: [live, gone]))
        #expect(!StreamRule.isShown(note, segments: [gone]))
        #expect(!StreamRule.isShown(note, segments: []))
        var deleted = note
        deleted.deletedAt = at("11:00")
        #expect(!StreamRule.isShown(deleted, segments: [live]))
        // Hidden is not deleted: the note itself is never marked.
        #expect(note.deletedAt == nil)
    }
}
