import KnotCore

/// What each error means, in the words of its entry in `docs/errors.md`, and what to do for
/// each next action. The command line renders them; a test fails when a sentence here differs
/// from the entry, or when a code of `KnotError.catalog` has none.
enum ErrorSentences {
    /// The first paragraph of each code's entry in `docs/errors.md`.
    static let meaning: [ErrorCode: String] = [
        "disk_full":
            "The disk filled while Knot wrote. The transaction or the file was not written.",
        "store_busy":
            "Another writer holds the store for longer than the busy timeout.",
        "store_damaged":
            "The store's database cannot be read.",
        "store_newer_than_build":
            "The store was written by a newer Knot. This build does not open, change or delete it.",
        "store_older_than_tool":
            "The store is older than the `knot` tool, which never migrates.",
        "store_not_created_by_knot":
            "A database at the store's path that Knot did not create, told by its `store_meta` row.",
        "store_not_open":
            "The store is not open yet, is migrating, or did not answer in time. Capture goes on into `Inbox/`.",
        "write_failed":
            "A write to the store or to a file failed for a reason other than a full disk.",
        "group_container_missing":
            "The app group's container is missing, so `StoreLocations` has no place for `Inbox/`.",
        "agent_refused_milestone_store":
            "`KNOT_AGENT=1` is set and something asked for the milestone store (docs/architecture.md §7).",
        "asset_conflict":
            "An asset ID already holds a file with other content. A stored recording or drawing is never replaced, so the new file is refused and the stored one stays.",
        "dev_store_folder_invalid":
            "A development build on the Mac names no worktree folder for its store, or one that is not safe as a folder name. Development builds from two worktrees never share a store.",
        "microphone_permission_refused":
            "The microphone permission was refused.",
        "no_input_device":
            "No input device is connected.",
        "audio_session_busy":
            "Another app holds the audio session.",
        "too_little_space":
            "Too little free space to start a recording, so Knot refuses to start one.",
        "capture_stopped_disk_full":
            "The disk filled during a recording or a drawing. The capture stopped with the stop cue.",
        "conversion_failed":
            "The conversion to the final audio format failed. The working file stays as the recording.",
        "capture_blocked_by_recording":
            "A typing or drawing capture cannot start while a recording runs on this device.",
        "speech_model_not_installed":
            "The speech model is not installed yet, or is still installing. The recording waits, pending, and plays.",
        "audio_unreadable":
            "The recording cannot be read. It is kept, with no text. This is final, not a failure to fix.",
        "speech_unavailable":
            "Speech recognition is unavailable on this device. The recording stays recorded and shows as kept with no text here, until another device takes the work. Final on this device.",
        "transcription_failed":
            "The transcriber returned an error, whose code `context.engineCode` carries. The recording is kept.",
        "cleanup_model_not_ready":
            "The cleanup model is still downloading or not ready.",
        "cleanup_model_unavailable":
            "The device cannot use the cleanup model. The raw transcript is the final text.",
        "cleanup_declined":
            "Cleanup declined: a refusal, a guardrail violation, an empty or malformed result, a result the guard rejected, text too long for the model, an unsupported language or an unsupported request. The raw transcript is the text, and `context.detail` says which.",
        "cleanup_timed_out":
            "Cleanup took longer than its time allows. The raw transcript stays the text, and the job tries again.",
        "recognition_failed":
            "Handwriting recognition failed. The drawing is kept.",
        "drawing_unreadable":
            "The drawing's data cannot be decoded. No retry fixes it: the job ends, and the drawing is kept, shown as \"Kept, no text\".",
        "handwriting_language_unsupported":
            "The recogniser does not read handwriting in the language set. The job ends, and the drawing is kept, shown as \"Kept, no text\".",
        "requests_limited":
            "The system limits requests to the model for now. `context.retryAt` says when to try again, when the system gives a time.",
        "system_resources_limited":
            "The system limits its resources for now.",
        "no_background_time":
            "The app has no background time left.",
        "device_locked":
            "The device is locked and the step needs it unlocked.",
        "app_not_in_foreground":
            "The step runs only while the app is in the foreground, as recognition does (`docs/architecture.md` §10). It is not counted, and it runs when the app comes forward.",
        "cancelled":
            "A step was cancelled: the task that awaited it was cancelled, because background time ran out or the queue was asked to stop. It is a yield: not an attempt, not a decline and not an error, and nothing from the step was saved.",
        "inbox_item_unreadable":
            "An inbox item cannot be read: its manifest, or a body that does not fit its kind, such as a file whose digest is not 64 hexadecimal digits. It becomes a failed segment that says so, and its files are kept in `Inbox/`. When a later version can read the item, it is stored where that failed segment is.",
        "inbox_item_newer_version":
            "An inbox item was written by a newer Knot. It becomes a failed segment that says so, and its files are kept in `Inbox/`. After an update that can read it, it is stored where that failed segment is.",
        "manifest_too_large":
            "A manifest is larger than its bound.",
        "checksum_mismatch":
            "A file does not match the checksum its manifest or its record names: a file from the watch, which the watch sends again; a file placed in, or read from, the asset store; or a file the asset fetcher brought from another device, which is fetched again.",
        "link_not_ready":
            "The watch link's session is not activated yet, or the iPhone is switching watches. The capture waits in the outbox.",
        "counterpart_missing":
            "The other side of the watch link is missing: the devices are not paired, or the other app is not installed. The capture waits in the outbox, shown as waiting.",
        "counterpart_full":
            "The receiving side of the watch link, the iPhone, has no room. The capture waits in the outbox.",
        "delivery_failed":
            "A transfer over the watch link did not complete. It is an attempt, and the capture is queued again.",
        "outbox_file_missing":
            "The outbox file of a capture is missing or cannot be read. The capture fails at once, and its manifest is kept.",
        "sync_signed_out":
            "The device is signed out of iCloud. Sync pauses and the notes stay.",
        "sync_account_changed":
            "The device signed in to another iCloud account. Nothing uploads before the answer.",
        "sync_zone_removed":
            "The notes were removed from iCloud. This device keeps its notes and pauses sync.",
        "sync_mass_delete_paused":
            "A fetch would delete more than the set share of the local notes, so sync paused.",
        "sync_upload_needs_consent":
            "A restored store waits for consent before it uploads.",
        "sync_transient":
            "The network, the account or the service is not available for now, or the server limits requests. The engine retries by itself, and `context.retryAt` says when, when the server gave a time.",
        "sync_server_record_changed":
            "The server holds a newer version of a record. It is merged like a fetched record and sent again.",
        "sync_zone_missing":
            "A send found the zone missing: the user deleted it, or it went with a reset of the encrypted data. It leads to the zone-removed pause.",
        "sync_limit_exceeded":
            "A batch was over the server's limits. The adapter splits it and sends again.",
        "sync_quota_exceeded":
            "The user's iCloud storage is full. Sending stops until the person frees some, and the status says so. A retry after that is safe.",
        "sync_unknown_item":
            "A record is gone from the server. The rule of a long absence decides what follows (`docs/architecture.md` §11).",
        "sync_final":
            "Any other error of the engine. No retry fixes it on this device.",
        "text_too_long":
            "Text is longer than the door it came through allows, such as a title of more than 200 characters.",
        "capture_id_conflict":
            "The same capture ID with different content.",
        "capture_invalid":
            "A capture, or its end, that does not fit its kind: a body of another kind, a file whose digest is not 64 hexadecimal digits, a recording or drawing that starts with its file, a recording that ends stored with no file, or a negative content revision. `record`, `checkpoint` and `end` refuse it, and nothing was written. `setPeaks` refuses level peaks that `RecordingPeaks.isStorable` does not take, bytes of another format or more values than thirty minutes have, and nothing was written either. An inbox item that does not fit is `inbox_item_unreadable` instead.",
        "revision_stale":
            "The segment or note changed since the revision the caller read.",
        "revision_foreign":
            "A revision from another store, or from before a restore of this one.",
        "cursor_foreign":
            "A cursor from another store, or from another generation of this one.",
        "cursor_ahead_of_store":
            "A cursor ahead of the store's change counter.",
        "not_found":
            "No note or segment has that ID.",
        "id_ambiguous":
            "The end of an ID given matches more than one note or segment.",
        "note_deleted":
            "A capture was asked into a note that is deleted.",
        "segment_capture_open":
            "The segment's capture is still open in the app, so it cannot be edited, deleted or moved.",
        "remove_recording_refused_no_text":
            "\"Remove recording\" of a segment that has no text yet. The recording is all there is, and its transcribe job still needs it; once the segment has text, the recording can go and the text stays (`docs/product-spec.md` §7).",
        "move_refused_open_capture":
            "A move of a segment whose capture is open.",
        "move_refused_deleted_segment":
            "A move of a deleted segment.",
        "move_refused_conflict_copy":
            "A move of a conflict copy, which always stays with the segment it copies.",
        "move_refused_only_segment":
            "A move of the only live segment of its note, apart from its own conflict copies.",
        "return_refused_note_changed":
            "A return after the segment's note changed again since the move.",
        "return_refused_note_gone":
            "A return to a note that is deleted or gone.",
        "return_refused_no_move":
            "A return with no move to undo on this device in the last 30 days.",
        "job_died_twice":
            "A job was found running at launch twice. The process died inside it each time.",
        "illegal_transition":
            "A state machine was asked for a transition it does not have, or the store for a change its rules do not allow: `replaceText` with the typed origin, which only a capture's own saves write, a transcription run whose resume point is not after its start, or `setPeaks` on a segment that is not a voice segment, or that has no recording, none yet or one removed.",
        "hotkey_invalid":
            "A hotkey needs at least one modifier, or must be a function key.",
        "hotkey_taken":
            "Another app already uses that key.",
        "append_window_invalid":
            "An append window outside its range.",
        "usage_missing_text":
            "A command that takes text got none, or got text that is empty. Nothing was written.",
        "usage_unknown_command":
            "The first word is not a command.",
        "usage_invalid_argument":
            "A flag or an argument the command does not take, one that lacks its value, a value it cannot read, or a required argument other than text that is missing. Nothing was written.",
        "access_off":
            "Command-line access is off on this Mac.",
        "port_unavailable":
            "A port of `AppEnvironment.unavailable`: its package has not filled it in yet.",
        "unexpected":
            "Anything else. It carries a request ID once the logging facade records one.",
    ]
}

