// The error taxonomy (docs/architecture.md §5 and §19). Each case below has an entry in
// docs/errors.md, and a test fails when one lacks it. A later package adds a case here and
// its entry there in the same pull request.

extension KnotError {
    // MARK: The store and its files

    /// The disk filled while Knot wrote. The transaction or the file was not written.
    public static let diskFull = KnotError(
        code: "disk_full", next: .freeSpace, retry: .safe, written: .nothing, exitStatus: .unexpected)
    /// Another writer holds the store for longer than the busy timeout.
    public static let storeBusy = KnotError(
        code: "store_busy", next: .waitAndRetry, retry: .safe, written: .nothing, exitStatus: .storeBusy)
    /// The store's database cannot be read.
    public static let storeDamaged = KnotError(
        code: "store_damaged", next: .followTroubleshootingGuide, retry: .notSafe, written: .nothing,
        exitStatus: .needsOwner)
    /// The store was written by a newer Knot. This build does not open, change or delete it.
    public static let storeNewerThanBuild = KnotError(
        code: "store_newer_than_build", next: .updateKnot, retry: .notSafe, written: .nothing,
        exitStatus: .needsOwner)
    /// The store is older than the `knot` tool, which never migrates.
    public static let storeOlderThanTool = KnotError(
        code: "store_older_than_tool", next: .openKnot, retry: .safe, written: .nothing, exitStatus: .needsOwner)
    /// A database at the store's path that Knot did not create, told by its `store_meta` row.
    public static let storeNotCreatedByKnot = KnotError(
        code: "store_not_created_by_knot", next: .followTroubleshootingGuide, retry: .notSafe, written: .nothing,
        exitStatus: .needsOwner)
    /// The store is not open yet, is migrating, or did not answer in time. Capture goes on into `Inbox/`.
    public static let storeNotOpen = KnotError(
        code: "store_not_open", next: .waitAndRetry, retry: .safe, written: .keptInInbox, exitStatus: .storeBusy)
    /// A write to the store or to a file failed for a reason other than a full disk.
    public static let writeFailed = KnotError(
        code: "write_failed", next: .retry, retry: .safe(times: 3), written: .nothing, exitStatus: .unexpected)
    /// The app group's container is missing, so `StoreLocations` has no place for `Inbox/`.
    public static let groupContainerMissing = KnotError(
        code: "group_container_missing", next: .reinstallKnot, retry: .notSafe, written: .nothing,
        exitStatus: .needsOwner)
    /// `KNOT_AGENT=1` is set and something asked for the milestone store (docs/architecture.md §7).
    public static let agentRefusedMilestoneStore = KnotError(
        code: "agent_refused_milestone_store", next: .useDevelopmentBuild, retry: .notSafe, written: .nothing,
        exitStatus: .needsOwner)
    /// An asset ID already holds a file with other content. A stored recording or drawing is
    /// never replaced, so the new file is refused and the stored one stays.
    public static let assetConflict = KnotError(
        code: "asset_conflict", next: .reportProblem, retry: .notSafe, written: .nothing, exitStatus: .conflict)
    /// A development build on the Mac names no worktree folder for its store, or one that is
    /// not safe as a folder name. Development builds from two worktrees never share a store.
    public static let devStoreFolderInvalid = KnotError(
        code: "dev_store_folder_invalid", next: .buildFromWorktree, retry: .notSafe, written: .nothing,
        exitStatus: .needsOwner)

    // MARK: Recording

    /// The microphone permission was refused.
    public static let microphonePermissionRefused = KnotError(
        code: "microphone_permission_refused", next: .allowMicrophone, retry: .safe, written: .nothing,
        exitStatus: .unexpected)
    /// No input device is connected.
    public static let noInputDevice = KnotError(
        code: "no_input_device", next: .connectMicrophone, retry: .safe, written: .nothing, exitStatus: .unexpected)
    /// Another app holds the audio session.
    public static let audioSessionBusy = KnotError(
        code: "audio_session_busy", next: .waitAndRetry, retry: .safe, written: .nothing, exitStatus: .unexpected)
    /// Too little free space to start a recording, so Knot refuses to start one.
    public static let tooLittleSpace = KnotError(
        code: "too_little_space", next: .freeSpace, retry: .safe, written: .nothing, exitStatus: .unexpected)
    /// The disk filled during a recording or a drawing. The capture stopped with the stop cue.
    public static let captureStoppedDiskFull = KnotError(
        code: "capture_stopped_disk_full", next: .freeSpace, retry: .safe, written: .keptUpToFailure,
        exitStatus: .unexpected)
    /// The conversion to the final audio format failed. The working file stays as the recording.
    public static let conversionFailed = KnotError(
        code: "conversion_failed", next: .retry, retry: .safe(times: 5), written: .contentKept,
        exitStatus: .unexpected)
    /// A typing or drawing capture cannot start while a recording runs on this device.
    public static let captureBlockedByRecording = KnotError(
        code: "capture_blocked_by_recording", next: .stopRecording, retry: .safe, written: .nothing,
        exitStatus: .conflict)

