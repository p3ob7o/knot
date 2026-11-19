import ActivityKit
import Foundation

// The ports that WP-02's third pull request writes, drafted here in the shape SP-1 proposes
// and implemented with the real APIs below and in App/. That they compile against the pinned
// SDK, under Swift 6 with complete concurrency checking, is the evidence of docs/notes/SP-1.md.
// What they do on a locked iPhone is the sitting's question.

// MARK: - RecordingStateStore

/// Whether a recording is running, for the controls and widgets of other processes
/// (docs/architecture.md §5 and §8). Synchronous: a control's value provider and the app's
/// launch read it before anything else runs.
protocol RecordingStateStore: Sendable {
    func read() -> RecordingStateSnapshot
    func write(_ snapshot: RecordingStateSnapshot)
}

struct RecordingStateSnapshot: Codable, Sendable, Equatable {
    enum Phase: String, Codable, Sendable {
        case idle, starting, recording, stopping
    }

    var phase: Phase
    var captureID: UUID?
    var startedAt: Date?
    /// Written every second by the recorder's process (§8).
    var heartbeat: Date?
    /// The process launch that owns the recording, so that recovery never ends a capture
    /// of the current launch (§6, rule 6).
    var ownerLaunch: Date?
    var ownerPID: Int32?

    static let idle = RecordingStateSnapshot(phase: .idle)

    /// A heartbeat older than three seconds means no recording is running (§8).
    func isFresh(at now: Date) -> Bool {
        guard phase != .idle, let heartbeat else { return false }
        return now.timeIntervalSince(heartbeat) < 3
    }
}

/// The state in the app group's defaults, as one JSON value, so that a reader never sees half
/// a write.
struct GroupDefaultsRecordingState: RecordingStateStore {
    private static let key = "sp1.recordingState"

    func read() -> RecordingStateSnapshot {
        guard let defaults = Self.defaults() else { return .idle }
        guard let data = defaults.data(forKey: Self.key) else { return .idle }
        return (try? JSONDecoder().decode(RecordingStateSnapshot.self, from: data)) ?? .idle
    }

    func write(_ snapshot: RecordingStateSnapshot) {
        guard let defaults = Self.defaults(), let data = try? JSONEncoder().encode(snapshot) else {
            SP1Log.record("state.write-failed", ["reason": "no group defaults"])
            return
        }
        defaults.set(data, forKey: Self.key)
    }

    /// Whether the group's defaults can be read at all: before the first unlock they may not.
    static func probe() -> String {
        guard let defaults = defaults() else { return "no-suite" }
        return defaults.data(forKey: key) == nil ? "empty" : "readable"
    }

    private static func defaults() -> UserDefaults? {
        SP1Paths.appGroup.flatMap { UserDefaults(suiteName: $0) }
    }
}

// MARK: - RecordingActivity

/// The Live Activity that keeps an intent-started recording alive. iPhone and iPad only.
/// Keyed by capture ID: an implementation holds no `Activity` object, which is not Sendable,
/// and finds the activity again after a relaunch to end it.
protocol RecordingActivity: Sendable {
    /// `ActivityAuthorizationInfo().areActivitiesEnabled`. When false, an intent opens the app.
    var isEnabled: Bool { get }
    func start(captureID: UUID, startedAt: Date) throws(RecordingActivityError)
    func update(captureID: UUID, _ state: SP1RecordingAttributes.ContentState) async
    func end(captureID: UUID, _ state: SP1RecordingAttributes.ContentState, dismissAfter: TimeInterval) async
    /// Ends every activity whose capture this launch does not own. Returns how many it ended.
    func endAll(except captureID: UUID?) async -> Int
}

enum RecordingActivityError: Error, Sendable {
    case disabled
    /// One of ActivityKit's `ActivityAuthorizationError` cases, by name.
    case refused(String)
    case other(String)
}

// MARK: - BackgroundRunner

/// Time to finish work after a recording stops. The work is passed in with a progress sink,
/// because both mechanisms SP-1 tests require progress: `LongRunningIntent.performBackgroundTask`
/// and `BGContinuedProcessingTask` cancel a task that reports none.
///
/// A runner is scoped. The intent-backed one is valid only while its intent's `perform()`
/// runs, so the intent creates it, hands it to the work, and awaits the work before it returns.
protocol BackgroundRunner: Sendable {
    var name: String { get }
    func run(_ work: PostStopWork) async throws
}

/// The work after stop: transcribe, then clean. Reports a fraction and a short label, never text.
struct PostStopWork: Sendable {
    let captureID: UUID
    let body: @Sendable (_ report: @escaping @Sendable (Double, String) -> Void) async throws -> Void
}

/// Which mechanism runs the work after stop. The owner switches it in the app between rows.
enum PostStopMechanism: String, CaseIterable, Sendable {
    case longRunningIntent, continuedProcessing, backgroundTask, none

    private static let key = "sp1.postStopMechanism"

    static var current: PostStopMechanism {
        get {
            let raw = SP1Paths.appGroup.flatMap { UserDefaults(suiteName: $0)?.string(forKey: key) }
            return raw.flatMap(PostStopMechanism.init(rawValue:)) ?? .longRunningIntent
        }
        set {
            SP1Paths.appGroup.flatMap { UserDefaults(suiteName: $0) }?.set(newValue.rawValue, forKey: key)
        }
    }
}

// MARK: - The Live Activity's attributes

/// The recording's Live Activity. In the real tree this type lives in KnotIntents, inside
/// `#if os(iOS)` (docs/architecture.md §14); the spike is iOS only.
struct SP1RecordingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable {
            case starting, recording, saved, failed
        }

        var phase: Phase
        var startedAt: Date
        /// A reason code for a failure, shown with "Open Knot". Never note text.
        var reason: String?
    }

    var captureID: String
}
