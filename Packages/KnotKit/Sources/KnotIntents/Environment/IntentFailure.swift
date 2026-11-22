import Foundation
import KnotCore

/// The error a text intent or its query gives the system: the reason, by its code, and a line
/// for Siri and Shortcuts that holds none of the caller's text.
public struct IntentFailure: Error, Hashable, Sendable, CustomLocalizedStringResourceConvertible {
    public let reason: TextIntentError

    public init(_ reason: TextIntentError) {
        self.reason = reason
    }

    public var localizedStringResource: LocalizedStringResource {
        switch reason {
        case .noText:
            "There was no text to save."
        case .knot(let error):
            switch error.code {
            case KnotError.portUnavailable.code: "Open Knot, then try again."
            case KnotError.captureInvalid.code: "Knot takes text only. Nothing was saved."
            case KnotError.notFound.code: "That note is not in Knot."
            case KnotError.noteDeleted.code: "That note was deleted."
            case KnotError.captureBlockedByRecording.code: "Stop the recording first."
            default: "Knot could not do that. (\(error.code.rawValue))"
            }
        }
    }

    /// Runs a call to the ports and gives its error as an intent's.
    static func ports<Value>(_ body: () async throws(KnotError) -> Value) async throws(IntentFailure) -> Value {
        do {
            return try await body()
        } catch {
            throw IntentFailure(.knot(error))
        }
    }

    /// Runs a call of the text intents and gives its error as an intent's.
    static func actions<Value>(_ body: () async throws(TextIntentError) -> Value) async throws(IntentFailure) -> Value {
        do {
            return try await body()
        } catch {
            throw IntentFailure(error)
        }
    }

    /// Reads the environment through the accessor, and gives its error as an intent's.
    static func accessor<Value>(_ body: () throws(KnotError) -> Value) throws(IntentFailure) -> Value {
        do {
            return try body()
        } catch {
            throw IntentFailure(.knot(error))
        }
    }
}
