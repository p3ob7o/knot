import Foundation
import KnotCore
import Synchronization

/// The recording state in the defaults the composition gives, for controls and widgets in other
/// processes (docs/architecture.md §5 and §13; docs/notes/SP-1.md): one JSON value under one
/// key, written whole and read whole, so a reader never sees half a write. On iOS the
/// composition gives the app group's suite, so that the app's extensions read what the app
/// writes. KnotAudio names no suite and never falls back to `.standard`.
///
/// A value that cannot be read, or none, is idle.
///
/// The store takes the defaults it is given for itself: `UserDefaults` is not `Sendable`, so the
/// caller hands over an instance it keeps no use of, and every read and write goes through one
/// lock. Another instance of the same suite, in this process or another, sees what it writes.
public final class DefaultsRecordingStateStore: RecordingStateStore {
    /// The one key the state is kept under.
    public static let key = "knot.recording-state"

    private let defaults: Mutex<UserDefaults>

    public init(defaults: sending UserDefaults) {
        self.defaults = Mutex(defaults)
    }

    public func read() -> RecordingStateSnapshot {
        guard let data = defaults.withLock({ $0.data(forKey: Self.key) }),
            let snapshot = try? JSONDecoder().decode(RecordingStateSnapshot.self, from: data)
        else { return .idle }
        return snapshot
    }

    public func write(_ snapshot: RecordingStateSnapshot) {
        // A snapshot of identifiers, dates, a phase and a process ID always encodes.
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.withLock { $0.set(data, forKey: Self.key) }
    }
}
