import Foundation
import KnotCore
import Observation

/// The audio player of one voice segment.
@MainActor
@Observable
public final class PlayerViewModel {
    public private(set) var state: PlaybackState = .empty
    public private(set) var problem: ErrorCode?

    private let player: any AudioPlayer
    private var loaded: URL?

    public init(player: any AudioPlayer) {
        self.player = player
    }

    public var isPlaying: Bool {
        if case .playing = state { return true }
        return false
    }

    /// Where it stands and how long the recording is.
    public var position: (at: Duration, of: Duration) {
        switch state {
        case .empty: (.zero, .zero)
        case .paused(let at, let length), .playing(let at, let length): (at, length)
        case .ended(let length): (length, length)
        }
    }

    /// Plays `file`, loading it first, or pauses it while it plays.
    public func toggle(_ file: URL) async {
        if isPlaying {
            await player.pause()
            return
        }
        if loaded != file {
            do {
                _ = try await player.load(file)
                loaded = file
                problem = nil
            } catch {
                problem = error.code
                return
            }
        }
        if case .ended = state { await player.seek(to: .zero) }
        await player.play()
    }

    public func seek(to position: Duration) async {
        await player.seek(to: position)
    }

    /// Follows the player's state.
    public func observe() async {
        for await next in player.states() {
            state = next
        }
    }
}
