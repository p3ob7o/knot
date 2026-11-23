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
    /// A recording's capture ended with its asset, and its working file is not removed yet: on
    /// the store path its row points to the asset, on the `Inbox/` path its item names it.
    case afterRecordingEnded = "after_recording_ended"
    /// A typed item's manifest is placed in `Inbox/` and its payload is not: the one point that
    /// falls inside the item lock, where nothing waits. The engine asks the hook's synchronous
    /// half there, and stops after the manifest when told; it then awaits this point, outside the
    /// lock. A test that releases the engine sees it place the whole item again.
    case betweenTypedManifestAndPayload = "between_typed_manifest_and_payload"
    /// A recording's first manifest and working file are on the drive, as the recorder's start
    /// returned, and its row is not written yet.
    case afterRecordingManifest = "after_recording_manifest"
    /// A recording is stopped, its working file synced, and it is not converted or moved yet.
    case beforeConversion = "before_conversion"
    /// A recording's conversion failed: its working file stays, and its row is not ended failed
    /// yet.
    case afterFailedConversion = "after_failed_conversion"
    /// A discard's first step is done and the discard has not answered: a recording's audio and
    /// manifest are removed and its row is not ended yet; a typed capture's end as empty is
    /// durable.
    case afterDiscard = "after_discard"
    /// A store call that the engine stopped waiting for has committed, and the engine has not
    /// taken its late answer yet.
    case beforeLateAnswer = "before_late_answer"
    /// A recording's row, whose store call the engine stopped waiting for, has committed, and its
    /// file has not joined it: a row comes without its file, which the recording's end, or ingest
    /// of its item, adds. The store records a row that commits after a newer capture began as
    /// ended at that start, waiting for its file (docs/architecture.md §5). Reached as the engine
    /// takes the late answer, for a recording only.
    case lateRecordingRow = "late_recording_row"
}

#if DEBUG || KNOT_FAKES
    /// Holds an engine's kill-point hook, set once by the initialiser that takes it, and its
    /// synchronous half, which is asked inside a write that cannot wait.
    final class KillPointHook: Sendable {
        private let hook = Mutex<(@Sendable (EngineKillPoint, CaptureID) async -> Void)?>(nil)
        private let stopsHook = Mutex<(@Sendable (EngineKillPoint, CaptureID) -> Bool)?>(nil)

        func set(
            _ hook: @escaping @Sendable (EngineKillPoint, CaptureID) async -> Void,
            stops: (@Sendable (EngineKillPoint, CaptureID) -> Bool)?
        ) {
            self.hook.withLock { $0 = hook }
            stopsHook.withLock { $0 = stops }
        }

        /// Whether the engine stops at `point` inside a write: the soak's child kills its process
        /// here, and a test answers true for the point it armed.
        func stops(_ point: EngineKillPoint, _ capture: CaptureID) -> Bool {
            stopsHook.withLock { $0 }?(point, capture) ?? false
        }

        func reach(_ point: EngineKillPoint, _ capture: CaptureID) async {
            guard let hook = hook.withLock({ $0 }) else { return }
            await hook(point, capture)
        }
    }
#endif
