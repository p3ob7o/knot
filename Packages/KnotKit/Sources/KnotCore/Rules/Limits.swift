import Foundation

/// The size bounds of the domain (docs/architecture.md §4 and §19).
///
/// First values, all estimates. WP-02's third PR fixes them after SP-4 confirms CloudKit's
/// record limit.
public enum Limits {
    /// A segment's text, in bytes of UTF-8. With the raw transcript beside it a record stays
    /// under CloudKit's limit.
    public static let segmentTextBytes = 256 * 1024
    /// A title, in characters.
    public static let titleCharacters = 200
    /// A generated title, in characters (docs/architecture.md §9).
    public static let generatedTitleCharacters = 60
    /// A capture manifest, in bytes.
    public static let manifestBytes = 64 * 1024
    /// A recording stops by itself after 30 minutes, with the same cue as a stop
    /// (docs/product-spec.md §4.2).
    public static let longestRecording: TimeInterval = 30 * 60
    /// Deleted notes and segments stay recoverable, and replaced text and a move's history
    /// are kept, for 30 days (docs/product-spec.md §7 and §10).
    public static let keptForDays = 30

    /// Checks a title against its bound. A longer title is refused, never cut.
    public static func checkTitle(_ title: String) throws(KnotError) {
        guard title.count <= titleCharacters else { throw KnotError.textTooLong }
    }
}

/// Splits text that runs past the size limit into pieces (docs/architecture.md §4).
///
/// Nothing is cut: the pieces joined give the text back exactly. Each piece becomes a
/// segment of the same capture, and the same text always gives the same pieces and the same
/// IDs, so a repeat of the capture returns the same segments and the ledger counts it once.
public enum TextPieces {
    /// One piece of a capture's text and the segment it becomes.
    public struct Piece: Hashable, Sendable {
        public let segmentID: SegmentID
        public let position: Int
        public let text: String
    }

    /// The pieces of `text`, each at most `maxBytes` of UTF-8.
    ///
    /// A piece ends after the last line break that falls in its second half, or failing
    /// that after the last space there, or failing that at the last whole character that
    /// fits. A character is never split. A single character longer than `maxBytes`, which
    /// only a tiny limit allows, is a piece of its own.
    public static func split(_ text: String, maxBytes: Int = Limits.segmentTextBytes) -> [String] {
        precondition(maxBytes > 0, "A piece holds at least one byte.")
        var pieces: [String] = []
        var rest = Substring(text)
        while rest.utf8.count > maxBytes {
            let end = cut(rest, maxBytes: maxBytes)
            pieces.append(String(rest[..<end]))
            rest = rest[end...]
        }
        if !rest.isEmpty || pieces.isEmpty { pieces.append(String(rest)) }
        return pieces
    }

    /// The pieces of a capture's text with their segment IDs. Piece 0 shares the capture's ID.
    public static func pieces(of text: String, capture: CaptureID, maxBytes: Int = Limits.segmentTextBytes)
        -> [Piece]
    {
        split(text, maxBytes: maxBytes).enumerated().map { position, piece in
            Piece(segmentID: .piece(position, of: capture), position: position, text: piece)
        }
    }

    private static func cut(_ text: Substring, maxBytes: Int) -> Substring.Index {
        var bytes = 0
        var end = text.startIndex
        var lastLineBreak: Substring.Index?
        var lastSpace: Substring.Index?
        for index in text.indices {
            let size = text[index].utf8.count
            if bytes + size > maxBytes { break }
            bytes += size
            end = text.index(after: index)
            if bytes * 2 >= maxBytes {
                if text[index].isNewline {
                    lastLineBreak = end
                } else if text[index].isWhitespace {
                    lastSpace = end
                }
            }
        }
        if end == text.startIndex { return text.index(after: end) }
        return lastLineBreak ?? lastSpace ?? end
    }
}
