import Foundation
import Synchronization

/// Who uses the process's audio: the recordings that hold the session and the players that play
/// through it. The recording wins (the orchestrator's ruling on WP-12's PR 2):
///
/// - a recording that starts stops every player that plays, and each reports that it stopped;
/// - a play while this process records is refused, changing nothing.
///
/// The app has one, `process`. A test gives the recorder's input and its player one of their own,
/// so that tests that run at once never see each other's recordings.
final class AudioActivity: Sendable {
    /// The activity of this process, which the live entry point's input and player share.
    static let process = AudioActivity()

    private let state = Mutex(State())

    private struct State {
        /// The recordings that hold the session now.
        var recordings: Set<UUID> = []
        /// The players, each with what stops it.
        var players: [UUID: @Sendable () async -> Void] = [:]
    }

    /// True while a recording of this process holds the session.
    var isRecording: Bool { state.withLock { !$0.recordings.isEmpty } }

    /// A recording takes the session: every player stops first, and returns once each has. The
    /// claim ends with `RecordingClaim.end()`, once.
    func recordingBegins() async -> RecordingClaim {
        let id = UUID()
        let players = state.withLock { state in
            state.recordings.insert(id)
            return Array(state.players.values)
        }
        for stop in players { await stop() }
        return RecordingClaim(id: id, activity: self)
    }

    fileprivate func recordingEnds(_ id: UUID) {
        _ = state.withLock { $0.recordings.remove(id) }
    }

    /// A player, and what stops it when a recording begins.
    func register(player id: UUID, stop: @escaping @Sendable () async -> Void) {
        state.withLock { $0.players[id] = stop }
    }

    func unregister(player id: UUID) {
        _ = state.withLock { $0.players.removeValue(forKey: id) }
    }
}

/// A recording's hold on the session, given back once.
final class RecordingClaim: Sendable {
    private let id: UUID
    private let activity: AudioActivity
    private let ended = Mutex(false)

    fileprivate init(id: UUID, activity: AudioActivity) {
        self.id = id
        self.activity = activity
    }

    /// Gives the session back. A second call changes nothing.
    func end() {
        let first = ended.withLock { ended in
            defer { ended = true }
            return !ended
        }
        if first { activity.recordingEnds(id) }
    }
}
