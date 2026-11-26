import KnotCore

/// Keeps why a stored recording ended with its voice segment (`NoteStore.setRecordingEnding(_:of:)`,
/// pull request 128), so that the segment can say why (docs/product-spec.md §4.2 and §4.5). The
/// sibling of `StoredPeaks`, and kept at the same moment.
///
/// Whoever stores a recording, the engine, ingest or recovery, keeps the reason once the capture's
/// row points to its stored file and before `Recorder.removeWorkingFile(of:)`: the recorder's own
/// manifest keeps the reason beside the working file, and goes with it. A death between the two
/// leaves the manifest, and recovery keeps the reason then. A recording stopped at its control, or
/// discarded, has no reason, and nothing is set. A reason never fails, ends or holds a capture: a
/// store that refuses it is logged by its code, and the capture goes on. No log line names the
/// reason itself: it is not content, but a line has no field for it, and its capture ID finds it.
struct StoredRecordingEnding: Sendable {
    let notes: any NoteStore
    let log: KnotLog

    /// Keeps `reason` with the capture's segment. No reason is nothing to keep, and a refusal is
    /// logged and dropped.
    ///
    /// With `deadline`, the call races it, as every store call of the engine does: the engine's end
    /// holds the capture's line, and a store that held the reason would hold the end, its cue and
    /// the line with them. A miss is what a refusal is: logged, and the caller goes on at once. The
    /// call that lost the race may still land, and the reason is kept then. Ingest and recovery
    /// hold no caller's line, and wait for it.
    func keep(_ reason: RecordingEndReason?, of capture: CaptureID, deadline: StoreDeadline? = nil) async {
        guard let reason else { return }
        let segment = SegmentID(capture)
        guard let deadline else {
            do throws(KnotError) {
                try await notes.setRecordingEnding(reason, of: segment)
                log.capture(capture, "recording_ending_kept")
            } catch {
                log.failure(error.about(capture: capture), "recording_ending_not_kept")
            }
            return
        }
        let answer = await deadline.race { [notes] () async throws(KnotError) in
            try await notes.setRecordingEnding(reason, of: segment)
        }
        switch answer {
        case .answered:
            log.capture(capture, "recording_ending_kept")
        case .refused(let error):
            log.failure(error.about(capture: capture), "recording_ending_not_kept")
        case .timedOut:
            log.capture(capture, "recording_ending_not_kept", .code(KnotError.storeNotOpen.code))
        }
    }
}
