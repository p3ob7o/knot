/// The states of a typed segment (docs/architecture.md §4).
///
/// ```
/// draft ──end──► ready                 (empty draft ──► discarded)
/// draft ──killed──► ready at relaunch
/// ```
public enum TypedState: String, Hashable, Sendable, CaseIterable {
    case draft
    case ready
    case discarded
}

/// A step of a voice segment's processing.
public enum VoiceStep: String, Hashable, Sendable, CaseIterable {
    case transcribe
    case clean
}

/// The states of a voice segment (docs/architecture.md §4).
///
/// ```
/// recording ──stop──► recorded ──► transcribing ──► transcribed ──► cleaning ──► ready
///     │ killed            │ cannot run now            │ no model, or the guard rejects
///     ▼                   ▼                           ▼
/// recovered ──────► recorded (pending)          ready, with the raw transcript as text
/// any step fails ──► failed(step): the recording is kept and a retry is offered
/// onWatch ──transfer──► delivered ──► continues as "recorded" on the iPhone
/// ```
public enum VoiceState: Hashable, Sendable {
    case recording
    /// A recording a crash cut short, found at relaunch.
    case recovered
    case recorded
    case transcribing
    case transcribed
    case cleaning
    case ready
    /// A tap-started recording stopped within one second of its press.
    case discarded
    /// Saved on the watch, waiting for its iPhone.
    case onWatch
    /// Received by the iPhone, before ingest.
    case delivered
    case failed(VoiceStep, ErrorCode)
}

/// The states of an ink segment (docs/architecture.md §4).
///
/// ```
/// drawing ──end──► recognising ──► ready     (empty canvas ──► discarded)
/// drawing ──killed──► recognising at relaunch
/// ```
///
/// There is no way from `ready` back to `drawing`: a finished drawing is not reopened in v1.
public enum InkState: Hashable, Sendable {
    case drawing
    case recognising
    case ready
    case discarded
    case failed(ErrorCode)
}

/// A segment's state, whatever its kind. It syncs, so it has an unknown case.
public enum SegmentState: OpenEnum {
    case typed(TypedState)
    case voice(VoiceState)
    case ink(InkState)
    case unknown(String)

    public init(rawValue: String) {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        self = Self.parse(parts) ?? .unknown(rawValue)
    }

    private static func parse(_ parts: [String]) -> SegmentState? {
        guard let kind = parts.first else { return nil }
        switch (kind, parts.count) {
        case ("typed", 2):
            return TypedState(rawValue: parts[1]).map(SegmentState.typed)
        case ("voice", 2):
            let simple: [String: VoiceState] = [
                "recording": .recording, "recovered": .recovered, "recorded": .recorded,
                "transcribing": .transcribing, "transcribed": .transcribed, "cleaning": .cleaning,
                "ready": .ready, "discarded": .discarded, "on_watch": .onWatch, "delivered": .delivered,
            ]
            return simple[parts[1]].map(SegmentState.voice)
        case ("voice", 4) where parts[1] == "failed":
            guard let step = VoiceStep(rawValue: parts[2]), !parts[3].isEmpty else { return nil }
            return .voice(.failed(step, ErrorCode(rawValue: parts[3])))
        case ("ink", 2):
            let simple: [String: InkState] = [
                "drawing": .drawing, "recognising": .recognising, "ready": .ready, "discarded": .discarded,
            ]
            return simple[parts[1]].map(SegmentState.ink)
        case ("ink", 3) where parts[1] == "failed":
            return parts[2].isEmpty ? nil : .ink(.failed(ErrorCode(rawValue: parts[2])))
        default:
            return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .typed(let state): "typed.\(state.rawValue)"
        case .voice(let state):
            switch state {
            case .recording: "voice.recording"
            case .recovered: "voice.recovered"
            case .recorded: "voice.recorded"
            case .transcribing: "voice.transcribing"
            case .transcribed: "voice.transcribed"
            case .cleaning: "voice.cleaning"
            case .ready: "voice.ready"
            case .discarded: "voice.discarded"
            case .onWatch: "voice.on_watch"
            case .delivered: "voice.delivered"
            case .failed(let step, let code): "voice.failed.\(step.rawValue).\(code)"
            }
        case .ink(let state):
            switch state {
            case .drawing: "ink.drawing"
            case .recognising: "ink.recognising"
            case .ready: "ink.ready"
            case .discarded: "ink.discarded"
            case .failed(let code): "ink.failed.\(code)"
            }
        case .unknown(let raw): raw
        }
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    /// True while the segment's work is unfinished: still being captured, on the watch, or
    /// not yet transcribed, cleaned or recognised. A failed segment waits for a person, not
    /// for work, so it is not pending.
    public var isPending: Bool {
        switch self {
        case .typed(let state): state == .draft
        case .voice(let state):
            switch state {
            case .recording, .recovered, .recorded, .transcribing, .transcribed, .cleaning, .onWatch, .delivered:
                true
            case .ready, .discarded, .failed: false
            }
        case .ink(let state): state == .drawing || state == .recognising
        case .unknown: false
        }
    }

    /// True while the capture behind the segment is still being made.
    public var isCapturing: Bool {
        switch self {
        case .typed(.draft), .voice(.recording), .ink(.drawing): true
        default: false
        }
    }
}