    // MARK: Speech, cleanup and ink

    /// The speech model is not installed yet, or is still installing. The recording waits,
    /// pending, and plays.
    public static let speechModelNotInstalled = KnotError(
        code: "speech_model_not_installed", errorClass: .deferral, next: .waitForModel, retry: .safe,
        written: .nothing, exitStatus: .unexpected)
    /// The recording cannot be read. It is kept, with no text. This is final, not a failure to fix.
    public static let audioUnreadable = KnotError(
        code: "audio_unreadable", errorClass: .final, next: .none, retry: .notSafe, written: .contentKept,
        exitStatus: .unexpected)
    /// Speech recognition is unavailable on this device. The recording stays recorded and shows
    /// as kept with no text here, until another device takes the work. Final on this device.
    public static let speechUnavailable = KnotError(
        code: "speech_unavailable", errorClass: .final, next: .none, retry: .notSafe, written: .contentKept,
        exitStatus: .unexpected)
    /// The transcriber returned an error, whose code `context.engineCode` carries. The
    /// recording is kept.
    public static let transcriptionFailed = KnotError(
        code: "transcription_failed", next: .retry, retry: .safe(times: 5), written: .contentKept,
        exitStatus: .unexpected)
    /// The cleanup model is still downloading or not ready.
    public static let cleanupModelNotReady = KnotError(
        code: "cleanup_model_not_ready", errorClass: .deferral, next: .waitForModel, retry: .safe,
        written: .textUnchanged, exitStatus: .unexpected)
    /// The device cannot use the cleanup model. The raw transcript is the final text.
    public static let cleanupModelUnavailable = KnotError(
        code: "cleanup_model_unavailable", errorClass: .final, next: .none, retry: .notSafe,
        written: .textUnchanged, exitStatus: .unexpected)
    /// Cleanup declined: a refusal, a guardrail violation, an empty or malformed result, a result
    /// the guard rejected, text too long for the model, an unsupported language or an
    /// unsupported request. The raw transcript is the text, and `context.detail` says which.
    public static let cleanupDeclined = KnotError(
        code: "cleanup_declined", next: .none, retry: .notSafe, written: .textUnchanged, exitStatus: .unexpected)
    /// Cleanup took longer than its time allows. The raw transcript stays the text, and the job
    /// tries again.
    public static let cleanupTimedOut = KnotError(
        code: "cleanup_timed_out", next: .retry, retry: .safe(times: 5), written: .textUnchanged,
        exitStatus: .unexpected)
    /// Handwriting recognition failed. The drawing is kept.
    public static let recognitionFailed = KnotError(
        code: "recognition_failed", next: .retry, retry: .safe(times: 5), written: .contentKept,
        exitStatus: .unexpected)
    /// The drawing's data cannot be decoded. No retry fixes it: the drawing is kept, shown as
    /// "Kept, no text".
    public static let drawingUnreadable = KnotError(
        code: "drawing_unreadable", errorClass: .final, next: .none, retry: .notSafe, written: .contentKept,
        exitStatus: .unexpected)
    /// The recogniser does not read handwriting in the language set. The drawing is kept, shown
    /// as "Kept, no text".
    public static let handwritingLanguageUnsupported = KnotError(
        code: "handwriting_language_unsupported", errorClass: .final, next: .none, retry: .notSafe,
        written: .contentKept, exitStatus: .unexpected)

    // MARK: Deferrals: a step that cannot run now

