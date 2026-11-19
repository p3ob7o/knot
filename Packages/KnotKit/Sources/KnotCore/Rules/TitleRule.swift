import Foundation

/// The rules for generated titles (docs/product-spec.md §5, docs/architecture.md §4 and §9).
///
/// `fits` is the one check that a generated title uses only words from its note. KnotCleanup
/// calls it when it proposes a title, and the store calls it when a segment leaves a note.
public enum TitleRule {
    /// True when a generated title fits its note: one line of plain text, at most 60
    /// characters, not empty, and made only of words that occur in the note's text.
    ///
    /// Words are compared without regard to case, and are the runs of letters and digits,
    /// so punctuation never counts as a word.
    public static func fits(_ title: String, noteTexts: [String]) -> Bool {
        guard title.count <= Limits.generatedTitleCharacters,
            !title.contains(where: \.isNewline),
            !CaptureText.isEmpty(title)
        else { return false }
        let titleWords = words(of: title)
        guard !titleWords.isEmpty else { return false }
        let noteWords = Set(noteTexts.flatMap(words(of:)))
        return titleWords.allSatisfy(noteWords.contains)
    }

    /// The words of a text, folded to lower case.
    public static func words(of text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    /// True when the clean job may propose a title for the note that holds its recording
    /// when the job finishes: the note has no title, and the recording is the note's first
    /// live segment. A note whose first segment is not a recording gets no generated title.
    public static func mayPropose(for recording: SegmentID, segmentsInOrder: [Segment], title: String?) -> Bool {
        guard title == nil else { return false }
        guard let first = segmentsInOrder.first(where: \.isLiveCapture) else { return false }
        return first.id == recording && first.kind == .voice
    }

    /// A note's title after a segment left it.
    public struct AfterLeave: Hashable, Sendable {
        public var title: String?
        public var titleOrigin: TitleOrigin
        /// The generated title that was dropped, which a return may put back.
        public var dropped: String?

        public init(title: String?, titleOrigin: TitleOrigin, dropped: String?) {
            self.title = title
            self.titleOrigin = titleOrigin
            self.dropped = dropped
        }
    }

    /// Checks a note's title when a segment leaves it. A generated title that no longer
    /// fits the words still in the note is dropped. A typed title is never touched.
    public static func afterSegmentLeaves(title: String?, origin: TitleOrigin, remainingTexts: [String]) -> AfterLeave {
        guard let title, origin == .generated, !fits(title, noteTexts: remainingTexts) else {
            return AfterLeave(title: title, titleOrigin: origin, dropped: nil)
        }
        return AfterLeave(title: nil, titleOrigin: .none, dropped: title)
    }

    /// A note's title after a return: a title the move dropped comes back if the note has
    /// none by then.
    public static func afterReturn(title: String?, origin: TitleOrigin, dropped: String?) -> (String?, TitleOrigin) {
        guard title == nil, let dropped else { return (title, origin) }
        return (dropped, .generated)
    }
}
