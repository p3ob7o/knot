import Foundation
import KnotCore

/// What CreateNote writes, from the two text parameters of the system notes schema: the
/// note's `name`, which the schema requires, and its `content`, which it does not.
///
/// The orchestrator's ruling of 2026-11-22, for the owner to confirm. Knot keeps no empty note,
/// so a name can arrive alone, and it is not lost:
///
/// - A name and content: the content is the text, and the name is the title, when
///   `Limits.checkTitle` takes it.
/// - A name alone, or with content that is empty once trimmed: the name is the text of the
///   note, and no title is set. The stream shows a note's first line where it has no title.
/// - A name that `Limits.checkTitle` refuses, with content: the name is the first line of the
///   text, above the content, and no title is set.
/// - No name, with content: the content is the text, and no title is set.
/// - Nothing once trimmed, name and content both: nothing to write, and the intent refuses.
///
/// "Empty once trimmed" is the engine's own rule for an empty capture, `CaptureText.isEmpty`.
/// The name is trimmed of the spaces and line breaks around it; the content is kept as given.
public enum CreateNoteRule {
    /// The text of the typed capture and the title to set once it is stored, or `nil` when
    /// there is nothing to write.
    public static func plan(name: String, content: String?) -> CreateNotePlan? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = content.flatMap { CaptureText.isEmpty($0) ? nil : $0 }
        switch (name.isEmpty, content) {
        case (true, nil):
            return nil
        case (false, nil):
            return CreateNotePlan(text: name, title: nil)
        case (true, let content?):
            return CreateNotePlan(text: content, title: nil)
        case (false, let content?):
            if fitsTitle(name) {
                return CreateNotePlan(text: content, title: name)
            }
            return CreateNotePlan(text: name + "\n" + content, title: nil)
        }
    }

    private static func fitsTitle(_ name: String) -> Bool {
        do {
            try Limits.checkTitle(name)
            return true
        } catch {
            return false
        }
    }
}

/// The capture CreateNote makes, and the title it sets once the capture is stored.
public struct CreateNotePlan: Hashable, Sendable {
    /// The text of the typed capture: never empty once trimmed.
    public var text: String
    /// The note's title, set as a person's once the capture is stored, or `nil`.
    public var title: String?

    public init(text: String, title: String?) {
        self.text = text
        self.title = title
    }
}