    /// The system limits requests to the model for now. `context.retryAt` says when to try
    /// again, when the system gives a time.
    public static let requestsLimited = KnotError(
        code: "requests_limited", errorClass: .deferral, next: .waitAndRetry, retry: .safe, written: .nothing,
        exitStatus: .unexpected)
    /// The system limits its resources for now.
    public static let systemResourcesLimited = KnotError(
        code: "system_resources_limited", errorClass: .deferral, next: .waitAndRetry, retry: .safe,
        written: .nothing, exitStatus: .unexpected)
    /// The app has no background time left.
    public static let noBackgroundTime = KnotError(
        code: "no_background_time", errorClass: .deferral, next: .openKnot, retry: .safe, written: .nothing,
        exitStatus: .unexpected)
    /// The device is locked and the step needs it unlocked.
    public static let deviceLocked = KnotError(
        code: "device_locked", errorClass: .deferral, next: .unlockDevice, retry: .safe, written: .nothing,
        exitStatus: .unexpected)
    /// The step runs only while the app is in the foreground, as recognition does
    /// (docs/architecture.md §10). It runs when the app comes forward.
    public static let appNotInForeground = KnotError(
        code: "app_not_in_foreground", errorClass: .deferral, next: .openKnot, retry: .safe, written: .nothing,
        exitStatus: .unexpected)

    /// A step was cancelled: the task that awaited it was cancelled, because background time
    /// ran out or the queue was asked to stop. It is a yield (docs/architecture.md §4): not an
    /// attempt, not a decline and not an error, and nothing from the step was saved.
    public static let cancelled = KnotError(
        code: "cancelled", errorClass: .yield, next: .none, retry: .safe, written: .nothing, exitStatus: .unexpected)

    // MARK: Inbox and watch

    /// An inbox item cannot be read. It becomes a failed segment that says so, and the file is kept.
    public static let inboxItemUnreadable = KnotError(
        code: "inbox_item_unreadable", next: .reportProblem, retry: .notSafe, written: .contentKept,
        exitStatus: .unexpected)
    /// An inbox item was written by a newer Knot. It is kept, and ingested after an update.
    public static let inboxItemNewerVersion = KnotError(
        code: "inbox_item_newer_version", next: .updateKnot, retry: .safe, written: .contentKept,
        exitStatus: .unexpected)
    /// A manifest is larger than its bound.
    public static let manifestTooLarge = KnotError(
        code: "manifest_too_large", next: .reportProblem, retry: .notSafe, written: .contentKept,
        exitStatus: .unexpected)
    /// A file does not match the checksum its manifest or its record names: a file from the
    /// watch, which the watch sends again; a file placed in, or read from, the asset store; or a
    /// file the asset fetcher brought from another device, which is fetched again.
    public static let checksumMismatch = KnotError(
        code: "checksum_mismatch", next: .waitAndRetry, retry: .safe, written: .contentKept, exitStatus: .unexpected)
    /// The watch link's session is not activated yet, or the iPhone is switching watches. The
    /// capture waits in the outbox.
    public static let linkNotReady = KnotError(
        code: "link_not_ready", errorClass: .deferral, next: .waitAndRetry, retry: .safe, written: .contentKept,
        exitStatus: .unexpected)
    /// The other side of the watch link is missing: the devices are not paired, or the other
    /// app is not installed. The capture waits in the outbox.
    public static let counterpartMissing = KnotError(
        code: "counterpart_missing", errorClass: .deferral, next: .waitAndRetry, retry: .safe,
        written: .contentKept, exitStatus: .unexpected)
    /// The receiving side of the watch link has no room. The capture waits in the outbox.
    public static let counterpartFull = KnotError(
        code: "counterpart_full", errorClass: .deferral, next: .freeIPhoneSpace, retry: .safe,
        written: .contentKept,
        exitStatus: .unexpected)
    /// A transfer over the watch link did not complete. It is an attempt, and the capture is
    /// queued again.
    public static let deliveryFailed = KnotError(
        code: "delivery_failed", next: .waitAndRetry, retry: .safe, written: .contentKept, exitStatus: .unexpected)
    /// The outbox file of a capture is missing or cannot be read. The capture fails at once and
    /// its manifest is kept.
    public static let outboxFileMissing = KnotError(
        code: "outbox_file_missing", next: .reportProblem, retry: .notSafe, written: .contentKept,
        exitStatus: .unexpected)

    // MARK: Sync (docs/architecture.md §11)

