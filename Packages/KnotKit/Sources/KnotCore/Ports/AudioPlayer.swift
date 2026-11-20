import Foundation

/// Where a player stands.
public enum PlaybackState: Hashable, Sendable {
    /// Nothing is loaded.
    case empty
    /// A recording is loaded and does not play.
    case paused(at: Duration, of: Duration)
    case playing(at: Duration, of: Duration)
    /// It played to the end.
    case ended(Duration)
}

/// Plays a stored recording (docs/architecture.md §5). KnotAudio implements it.
public protocol AudioPlayer: Sendable {
    /// Loads the recording at `file`, paused at its start, and returns its length. A file that
    /// cannot be read fails with `audio_unreadable`.
    func load(_ file: URL) async throws(KnotError) -> Duration

    /// Plays from where it stands. With nothing loaded it changes nothing.
    func play() async

    func pause() async

    /// Moves to `position`, held between the start and the end, and keeps playing or paused.
    func seek(to position: Duration) async

    /// The current state, then every change. When the consumer goes away, its subscription
    /// ends; playback is not affected.
    func states() -> AsyncStream<PlaybackState>
}
