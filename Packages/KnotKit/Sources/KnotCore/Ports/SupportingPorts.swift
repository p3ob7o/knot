import Foundation

// The supporting ports that the second engineering pass named (docs/architecture.md §5),
// each with a fake in KnotFakes. Their implementers are listed in §5.

/// Where an Open intent, a widget or the URL scheme lands (docs/architecture.md §14). The
/// URL scheme only navigates: it never writes text and never starts a recording.
public enum SurfaceDestination: Hashable, Sendable {
    /// The capture surface.
    case capture
    /// The canvas.
    case sketch
    /// The stream with search focused.
    case search
    /// One note.
    case note(NoteID)
}

/// Brings a surface of the app forward. The iOS and Mac app targets implement it.
public protocol SurfaceRouter: Sendable {
    func open(_ destination: SurfaceDestination) async
}

/// The cues that tell a person a capture worked (docs/product-spec.md §4.5). The design sets
/// the exact haptics and sounds; the recorder decides when a cue may play, so that a start cue
/// is not recorded.
public enum Cue: String, Hashable, Sendable, Codable, CaseIterable {
    /// The recording started and the microphone is live.
    case recordingLive = "recording_live"
    /// Stopped and saved.
    case saved
    /// The recording could not start.
    case couldNotStart = "could_not_start"
    /// A tap-started recording stopped within a second, and nothing was kept.
    case discarded
    /// Stopped at the limit, by a call, or because it could not be saved further.
    case stoppedEarly = "stopped_early"
}

/// Plays the cues. The iOS, Watch and Mac app targets implement it.
public protocol CueEmitter: Sendable {
    func emit(_ cue: Cue)
}

/// Reads the free space of a volume. The recorder tells a full disk from another failed write
/// by it, because the audio file's error does not say (docs/architecture.md §5). KnotAudio
/// implements it.
public protocol FreeSpaceProbe: Sendable {
    /// The bytes free for this app on the volume that holds `url`, or `nil` when it cannot tell.
    func availableBytes(forVolumeAt url: URL) -> Int64?
}

/// The install ID kept in the Keychain for this device only (docs/architecture.md §4). The
/// store's device ID is checked against it: when a store arrives on another device through a
/// backup, the two no longer match. KnotStore implements it.
public protocol InstallIdentity: Sendable {
    /// This install's ID, made on the first call and the same on every later one. A Keychain
    /// that cannot be read fails with `write_failed`.
    func installID() throws(KnotError) -> UUID
}

/// The notice between processes: the `knot` command posts one after it writes, and the app
/// refreshes its observers when it arrives (docs/architecture.md §7). KnotStore implements it.
///
/// A notice is a hint and carries nothing. One can be lost, so the app also compares the
/// store's change counter when it comes forward. A process may receive its own notices too,
/// as Darwin notifications deliver them to the poster, and acting on its own is harmless: it
/// refreshes from the store as it would for another's.
public protocol ProcessNotifier: Sendable {
    /// Tells the other processes that the store changed.
    func postStoreChanged()

    /// One element for each notice that arrives, another process's or this one's own. When the
    /// consumer goes away, its subscription ends.
    func storeChanges() -> AsyncStream<Void>
}

/// An event of the app's life.
public enum LifecycleEvent: String, Hashable, Sendable, Codable, CaseIterable {
    /// The app came forward.
    case cameForward = "came_forward"
    /// The app went to the background.
    case wentToBackground = "went_to_background"
    /// The process is about to end.
    case willTerminate = "will_terminate"
}

/// The app's foreground and background events (docs/architecture.md §5). No module takes it
/// itself: the composition wires it to each module's call for the app coming forward. KnotApp
/// implements it, with an adapter for iOS and one for macOS.
public protocol Lifecycle: Sendable {
    /// Whether the app is in the foreground now.
    var isInForeground: Bool { get }

    /// Each event as it happens. When the consumer goes away, its subscription ends.
    func events() -> AsyncStream<LifecycleEvent>
}