    /// The device is signed out of iCloud. Sync pauses and the notes stay.
    public static let syncSignedOut = KnotError(
        code: "sync_signed_out", next: .signInToICloud, retry: .safe, written: .nothing, exitStatus: .unexpected)
    /// The device signed in to another iCloud account. Nothing uploads before the answer.
    public static let syncAccountChanged = KnotError(
        code: "sync_account_changed", next: .answerUploadQuestion, retry: .notSafe, written: .nothing,
        exitStatus: .unexpected)
    /// The notes were removed from iCloud. This device keeps its notes and pauses sync.
    public static let syncZoneRemoved = KnotError(
        code: "sync_zone_removed", next: .answerUploadQuestion, retry: .notSafe, written: .nothing,
        exitStatus: .unexpected)
    /// A fetch would delete more than the set share of the local notes, so sync paused.
    public static let syncMassDeletePaused = KnotError(
        code: "sync_mass_delete_paused", next: .answerUploadQuestion, retry: .notSafe, written: .nothing,
        exitStatus: .unexpected)
    /// A restored store waits for consent before it uploads.
    public static let syncUploadNeedsConsent = KnotError(
        code: "sync_upload_needs_consent", next: .answerUploadQuestion, retry: .notSafe, written: .nothing,
        exitStatus: .unexpected)

    // The sync conditions: the errors of the engine that SP-4's code half sorted
    // (docs/notes/SP-4.md). Only a manual sync throws them; otherwise they surface as a status.

    /// The network, the account or the service is not available for now, or the server limits
    /// requests. The engine retries by itself; `context.retryAt` says when, when the server gave
    /// a time.
    public static let syncTransient = KnotError(
        code: "sync_transient", errorClass: .deferral, next: .waitAndRetry, retry: .safe, written: .nothing,
        exitStatus: .unexpected)
    /// The server holds a newer version of a record. It is merged like a fetched record and sent
    /// again.
    public static let syncServerRecordChanged = KnotError(
        code: "sync_server_record_changed", next: .retry, retry: .safe, written: .nothing, exitStatus: .unexpected)
    /// A send found the zone missing: the user deleted it, or it went with a reset of the
    /// encrypted data. It leads to the zone-removed pause.
    public static let syncZoneMissing = KnotError(
        code: "sync_zone_missing", next: .answerUploadQuestion, retry: .notSafe, written: .nothing,
        exitStatus: .unexpected)
    /// A batch was over the server's limits. The adapter splits it and sends again.
    public static let syncLimitExceeded = KnotError(
        code: "sync_limit_exceeded", next: .retry, retry: .safe, written: .nothing, exitStatus: .unexpected)
    /// The user's iCloud storage is full. Sending stops until there is room, and a retry after
    /// the person freed some is safe.
    public static let syncQuotaExceeded = KnotError(
        code: "sync_quota_exceeded", next: .freeICloudStorage, retry: .safe, written: .nothing,
        exitStatus: .unexpected)
    /// A record is gone from the server. The rule of a long absence decides what follows.
    public static let syncUnknownItem = KnotError(
        code: "sync_unknown_item", next: .none, retry: .notSafe, written: .nothing, exitStatus: .unexpected)
    /// Any other error of the engine. No retry fixes it on this device.
    public static let syncFinal = KnotError(
        code: "sync_final", errorClass: .final, next: .reportProblem, retry: .notSafe, written: .nothing,
        exitStatus: .unexpected)

    // MARK: Text, revisions and cursors

