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
    /// The press is ignored: the recording is still starting or stopping.
    case ignore
}

/// What a press of a record control does (docs/architecture.md §8, docs/product-spec.md §4.2).
public enum RecordingPressRule {
    /// The accidental-press window. It is measured between the two presses, not in audio.
    public static let accidentalPressWindow: TimeInterval = 1

    /// The decision for `press`, made in the app's process, where the recorder is.
    ///
    /// Only a process that has a recorder decides a press: every recording intent runs in
    /// the app's process (docs/architecture.md §14), and a control in another process hands
    /// its press to the app, where this rule runs. The recorder is the truth: a press stops a
    /// recording that this process is running, whatever the heartbeat says, and an idle
    /// recorder that finds a saved state, fresh or stale, recovers the orphan and starts a
    /// new recording, so a press never does nothing after a crash.
    ///
    /// - Parameters:
    ///   - recorder: this process's recorder. There is no way to call the rule without one.
    ///   - saved: the saved recording state, which recovery reads.
    public static func decide(_ press: Press, recorder: RecorderActivity, saved: SavedRecordingState?)
        -> PressDecision
    {
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

    /// True when a stop discards the recording: a tap started it and the stop came within
    /// one second of that tap. Hold-to-record is exempt, because the hold already filters
    /// accidents. A stop that the clock puts before its start, because the clock moved back,
    /// is kept: every recording that is not plainly accidental is kept.
    public static func isAccidental(start: Press, stop: Press) -> Bool {
        let gap = stop.at.timeIntervalSince(start.at)
        return start.kind == .tap && stop.kind == .tap && gap >= 0 && gap < accidentalPressWindow
    }
}

/// The Mac hotkey's states (docs/product-spec.md §6, docs/architecture.md §15). Times are on
/// the monotonic clock, which a change of the wall clock cannot move.
public enum HotkeyState: Hashable, Sendable {
    case idle
    /// The key is down and its 250 ms mark has not been handled.
    case pressed(since: ContinuousClock.Instant)
    /// The key is held past the mark and a recording runs.
    case holding(since: ContinuousClock.Instant)
}

/// What happens to the hotkey.
public enum HotkeyEvent: Hashable, Sendable {
    case keyDown(at: ContinuousClock.Instant)
    case keyUp
    /// The timer set at key-down for `HotkeyMachine.markDeadline(after:)` fired.
    case markReached
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
///
/// The order of events decides, not the clock: a release that arrives before the mark has
/// been handled is a tap, because the microphone has not opened, and the mark that arrives
/// first opens the hold. So no press does nothing, and no clock can leave the key stuck. The
/// app sets the mark's timer on the monotonic clock, at `markDeadline(after:)`.
public enum HotkeyMachine {
    public static let holdMark: Duration = .milliseconds(250)

    /// When the mark's timer fires for a key that went down at `keyDown`.
    public static func markDeadline(after keyDown: ContinuousClock.Instant) -> ContinuousClock.Instant {
        keyDown.advanced(by: holdMark)
    }

    public static func reduce(_ state: HotkeyState, _ event: HotkeyEvent) -> (HotkeyState, [HotkeyEffect]) {
        switch (state, event) {
        case (.idle, .keyDown(let at)):
            return (.pressed(since: at), [.prepareMicrophone])
        case (.pressed, .keyUp):
            return (.idle, [.releaseMicrophone, .tap])
        case (.pressed(let since), .markReached):
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
