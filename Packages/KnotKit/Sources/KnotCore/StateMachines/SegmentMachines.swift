/// A transition a state machine does not have.
public struct IllegalTransition<State: Hashable & Sendable, Event: Hashable & Sendable>: Error, Hashable {
    public let from: State
    public let event: Event

    public init(from: State, event: Event) {
        self.from = from
        self.event = event
    }

    /// The taxonomy's case for it, for a caller that reports through `KnotError`.
    public var knotError: KnotError { .illegalTransition }
}

/// What happens to a typed segment.
public enum TypedEvent: Hashable, Sendable {
    /// The capture ended: the surface was dismissed, ⌘↩ or Done, or the app was left.
    case end(isEmpty: Bool)
    /// A draft was found at relaunch after a crash (rule 12).
    case recoverAtRelaunch(isEmpty: Bool)
    /// The capture's save failed; its text waits in `Inbox/` (§6, rule 6).
    case saveFailed
    /// A retry stored the capture that had failed.
    case retrySaved
}

/// The typed segment's state machine (docs/architecture.md §4).
public enum TypedMachine {
    public static func reduce(_ state: TypedState, _ event: TypedEvent) throws(IllegalTransition<
        TypedState, TypedEvent
    >) -> TypedState {
        switch (state, event) {
        case (.draft, .end(let isEmpty)), (.draft, .recoverAtRelaunch(let isEmpty)):
            return isEmpty ? .discarded : .ready
        case (.draft, .saveFailed): return .failed
        case (.failed, .retrySaved): return .ready
        default:
            throw IllegalTransition(from: state, event: event)
        }
    }
}

/// What happens to a voice segment.
public enum VoiceEvent: Hashable, Sendable {
    /// The recording stopped and was kept: by its control, by a call, at the limit, or
    /// because writing failed. The segment says why apart from its state.
    case stop
    /// A tap-started recording stopped within one second of its press.
    case discardAccidental
    /// The process died while recording. Recovery finds it at relaunch.
    case killed
    /// Recovery turned the orphaned recording into a segment.
    case recoveryFinished
    /// The watch handed the recording to its iPhone.
    case transferred
    /// The iPhone ingested the delivered recording.
    case ingested
    case startTranscribing
    /// The transcriber finished. With no recognised words the segment is ready with empty text.
    case transcribed(hasWords: Bool)
    case startCleaning
    /// The raw transcript stays as the text: no model, cleanup off, a refusal, or the guard
    /// rejected the result.
    case keepRawTranscript
    case cleaned
    /// The step cannot run now, or its job was found running at launch: back to waiting.
    case deferred
    /// Speech is unavailable on this device, a final error here: the segment stays recorded,
    /// kept with no text here, until another device takes the work.
    case speechUnavailableHere
    /// The audio cannot be read, a final error: the recording is kept, ready with no text.
    case audioUnreadable
    /// The step failed for good, after its attempts.
    case stepFailed(ErrorCode)
    /// The recording could not be saved as a capture; its audio is kept.
    case saveFailed(ErrorCode)
    /// A person pressed Retry.
    case retry
}

/// The voice segment's state machine (docs/architecture.md §4).
public enum VoiceMachine {
    public static func reduce(_ state: VoiceState, _ event: VoiceEvent) throws(IllegalTransition<
        VoiceState, VoiceEvent
    >) -> VoiceState {
        switch (state, event) {
        case (.recording, .stop): return .recorded
        case (.recording, .discardAccidental): return .discarded
        case (.recording, .killed): return .recovered
        case (.recovered, .recoveryFinished): return .recorded
        case (.onWatch, .transferred): return .delivered
        case (.delivered, .ingested): return .recorded
        case (.recorded, .startTranscribing): return .transcribing
        case (.transcribing, .transcribed(let hasWords)): return hasWords ? .transcribed : .ready
        case (.transcribing, .deferred): return .recorded
        case (.transcribing, .speechUnavailableHere): return .recorded
        case (.transcribing, .audioUnreadable): return .ready
        case (.transcribing, .stepFailed(let code)): return .failed(.transcribe, code)
        case (.transcribed, .startCleaning): return .cleaning
        case (.transcribed, .keepRawTranscript), (.cleaning, .keepRawTranscript): return .ready
        case (.cleaning, .cleaned): return .ready
        case (.cleaning, .deferred): return .transcribed
        case (.cleaning, .stepFailed(let code)): return .failed(.clean, code)
        case (.recording, .saveFailed(let code)), (.recovered, .saveFailed(let code)):
            return .failed(.record, code)
        case (.failed(.record, _), .retry): return .recorded
        case (.failed(.transcribe, _), .retry): return .recorded
        case (.failed(.clean, _), .retry): return .transcribed
        default: throw IllegalTransition(from: state, event: event)
        }
    }
}

/// What happens to an ink segment.
public enum InkEvent: Hashable, Sendable {
    /// The Pencil drew a stroke on this segment's canvas.
    case stroke
    /// The capture ended with Done.
    case end(isEmpty: Bool)
    /// A drawing was found at relaunch after a crash: it goes on to recognition.
    case recoverAtRelaunch(isEmpty: Bool)
    case recognised
    case stepFailed(ErrorCode)
    /// The drawing could not be saved as a capture; its data is kept.
    case saveFailed(ErrorCode)
    case retry
}

/// The ink segment's state machine (docs/architecture.md §4).
///
/// A finished drawing is not reopened in v1, so a stroke on a ready drawing is refused:
/// writing more starts a new ink segment in the same note (docs/product-spec.md §4.3).
public enum InkMachine {
    public static func reduce(_ state: InkState, _ event: InkEvent) throws(IllegalTransition<
        InkState, InkEvent
    >) -> InkState {
        switch (state, event) {
        case (.drawing, .stroke): return .drawing
        case (.drawing, .end(let isEmpty)), (.drawing, .recoverAtRelaunch(let isEmpty)):
            return isEmpty ? .discarded : .recognising
        case (.recognising, .recognised): return .ready
        case (.recognising, .stepFailed(let code)), (.drawing, .saveFailed(let code)): return .failed(code)
        case (.failed, .retry): return .recognising
        default: throw IllegalTransition(from: state, event: event)
        }
    }
}