    /// Text is longer than the door it came through allows, such as a title of more than 200 characters.
    public static let textTooLong = KnotError(
        code: "text_too_long", next: .shortenText, retry: .notSafe, written: .nothing, exitStatus: .usage)
    /// The same capture ID with different content.
    public static let captureIDConflict = KnotError(
        code: "capture_id_conflict", next: .useNewCaptureID, retry: .notSafe, written: .nothing,
        exitStatus: .conflict)
    /// A capture, or its end, that does not fit its kind: a body of another kind, a file whose
    /// digest is not 64 hexadecimal digits, a recording or drawing that starts with its file, a
    /// recording that ends stored with no file, or a negative content revision. Refused by
    /// `record`, `checkpoint` and `end`, with nothing written; and by `setPeaks`, for peaks that
    /// `RecordingPeaks.isStorable(_:)` does not take.
    public static let captureInvalid = KnotError(
        code: "capture_invalid", next: .reportProblem, retry: .notSafe, written: .nothing, exitStatus: .unexpected)
    /// The segment or note changed since the revision the caller read.
    public static let revisionStale = KnotError(
        code: "revision_stale", next: .readAgain, retry: .notSafe, written: .nothing, exitStatus: .conflict)
    /// A revision from another store, or from before a restore of this one.
    public static let revisionForeign = KnotError(
        code: "revision_foreign", next: .readAgain, retry: .notSafe, written: .nothing, exitStatus: .conflict)
    /// A cursor from another store, or from another generation of this one.
    public static let cursorForeign = KnotError(
        code: "cursor_foreign", next: .readFromStart, retry: .notSafe, written: .nothing, exitStatus: .conflict)
    /// A cursor ahead of the store's change counter.
    public static let cursorAheadOfStore = KnotError(
        code: "cursor_ahead_of_store", next: .readFromStart, retry: .notSafe, written: .nothing,
        exitStatus: .conflict)
    /// No note or segment has that ID.
    public static let notFound = KnotError(
        code: "not_found", next: .readAgain, retry: .notSafe, written: .nothing, exitStatus: .notFound)
    /// The end of an ID given matches more than one note or segment.
    public static let idAmbiguous = KnotError(
        code: "id_ambiguous", next: .giveMoreOfTheID, retry: .notSafe, written: .nothing, exitStatus: .notFound)
    /// A capture was asked into a note that is deleted.
    public static let noteDeleted = KnotError(
        code: "note_deleted", next: .readAgain, retry: .notSafe, written: .nothing, exitStatus: .conflict)
    /// The segment's capture is still open in the app, so it cannot be edited, deleted or moved.
    public static let segmentCaptureOpen = KnotError(
        code: "segment_capture_open", next: .waitForCaptureToEnd, retry: .safe, written: .nothing,
        exitStatus: .conflict)
    /// "Remove recording" of a segment that has no text yet: the recording is all there is,
    /// and its transcribe job still needs it.
    public static let removeRecordingRefusedNoText = KnotError(
        code: "remove_recording_refused_no_text", next: .waitAndRetry, retry: .safe, written: .nothing,
        exitStatus: .conflict)

    // MARK: Moves and returns (docs/architecture.md §5)

    /// A move of a segment whose capture is open.
    public static let moveRefusedOpenCapture = KnotError(
        code: "move_refused_open_capture", next: .waitForCaptureToEnd, retry: .safe, written: .nothing,
        exitStatus: .conflict)
    /// A move of a deleted segment.
    public static let moveRefusedDeletedSegment = KnotError(
        code: "move_refused_deleted_segment", next: .none, retry: .notSafe, written: .nothing,
        exitStatus: .conflict)
    /// A move of a conflict copy, which always stays with the segment it copies.
    public static let moveRefusedConflictCopy = KnotError(
        code: "move_refused_conflict_copy", next: .none, retry: .notSafe, written: .nothing, exitStatus: .conflict)
    /// A move of the only live segment of its note, apart from its own conflict copies.
    public static let moveRefusedOnlySegment = KnotError(
        code: "move_refused_only_segment", next: .none, retry: .notSafe, written: .nothing, exitStatus: .conflict)
    /// A return after the segment's note changed again since the move.
    public static let returnRefusedNoteChanged = KnotError(
        code: "return_refused_note_changed", next: .none, retry: .notSafe, written: .nothing,
        exitStatus: .conflict)
    /// A return to a note that is deleted or gone.
    public static let returnRefusedNoteGone = KnotError(
        code: "return_refused_note_gone", next: .none, retry: .notSafe, written: .nothing, exitStatus: .conflict)
    /// A return with no move to undo on this device in the last 30 days.
    public static let returnRefusedNoMove = KnotError(
        code: "return_refused_no_move", next: .none, retry: .notSafe, written: .nothing, exitStatus: .notFound)

    // MARK: Jobs and rules

    /// A job was found running at launch twice. The process died inside it each time.
    public static let jobDiedTwice = KnotError(
        code: "job_died_twice", next: .retry, retry: .safe(times: 1), written: .contentKept,
        exitStatus: .unexpected)
    /// A state machine was asked for a transition it does not have, or the store for a change
    /// its rules do not allow, such as peaks for a segment with no recording, or why a recording
    /// ended for a segment that is not a voice segment or whose capture is open.
    public static let illegalTransition = KnotError(
        code: "illegal_transition", next: .reportProblem, retry: .notSafe, written: .nothing,
        exitStatus: .unexpected)

    // MARK: Settings

