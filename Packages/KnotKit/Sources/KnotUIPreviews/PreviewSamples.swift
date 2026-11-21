#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import KnotFakes
    import KnotUI

    /// Synthetic segments and rows in each state, for the previews of the components. They are
    /// values, built from KnotFakes' builders: no preview of a component touches a store.
    public enum PreviewSamples {
        static let clock = FakeClock()
        static let ids = SeededIDGenerator(seed: 2101, clock: clock)
        static let device: DeviceID = ids.make()
        static let elsewhere: DeviceID = ids.make()
        static let noteID: NoteID = ids.make()

        /// A voice segment in each of the six states, in the order of docs/product-spec.md §5.
        public static let voiceStates: [SegmentItem] = {
            let start = clock.now()
            func voice(_ state: SegmentState, text: String, owner: DeviceID = device) -> Segment? {
                guard
                    var segment = try? Build.voice(ids.make(), in: noteID, from: start, transcript: text, device: owner)
                else { return nil }
                segment.state = state
                segment.duration = .seconds(42)
                return segment
            }
            let segments = [
                voice(.voice(.onWatch), text: ""),
                voice(.voice(.recorded), text: ""),
                voice(.voice(.recorded), text: "", owner: elsewhere),
                voice(.voice(.ready), text: "Call the roofer about the leak."),
                voice(.voice(.failed(.transcribe, KnotError.transcriptionFailed.code)), text: ""),
                voice(.voice(.ready), text: ""),
            ]
            return segments.compactMap { segment in
                guard let segment else { return nil }
                let record = NoteRecord(
                    note: Build.note(noteID, at: start), segments: [segment], storeID: ids.make(), generation: 0)
                return SegmentPresenter.items(for: record, assets: [:], thisDevice: device, speech: .ready).first
            }
        }()

        /// A typed segment written by an agent through MCP, with its quiet mark.
        public static let fromAnAgent: SegmentItem = SegmentItem(
            id: ids.make(), kind: .typed, text: "Summary of the call, added by an assistant.", rawTranscript: nil,
            state: .ready, attachment: .none, duration: nil, originMark: .mcp, isConflictCopy: false,
            hasArrived: false, actions: [.moveToOwnNote, .delete])

        /// A recording purged after a restored copy was made: missing, never a broken player.
        public static let missingRecording: SegmentItem = SegmentItem(
            id: ids.make(), kind: .voice, text: "Text kept from before the restore.", rawTranscript: nil,
            state: .ready, attachment: .missing, duration: .seconds(12), originMark: nil, isConflictCopy: false,
            hasArrived: false, actions: [.delete])

        /// A segment made by a newer Knot: it says so and offers nothing else.
        public static let newerKnot: SegmentItem = SegmentItem(
            id: ids.make(), kind: .typed, text: "", rawTranscript: nil, state: .madeByNewerKnot, attachment: .none,
            duration: nil, originMark: nil, isConflictCopy: false, hasArrived: false, actions: [])

        /// A stream row with every part: pending, failed and arrived.
        public static let busyRow = StreamRowModel(
            id: ids.make(), title: "Call the roofer about the leak", preview: "Ask for Thursday",
            kinds: [.typed, .voice], time: clock.now(), hasPending: true, hasFailed: true, hasArrived: true)

        /// A row for a note that holds only a recording with no text yet.
        public static let recordingOnlyRow = StreamRowModel(
            id: ids.make(), title: "Recording, 0:42", preview: nil, kinds: [.voice], time: clock.now(),
            hasPending: true, hasFailed: false, hasArrived: false)

        /// Peaks for the waveform.
        public static let levels: [Float] = (0..<48).map { index in
            Float(0.2 + 0.7 * abs(sin(Double(index) / 4)))
        }
    }
#endif
