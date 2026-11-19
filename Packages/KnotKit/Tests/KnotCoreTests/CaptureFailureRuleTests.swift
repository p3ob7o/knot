import Foundation
import KnotCore
import Testing

/// The table of docs/product-spec.md §4.4.
enum CaptureFailureRuleCases {
    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let error: KnotError
        let kind: SegmentKind
        let moment: CaptureMoment
        let inboxWritable: Bool
        let expected: CaptureFailureResponse
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(
            name: "no microphone permission: the recording says why", error: .microphonePermissionRefused, kind: .voice,
            moment: .starting, inboxWritable: true, expected: .refuseToStart(.microphonePermissionRefused)),
        Row(
            name: "no microphone on a Mac Studio", error: .noInputDevice, kind: .voice, moment: .starting,
            inboxWritable: true, expected: .refuseToStart(.noInputDevice)),
        Row(
            name: "too little free space refuses a recording", error: .tooLittleSpace, kind: .voice, moment: .starting,
            inboxWritable: true, expected: .refuseToStart(.tooLittleSpace)),
        Row(
            name: "the disk fills while recording: stop cue, kept", error: .diskFull, kind: .voice, moment: .during,
            inboxWritable: false, expected: .stopKeepingWhatWasCaptured(.captureStoppedDiskFull)),
        Row(
            name: "the disk fills while drawing: stop cue, kept", error: .diskFull, kind: .ink, moment: .during,
            inboxWritable: false, expected: .stopKeepingWhatWasCaptured(.captureStoppedDiskFull)),
        Row(
            name: "a typed save fails: fallback file, failed, retried", error: .writeFailed, kind: .typed,
            moment: .saving, inboxWritable: true, expected: .fallBackAndRetry(.writeFailed)),
        Row(
            name: "typed text cannot be saved anywhere: the surface stays open", error: .diskFull, kind: .typed,
            moment: .saving, inboxWritable: false, expected: .keepSurfaceOpen(.diskFull)),
        Row(
            name: "the notes cannot open: capture goes on into Inbox", error: .storeDamaged, kind: .typed,
            moment: .saving, inboxWritable: true, expected: .continueIntoInbox),
        Row(
            name: "the store is newer than the build: a recording still starts", error: .storeNewerThanBuild,
            kind: .voice, moment: .starting, inboxWritable: true, expected: .continueIntoInbox),
        Row(
            name: "the store does not answer in time: the engine never waits", error: .storeNotOpen, kind: .typed,
            moment: .starting, inboxWritable: true, expected: .continueIntoInbox),
        Row(
            name: "no store and no Inbox: a recording cannot start", error: .storeNotOpen, kind: .voice,
            moment: .starting, inboxWritable: false, expected: .refuseToStart(.storeNotOpen)),
        Row(
            name: "no store and no Inbox: typed text stays on the surface", error: .storeBusy, kind: .typed,
            moment: .saving, inboxWritable: false, expected: .keepSurfaceOpen(.storeBusy)),
    ]
}

@Suite struct CaptureFailureRuleTests {
    @Test(arguments: CaptureFailureRuleCases.rows)
    func whatASurfaceDoesWhenACaptureCannotStartOrBeSaved(row: CaptureFailureRuleCases.Row) {
        #expect(
            CaptureFailureRule.response(
                to: row.error, kind: row.kind, moment: row.moment, inboxWritable: row.inboxWritable) == row.expected)
    }
}
