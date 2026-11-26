import Foundation
import KnotCore
import KnotTestSupport
import Testing

/// Why a recording ended, as it is kept (docs/plan/open-points.md, point 28): the open enum, its
/// two mappings to the recorder's closed ending, and where the contract keeps it.
@Suite struct RecordingEndReasonTests {
    /// The text of every reason, which the store, the manifests and the synced record hold.
    @Test func eachReasonHasItsText() {
        #expect(
            RecordingEndReason.allCases.map(\.rawValue) == [
                "limit_reached", "interrupted", "input_lost", "disk_full", "write_failed", "recovered",
            ])
        let newer = RecordingEndReason(rawValue: "thermal_shutdown")
        #expect(newer == .unknown("thermal_shutdown") && newer.isUnknown, "A newer build's reason is kept.")
        #expect(newer.rawValue == "thermal_shutdown", "And written back as it was.")
        #expect(RecordingEndReason.allCases.allSatisfy { !$0.isUnknown })
    }

    /// Every ending but `stopped` and `discarded` gives its reason, and the reason gives that
    /// ending back; a reason this build does not know names no ending.
    @Test(arguments: RecordingEnding.allCases)
    func anEndingGivesItsReasonAndBack(ending: RecordingEnding) {
        let reason = RecordingEndReason(ending)
        switch ending {
        case .stopped, .discarded:
            #expect(reason == nil, "\(ending) has no reason to give.")
        case .limitReached, .interrupted, .inputLost, .diskFull, .writeFailed, .recovered:
            #expect(reason?.rawValue == ending.rawValue, "The reason has the ending's text.")
            #expect(reason.flatMap(RecordingEnding.init) == ending, "The reason gives the ending back.")
        }
        #expect(RecordingEnding(RecordingEndReason.unknown("thermal_shutdown")) == nil)
    }

    /// Every reason this build knows is the reason of one ending.
    @Test func everyReasonIsAnEndings() {
        let given = Set(RecordingEnding.allCases.compactMap(RecordingEndReason.init))
        #expect(given == Set(RecordingEndReason.allCases))
    }

    /// `Segment.recordingEnding` is a field with a default: a segment built as before has none,
    /// one with it round-trips, a reason this build does not know among them, and a record
    /// without it decodes with none.
    @Test func aVoiceSegmentKeepsWhyItsRecordingEnded() throws {
        var voice = try Segment(
            id: id(1), noteID: id(2), kind: .voice, origin: fromDevice, startedAt: at("10:00"),
            endedAt: at("10:30"), textOrigin: .rawTranscript, state: .voice(.recorded))
        #expect(voice.recordingEnding == nil, "A segment built as before has none.")
        let without = try JSONEncoder().encode(voice)
        #expect(!String(decoding: without, as: UTF8.self).contains("recordingEnding"), "Absent when nil.")
        for reason in RecordingEndReason.allCases + [.unknown("thermal_shutdown")] {
            voice.recordingEnding = reason
            #expect(try JSONDecoder().decode(Segment.self, from: JSONEncoder().encode(voice)) == voice)
        }
        #expect(try JSONDecoder().decode(Segment.self, from: without).recordingEnding == nil)
    }

    /// `CaptureState` gains two values with defaults: a state built as before has neither, and
    /// one built with them keeps them.
    @Test func aCapturesStateCanSayWhyAndSinceWhen() {
        let before = CaptureState(
            captureID: id(1), kind: .voice, noteID: id(2), outcome: .open, path: .store, durableRevision: 16_000)
        #expect(before.recordingEnding == nil && before.liveSince == nil, "A state built as before has neither.")
        let live = CaptureState(
            captureID: id(1), kind: .voice, noteID: id(2), outcome: .open, path: .store, durableRevision: 16_000,
            liveSince: at("10:00"))
        #expect(live.liveSince == at("10:00") && live.recordingEnding == nil)
        let ended = CaptureState(
            captureID: id(1), kind: .voice, noteID: id(2), outcome: .stored, path: .store, durableRevision: 16_000,
            recordingEnding: .interrupted)
        #expect(ended.recordingEnding == .interrupted && ended.liveSince == nil)
        #expect(before != live && before != ended, "Each is part of the state.")
    }

    /// A store written before the operation answers it from the default: not there yet.
    @Test func aStoreWithoutTheOperationSaysItIsNotThere() async {
        let segment: SegmentID = id(1)
        await #expect(throws: KnotError.portUnavailable.with(.init(segmentID: segment))) {
            try await UnavailableNoteStore().setRecordingEnding(.limitReached, of: segment)
        }
    }
}