extension ErrorSentences {
    /// What a person or an agent does next, for each next action.
    static func fix(_ next: NextAction) -> String {
        switch next {
        case .none: "Nothing is needed."
        case .retry: "Try again now."
        case .waitAndRetry: "Try again a little later, unchanged."
        case .freeSpace: "Free space on this Mac, then try again."
        case .allowMicrophone: "Allow the microphone in the system's settings."
        case .connectMicrophone: "Connect a microphone."
        case .updateKnot: "Install a newer Knot."
        case .openKnot: "Open Knot, which migrates or repairs what the tool cannot."
        case .followTroubleshootingGuide: "The store needs its owner: follow the troubleshooting guide."
        case .waitForModel: "Wait for the on-device model to arrive. Knot finishes the work by itself."
        case .unlockDevice: "Unlock the device. Knot finishes the work by itself."
        case .signInToICloud: "Sign in to iCloud."
        case .freeICloudStorage: "Free iCloud storage, which is full."
        case .freeIPhoneSpace: "Free space on the iPhone, which the Watch's recordings go to."
        case .answerUploadQuestion: "Answer, in Knot, whether to upload the notes on this device."
        case .readAgain: "Read the note or segment again and use its current revision."
        case .readFromStart: "Read the changes again from the start, without a cursor."
        case .useNewCaptureID: "Use a new capture ID for new content."
        case .shortenText: "Make the text shorter."
        case .chooseAnotherKey: "Choose another hotkey."
        case .turnOnCommandLineAccess:
            "The owner turns on command-line access in Knot's Settings on this Mac. The tool cannot turn it on."
        case .giveMoreOfTheID: "Give a full ID, or more of its last characters."
        case .waitForCaptureToEnd: "Wait for the capture to end in the app."
        case .stopRecording: "Stop the recording before typing or drawing."
        case .useDevelopmentBuild: "Use the development build, knot-dev, and its own store."
        case .buildFromWorktree: "Build the development app from its worktree, which names the worktree's store folder."
        case .reinstallKnot: "Reinstall Knot, whose installation lacks its shared container."
        case .reportProblem: "Report the problem with its code."
        case .seeUsage: "Read the usage, which knot help prints, and run the command again as it says."
        }
    }
}
