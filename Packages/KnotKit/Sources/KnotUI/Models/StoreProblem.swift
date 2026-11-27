import Foundation
import KnotCore

/// What is wrong when the stream cannot read the notes (docs/product-spec.md §4.4). Capture
/// still works: new captures go to `Inbox/` and appear once the notes open again, and Knot
/// never deletes notes to recover. The stream says so.
public struct StoreProblem: Hashable, Sendable {
    public var code: ErrorCode

    public init(code: ErrorCode) {
        self.code = code
    }

    public init(_ error: KnotError) {
        self.code = error.code
    }

    /// What the stream says.
    public var message: String {
        let kept = localized("New captures are kept safe and appear when your notes open again.")
        let cause: String =
            switch code {
            case KnotError.storeNewerThanBuild.code:
                localized("Your notes were saved by a newer Knot. Update Knot to open them.")
            case KnotError.storeDamaged.code:
                localized("Knot can’t read your notes. Nothing was deleted.")
            case KnotError.diskFull.code:
                localized("This device is out of space, so Knot can’t open your notes.")
            default:
                localized("Knot can’t open your notes right now.")
            }
        return cause + " " + kept
    }
}

/// What a capture surface says when something went wrong with what the person did there.
public enum SurfaceProblem: Hashable, Sendable {
    /// Typed text could not be saved anywhere: the surface keeps it in the field
    /// (docs/product-spec.md §4.4).
    case couldNotSave(ErrorCode)
    /// A recording could not start, and why (docs/product-spec.md §4.4).
    case couldNotStartRecording(ErrorCode)
    /// An action on a segment or the note was refused by the store.
    case actionRefused(ErrorCode)
    /// The undo of a move was refused: the segment stays in its new note
    /// (docs/plan/WP-21.md, failure rules).
    case undoRefused(ErrorCode)
    /// The action is not in this build yet.
    case notAvailableYet

    public var message: String {
        switch self {
        case .couldNotSave:
            localized("Knot couldn’t save this text. It stays here until it can.")
        case .couldNotStartRecording(let code):
            switch code {
            case KnotError.microphonePermissionRefused.code:
                localized("Knot can’t use the microphone. You can allow it in Settings.")
            case KnotError.noInputDevice.code:
                localized("No microphone is connected. You can still type.")
            case KnotError.tooLittleSpace.code:
                localized("There isn’t enough space to record.")
            default:
                localized("The recording couldn’t start.")
            }
        case .actionRefused:
            localized("That didn’t work. Nothing was changed.")
        case .undoRefused:
            localized("The note it came from has changed or is gone, so the move can’t be undone.")
        case .notAvailableYet:
            localized("This isn’t available yet.")
        }
    }
}
