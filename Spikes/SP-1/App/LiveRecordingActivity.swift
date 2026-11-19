import ActivityKit
import Foundation

/// `RecordingActivity` on ActivityKit. Stateless: the activity is found by its capture ID each
/// time, because `Activity` is not Sendable and must not be held across isolation domains.
struct LiveRecordingActivity: RecordingActivity {
    typealias Content = SP1RecordingAttributes.ContentState

    var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func start(captureID: UUID, startedAt: Date) throws(RecordingActivityError) {
        guard isEnabled else { throw .disabled }
        let state = Content(phase: .recording, startedAt: startedAt, reason: nil)
        // A stale date one heartbeat window ahead: if the app dies, the system shows the
        // activity as stale (docs/architecture.md §8).
        let content = ActivityContent(state: state, staleDate: startedAt.addingTimeInterval(10))
        do {
            let activity = try Activity.request(
                attributes: SP1RecordingAttributes(captureID: captureID.uuidString), content: content,
                pushType: nil)
            SP1Log.record("activity.started", ["capture": captureID.uuidString, "activity": activity.id])
        } catch let error as ActivityAuthorizationError {
            throw .refused(String(describing: error))
        } catch {
            throw .other(SP1Log.code(error))
        }
    }

    func update(captureID: UUID, _ state: Content) async {
        guard let activity = Self.find(captureID) else { return }
        let stale = state.phase == .recording ? Date().addingTimeInterval(10) : nil
        await activity.update(ActivityContent(state: state, staleDate: stale))
    }

    func end(captureID: UUID, _ state: Content, dismissAfter: TimeInterval) async {
        guard let activity = Self.find(captureID) else {
            SP1Log.record("activity.end-missing", ["capture": captureID.uuidString])
            return
        }
        await activity.end(
            ActivityContent(state: state, staleDate: nil),
            dismissalPolicy: .after(Date().addingTimeInterval(dismissAfter)))
        SP1Log.record("activity.ended", ["capture": captureID.uuidString, "phase": state.phase.rawValue])
    }

    func endAll(except captureID: UUID?) async -> Int {
        var ended = 0
        for activity in Activity<SP1RecordingAttributes>.activities
        where activity.attributes.captureID != captureID?.uuidString {
            await activity.end(nil, dismissalPolicy: .immediate)
            ended += 1
        }
        return ended
    }

    private static func find(_ captureID: UUID) -> Activity<SP1RecordingAttributes>? {
        Activity<SP1RecordingAttributes>.activities.first { $0.attributes.captureID == captureID.uuidString }
    }
}
