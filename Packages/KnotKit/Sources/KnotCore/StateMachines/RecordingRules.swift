import Foundation

/// How a recording was started or stopped.
public enum PressKind: Hashable, Sendable {
    /// A tap of a record control, the Action Button, a control, Double Tap, or a click.
    case tap
    /// The 250 ms mark of a held hotkey on the Mac.
    case holdStart
    /// The release of a held hotkey.
    case holdRelease
}

/// One press, with the time it happened.
public struct Press: Hashable, Sendable {
    public var kind: PressKind
    public var at: Date

    public init(_ kind: PressKind, at: Date) {
        self.kind = kind
        self.at = at
    }
}

/// What the recorder in this process is doing. In the app process it is the truth.
public enum RecorderActivity: Hashable, Sendable {
    case idle
    case starting
    /// Recording, started by `startedBy`.
    case recording(startedBy: Press)
    case stopping
}

/// The saved recording state that other processes read: which capture records, which launch
/// runs it, and its heartbeat, which the recorder writes every second (docs/architecture.md §8).
public struct SavedRecordingState: Hashable, Sendable, Codable {
    public var captureID: CaptureID
    public var launchID: LaunchID
    public var heartbeatAt: Date

    public init(captureID: CaptureID, launchID: LaunchID, heartbeatAt: Date) {
        self.captureID = captureID
        self.launchID = launchID
        self.heartbeatAt = heartbeatAt
    }

    /// A heartbeat older than three seconds is stale: no recording is running. A heartbeat
    /// more than three seconds ahead of `now` cannot come from a recorder that writes every
    /// second either, so after a clock moved backwards it is stale too.
    public static let staleAfter: TimeInterval = 3

    public func isStale(at now: Date) -> Bool {
        abs(now.timeIntervalSince(heartbeatAt)) > Self.staleAfter
    }
}

/// What a press does.
public enum PressDecision: Hashable, Sendable {
    /// Start a recording, with the started cue.
    case start
    /// Recover the orphaned recording a crash left, then start a new one, with the started
    /// cue: a person pressing then is starting a recording.
    case recoverOrphanThenStart(CaptureID)
    /// Stop the recording and keep it.
    case stopAndKeep
    /// Stop the recording and discard it: a tap-started recording stopped within one
    /// second of its press.
    case stopAndDiscard
    /// Ask the process that runs the recording to stop it.
    case askOwnerToStop(CaptureID)
    /// The press is ignored: the recording is still starting or stopping.
    case ignore
}

/// What a press of a record control does (docs/architecture.md §8, docs/product-spec.md §4.2).
public enum RecordingPressRule {
    /// The accidental-press window. It is measured between the two presses, not in audio.
    public static let accidentalPressWindow: TimeInterval = 1

    /// The decision for `press`.
    ///
    /// - Parameters:
    ///   - recorder: this process's recorder, or `nil` in a process that has none, such as
    ///     the widget extension. Where there is a recorder it decides, whatever the heartbeat
    ///     says: a press stops a recording that this process is running.
    ///   - saved: the saved recording state, which serves other processes and recovery.
    ///   - now: the time to judge the heartbeat by.
    public static func decide(
        _ press: Press, recorder: RecorderActivity?, saved: SavedRecordingState?, now: Date
    ) -> PressDecision {
        if let recorder {
            switch recorder {
            case .starting, .stopping:
                return .ignore
            case .recording(let start):
                // A release ends only the hold that started the recording.
                if press.kind == .holdRelease, start.kind != .holdStart { return .ignore }
                return isAccidental(start: start, stop: press) ? .stopAndDiscard : .stopAndKeep
            case .idle:
                if press.kind == .holdRelease { return .ignore }
                // Nothing records in this process, so a saved state is an orphan, fresh or not.
                if let saved { return .recoverOrphanThenStart(saved.captureID) }
                return .start
            }
        }
        guard let saved else { return press.kind == .holdRelease ? .ignore : .start }
        if saved.isStale(at: now) {
            return press.kind == .holdRelease ? .ignore : .recoverOrphanThenStart(saved.captureID)
        }
        return press.kind == .holdStart ? .ignore : .askOwnerToStop(saved.captureID)
    }

    /// True when a stop discards the recording: a tap started it and the stop came within
    /// one second of that tap. Hold-to-record is exempt, because the hold already filters
    /// accidents. A stop that the clock puts before its start, because the clock moved back,
    /// is kept: every recording that is not plainly accidental is kept.
    public static func isAccidental(start: Press, stop: Press) -> Bool {
        let gap = stop.at.timeIntervalSince(start.at)
        return start.kind == .tap && stop.kind == .tap && gap >= 0 && gap < accidentalPressWindow
    }
}

/// The Mac hotkey's states (docs/product-spec.md §6, docs/architecture.md §15).
public enum HotkeyState: Hashable, Sendable {
    case idle
    /// The key is down and its 250 ms mark has not passed.
    case pressed(since: Date)
    /// The key is held past the mark and a recording runs.
    case holding(since: Date)
}

/// What happens to the hotkey.
public enum HotkeyEvent: Hashable, Sendable {
    case keyDown(at: Date)
    case keyUp(at: Date)
    /// The timer set at key-down fired.
    case markReached(at: Date)
    /// The once-a-second check found the key up while a hold records: its release was missed.
    case keyFoundUp
    case escape
}

/// What the hotkey asks of the app.
public enum HotkeyEffect: Hashable, Sendable {
    /// Get the microphone ready without opening it.
    case prepareMicrophone
    /// Let go of the prepared microphone, which never opened.
    case releaseMicrophone
    /// A tap: show the panel ready for typing, or hide it if it is showing.
    case tap
    /// The 250 ms mark of a hold: show the panel without the keyboard and open the microphone.
    case startHoldRecording
    /// Stop the hold's recording.
    case stopRecording
}

/// The hotkey's state machine. A press shorter than 250 ms is a tap, and the microphone opens
/// only at the 250 ms mark of a hold, never on a tap.
public enum HotkeyMachine {
    public static let holdMark: TimeInterval = 0.25

    public static func reduce(_ state: HotkeyState, _ event: HotkeyEvent) -> (HotkeyState, [HotkeyEffect]) {
        switch (state, event) {
        case (.idle, .keyDown(let at)):
            return (.pressed(since: at), [.prepareMicrophone])
        case (.pressed(let since), .keyUp(let at)):
            // A release that comes at or after the mark, before the mark's timer was handled,
            // is not a tap, and the microphone never opened.
            return at.timeIntervalSince(since) < holdMark
                ? (.idle, [.releaseMicrophone, .tap]) : (.idle, [.releaseMicrophone])
        case (.pressed(let since), .markReached(let at)):
            guard at.timeIntervalSince(since) >= holdMark else { return (state, []) }
            return (.holding(since: since), [.startHoldRecording])
        case (.holding, .keyUp), (.holding, .keyFoundUp), (.holding, .escape), (.holding, .keyDown):
            // Releasing stops the hold. If a release was missed, the check of the key's state,
            // Esc or another press of the hotkey stops it.
            return (.idle, [.stopRecording])
        case (.pressed, .escape):
            return (.idle, [.releaseMicrophone])
        default:
            return (state, [])
        }
    }
}