    /// A hotkey needs at least one modifier, or must be a function key.
    public static let hotkeyInvalid = KnotError(
        code: "hotkey_invalid", next: .chooseAnotherKey, retry: .notSafe, written: .nothing, exitStatus: .usage)
    /// Another app already uses that key.
    public static let hotkeyTaken = KnotError(
        code: "hotkey_taken", next: .chooseAnotherKey, retry: .notSafe, written: .nothing, exitStatus: .usage)
    /// An append window outside its range.
    public static let appendWindowInvalid = KnotError(
        code: "append_window_invalid", next: .none, retry: .notSafe, written: .nothing, exitStatus: .usage)

    // MARK: Usage: a command line or a tool call that does not fit its command

    /// A command that takes text got none, or got text that is empty. Nothing was written.
    public static let usageMissingText = KnotError(
        code: "usage_missing_text", next: .seeUsage, retry: .notSafe, written: .nothing, exitStatus: .usage)
    /// The first word is not a command.
    public static let usageUnknownCommand = KnotError(
        code: "usage_unknown_command", next: .seeUsage, retry: .notSafe, written: .nothing, exitStatus: .usage)
    /// A flag or an argument the command does not take, one that lacks its value, a value it
    /// cannot read, or a required argument other than text that is missing. Nothing was written.
    public static let usageInvalidArgument = KnotError(
        code: "usage_invalid_argument", next: .seeUsage, retry: .notSafe, written: .nothing, exitStatus: .usage)

    // MARK: The process

    /// Command-line access is off on this Mac.
    public static let accessOff = KnotError(
        code: "access_off", next: .turnOnCommandLineAccess, retry: .safe, written: .nothing, exitStatus: .accessOff)
    /// A port of `AppEnvironment.unavailable`: its package has not filled it in yet.
    public static let portUnavailable = KnotError(
        code: "port_unavailable", next: .reportProblem, retry: .notSafe, written: .nothing, exitStatus: .unexpected)
    /// Anything else. It carries a request ID once the logging facade records one.
    public static let unexpected = KnotError(
        code: "unexpected", next: .reportProblem, retry: .notSafe, written: .unknown, exitStatus: .unexpected)

    /// Every case of the taxonomy, in the order of docs/errors.md.
    public static let catalog: [KnotError] = [
        diskFull, storeBusy, storeDamaged, storeNewerThanBuild, storeOlderThanTool, storeNotCreatedByKnot,
        storeNotOpen, writeFailed, groupContainerMissing, agentRefusedMilestoneStore, assetConflict,
        devStoreFolderInvalid,
        microphonePermissionRefused, noInputDevice, audioSessionBusy, tooLittleSpace, captureStoppedDiskFull,
        conversionFailed, captureBlockedByRecording,
        speechModelNotInstalled, audioUnreadable, speechUnavailable, transcriptionFailed, cleanupModelNotReady,
        cleanupModelUnavailable, cleanupDeclined, cleanupTimedOut, recognitionFailed, drawingUnreadable,
        handwritingLanguageUnsupported,
        requestsLimited, systemResourcesLimited, noBackgroundTime, deviceLocked, appNotInForeground, cancelled,
        inboxItemUnreadable, inboxItemNewerVersion, manifestTooLarge, checksumMismatch, linkNotReady,
        counterpartMissing, counterpartFull, deliveryFailed, outboxFileMissing,
        syncSignedOut, syncAccountChanged, syncZoneRemoved, syncMassDeletePaused, syncUploadNeedsConsent,
        syncTransient, syncServerRecordChanged, syncZoneMissing, syncLimitExceeded, syncQuotaExceeded,
        syncUnknownItem, syncFinal,
        textTooLong, captureIDConflict, captureInvalid, revisionStale, revisionForeign, cursorForeign,
        cursorAheadOfStore,
        notFound, idAmbiguous, noteDeleted, segmentCaptureOpen, removeRecordingRefusedNoText,
        moveRefusedOpenCapture, moveRefusedDeletedSegment, moveRefusedConflictCopy, moveRefusedOnlySegment,
        returnRefusedNoteChanged, returnRefusedNoteGone, returnRefusedNoMove,
        jobDiedTwice, illegalTransition,
        hotkeyInvalid, hotkeyTaken, appendWindowInvalid,
        usageMissingText, usageUnknownCommand, usageInvalidArgument,
        accessOff, portUnavailable, unexpected,
    ]
}
