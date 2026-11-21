import KnotCore
import Synchronization

/// The points of the engine where a kill tells the most: each comes right after a write that
/// is durable and before the call that made it answers, or between two writes of one end.
///
/// The engine awaits its kill-point hook at each, with the capture's ID. Only a debug build, or
/// one that sets `KNOT_FAKES`, has the hook, through the engine's initialiser that takes it; a
/// release build has these names and nothing that uses them. A test passes a hook that never
/// returns, which stops the engine there as a kill would, and then relaunches over the same
/// store and files; the soak's child kills its process in the hook (docs/architecture.md §17).
public enum EngineKillPoint: String, CaseIterable, Sendable {
    /// A start's first durable write is done, and the start has not answered: on the store
    /// path its row, on the `Inbox/` path its item, for a recording its row after the manifest.
    case afterStart = "after_start"
    /// A start answered as begun, before it ends the capture it follows (rule 15).
    case beforeEndingFollowed = "before_ending_followed"
    /// An update's save is durable, and the update has not answered.
    case afterSave = "after_save"
    /// A typed capture's end is durable, and the end has not answered.
    case afterTypedEnd = "after_typed_end"
    /// A stopped recording's file is converted and moved into the `AssetStore`, and its
    /// capture has not been ended with it.
    case afterRecordingMoved = "after_recording_moved"
    /// A recording's capture ended with its asset, and its working file is not removed yet.
    case afterRecordingEnded = "after_recording_ended"
}

#if DEBUG || KNOT_FAKES
    /// Holds an engine's kill-point hook, set once by the initialiser that takes it.
    final class KillPointHook: Sendable {
        private let hook = Mutex<(@Sendable (EngineKillPoint, CaptureID) async -> Void)?>(nil)

        func set(_ hook: @escaping @Sendable (EngineKillPoint, CaptureID) async -> Void) {
            self.hook.withLock { $0 = hook }
        }

        func reach(_ point: EngineKillPoint, _ capture: CaptureID) async {
            guard let hook = hook.withLock({ $0 }) else { return }
            await hook(point, capture)
        }
    }
#endif
