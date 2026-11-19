#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore

    /// Builders of notes and segments for tests, previews and seeded stores
    /// (docs/architecture.md §3). Every value they make is synthetic.
    public enum Build {
        /// A note whose latest capture ended at `at`.
        public static func note(
            _ id: NoteID, at date: Date, title: String? = nil, titleOrigin: TitleOrigin = .none, revision: Int64 = 1
        ) -> Note {
            // A title the builder is given is short and synthetic, so it is within its bound.
            (try? Note(
                id: id, createdAt: date, title: title, titleOrigin: title == nil ? .none : titleOrigin,
                lastCaptureEndedAt: date, revision: revision))
                ?? Note(id: id, createdAt: date, lastCaptureEndedAt: date, revision: revision)
        }

        /// A finished typed segment.
        public static func typed(
            _ id: SegmentID, in note: NoteID, from start: Date, to end: Date? = nil, text: String,
            origin: SegmentOrigin
        ) throws(KnotError) -> Segment {
            try Segment(
                id: id, noteID: note, kind: .typed, origin: origin, startedAt: start,
                endedAt: end ?? start.addingTimeInterval(10), text: text, textOrigin: .typed, state: .typed(.ready),
                revision: 1)
        }

        /// A voice segment whose text is its raw transcript, ready.
        public static func voice(
            _ id: SegmentID, in note: NoteID, from start: Date, to end: Date? = nil, transcript: String,
            device: DeviceID
        ) throws(KnotError) -> Segment {
            try Segment(
                id: id, noteID: note, kind: .voice, origin: .device(device), startedAt: start,
                endedAt: end ?? start.addingTimeInterval(30), text: transcript, textOrigin: .rawTranscript,
                rawTranscript: transcript, processingOwner: device, state: .voice(.ready), revision: 1)
        }

        /// The conflict copy sync makes when a segment's text changed on two devices: text
        /// only, in the note of the segment it copies (docs/architecture.md §11).
        public static func conflictCopy(
            of segment: Segment, losingDevice: DeviceID, text: String
        ) throws(KnotError) -> Segment {
            try Segment(
                id: .conflictCopy(of: segment.id, losingDevice: losingDevice, losingRevision: segment.revision),
                noteID: segment.noteID, kind: .typed, noteGeneration: segment.noteGeneration,
                origin: .device(losingDevice), startedAt: segment.startedAt, endedAt: segment.endedAt, text: text,
                textOrigin: .edited, state: .typed(.ready), conflictOf: segment.id, revision: 1)
        }
    }
#endif
