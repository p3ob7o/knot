import Foundation

/// Where the one recording of a device stands, for controls and widgets in other processes.
public enum RecordingPhase: String, Hashable, Sendable, Codable, CaseIterable {
    case idle
    case starting
    case recording
    case stopping
}

/// The recording state that controls and widgets read (docs/notes/SP-1.md): one value, written
/// whole, so a reader never sees half a write.
public struct RecordingStateSnapshot: Hashable, Sendable, Codable {
    public var phase: RecordingPhase
    public var captureID: CaptureID?
    public var startedAt: Date?
    /// The recorder's last sign of life. A snapshot whose heartbeat is older than
    /// `freshness` belongs to a recorder that died.
    public var heartbeat: Date?
    public var ownerLaunch: LaunchID?
    public var ownerPID: Int32?

    /// How old a heartbeat may be for the snapshot to count.
    public static let freshness: TimeInterval = 3

    public static let idle = RecordingStateSnapshot(phase: .idle)

    public init(
        phase: RecordingPhase, captureID: CaptureID? = nil, startedAt: Date? = nil, heartbeat: Date? = nil,
        ownerLaunch: LaunchID? = nil, ownerPID: Int32? = nil
    ) {
        self.phase = phase
        self.captureID = captureID
        self.startedAt = startedAt
        self.heartbeat = heartbeat
        self.ownerLaunch = ownerLaunch
        self.ownerPID = ownerPID
    }

    /// True when the heartbeat is less than `freshness` old at `now`. An idle snapshot needs none.
    public func isFresh(at now: Date) -> Bool {
        guard phase != .idle else { return true }
        guard let heartbeat else { return false }
        return now.timeIntervalSince(heartbeat) < Self.freshness
    }
}

/// Publishes whether a recording is running, for controls and widgets in other processes
/// (docs/architecture.md §5; docs/notes/SP-1.md): a synchronous read and write of one value in
/// the app group's defaults. KnotAudio implements it. Reloading the controls when the phase
/// changes belongs to the app shell, not to this port.
public protocol RecordingStateStore: Sendable {
    /// The last snapshot written, or `RecordingStateSnapshot.idle` when none was.
    func read() -> RecordingStateSnapshot
    func write(_ snapshot: RecordingStateSnapshot)
}

/// What the Live Activity of a recording shows.
public enum RecordingActivityPhase: String, Hashable, Sendable, Codable, CaseIterable {
    case recording
    case saving
    case saved
    case failed
}

/// The content of the Live Activity of an intent-started recording.
public struct RecordingActivityContent: Hashable, Sendable, Codable {
    public var phase: RecordingActivityPhase
    public var startedAt: Date
    /// When the content is out of date if nothing updates it (docs/architecture.md §8).
    public var staleDate: Date?

    public init(phase: RecordingActivityPhase, startedAt: Date, staleDate: Date? = nil) {
        self.phase = phase
        self.startedAt = startedAt
        self.staleDate = staleDate
    }
}

/// Why ActivityKit would not start an activity (docs/notes/SP-1.md).
public enum RecordingActivityError: Error, Hashable, Sendable {
    /// Live Activities are switched off for the app.
    case disabled
    /// ActivityKit refused, with the name of its `ActivityAuthorizationError` case, such as
    /// `globalMaximumExceeded`.
    case refused(String)
    /// Anything else, with its description.
    case other(String)
}

/// The Live Activity that keeps an intent-started recording alive, keyed by capture ID
/// (docs/architecture.md §5; docs/notes/SP-1.md). iPhone and iPad only; the iOS app target
/// implements it. It holds no activity: it finds one by the capture ID each time, so a new
/// launch ends the activity that a dead one left.
public protocol RecordingActivity: Sendable {
    /// Whether Live Activities are on for the app.
    var isEnabled: Bool { get }

    /// Starts the activity of `captureID`.
    func start(captureID: CaptureID, content: RecordingActivityContent) throws(RecordingActivityError)

    /// Updates the activity of `captureID`. One that is not there changes nothing.
    func update(captureID: CaptureID, _ content: RecordingActivityContent) async

    /// Ends the activity of `captureID` with its last content, dismissed after `dismissAfter`.
    func end(captureID: CaptureID, _ content: RecordingActivityContent, dismissAfter: Duration) async

    /// Ends every activity but that of `captureID`, at launch: those that have no recorder.
    /// Returns how many it ended.
    func endAll(except captureID: CaptureID?) async -> Int
}
