# Error codes

Every error that Knot reports has a stable code. This page has one entry for each code in the error taxonomy, `KnotError.catalog` in `Packages/KnotKit/Sources/KnotCore/Errors/ErrorCatalog.swift`. A test fails when a code has no entry here, or when an entry names another class, next action, retry, write or exit code than the code itself (`docs/architecture.md` §19).

Each entry gives:

- **Class.** A `failure` counts as an attempt. A `deferral` is a step that cannot run now and is never counted: the work runs again when the app comes forward or the model's availability changes. A `final` error is one that no retry on this device can fix: the job ends at once and is not tried again here (`docs/architecture.md` §4).
- **Next.** What to do next, by its stable name.
- **Retry.** Whether repeating the same call is safe, and how often it is worth it.
- **Written.** What was written before the error.
- **Exit code.** The exit code of the `knot` command (`docs/product-spec.md` §10): 0 done, 1 unexpected, 2 usage, 3 ID not found or ambiguous, 4 access off, 5 conflict, 6 store busy, 7 the store needs the owner, 8 incomplete.

A code never changes its meaning. A package that adds a case adds its entry in the same pull request. No error ever contains note text.

## The store and its files

### `disk_full`

The disk filled while Knot wrote. The transaction or the file was not written.

- Class: failure
- Next: free_space
- Retry: safe, as often as needed
- Written: nothing
- Exit code: 1

### `store_busy`

Another writer holds the store for longer than the busy timeout.

- Class: failure
- Next: wait_and_retry
- Retry: safe, as often as needed
- Written: nothing
- Exit code: 6

### `store_damaged`

The store's database cannot be read.

- Class: failure
- Next: follow_troubleshooting_guide
- Retry: not safe
- Written: nothing
- Exit code: 7

### `store_newer_than_build`

The store was written by a newer Knot. This build does not open, change or delete it.

- Class: failure
- Next: update_knot
- Retry: not safe
- Written: nothing
- Exit code: 7

### `store_older_than_tool`

The store is older than the `knot` tool, which never migrates.

- Class: failure
- Next: open_knot
- Retry: safe, as often as needed
- Written: nothing
- Exit code: 7

### `store_not_created_by_knot`

A database at the store's path that Knot did not create, told by its `store_meta` row.

- Class: failure
- Next: follow_troubleshooting_guide
- Retry: not safe
- Written: nothing
- Exit code: 7

### `store_not_open`

The store is not open yet, is migrating, or did not answer in time. Capture goes on into `Inbox/`.

- Class: failure
- Next: wait_and_retry
- Retry: safe, as often as needed
- Written: kept_in_inbox
- Exit code: 6

### `write_failed`

A write to the store or to a file failed for a reason other than a full disk.

- Class: failure
- Next: retry
- Retry: safe, up to 3 times
- Written: nothing
- Exit code: 1

### `group_container_missing`

The app group's container is missing, so `StoreLocations` has no place for `Inbox/`.

- Class: failure
- Next: reinstall_knot
- Retry: not safe
- Written: nothing
- Exit code: 7

### `agent_refused_milestone_store`

`KNOT_AGENT=1` is set and something asked for the milestone store (docs/architecture.md §7).

- Class: failure
- Next: use_development_build
- Retry: not safe
- Written: nothing
- Exit code: 7

### `dev_store_folder_invalid`

A development build on the Mac names no worktree folder for its store, or one that is not safe as a folder name. Development builds from two worktrees never share a store.

- Class: failure
- Next: build_from_worktree
- Retry: not safe
- Written: nothing
- Exit code: 7

## Recording

### `microphone_permission_refused`

The microphone permission was refused.

- Class: failure
- Next: allow_microphone
- Retry: safe, as often as needed
- Written: nothing
- Exit code: 1

### `no_input_device`

No input device is connected.

- Class: failure
- Next: connect_microphone
- Retry: safe, as often as needed
- Written: nothing
- Exit code: 1

### `audio_session_busy`

Another app holds the audio session.

- Class: failure
- Next: wait_and_retry
- Retry: safe, as often as needed
- Written: nothing
- Exit code: 1

### `too_little_space`

Too little free space to start a recording, so Knot refuses to start one.

- Class: failure
- Next: free_space
- Retry: safe, as often as needed
- Written: nothing
- Exit code: 1

### `capture_stopped_disk_full`

The disk filled during a recording or a drawing. The capture stopped with the stop cue.

- Class: failure
- Next: free_space
- Retry: safe, as often as needed
- Written: kept_up_to_failure
- Exit code: 1

### `conversion_failed`

The conversion to the final audio format failed. The working file stays as the recording.

- Class: failure
- Next: retry
- Retry: safe, up to 5 times
- Written: content_kept
- Exit code: 1

### `capture_blocked_by_recording`

A typing or drawing capture cannot start while a recording runs on this device.

- Class: failure
- Next: stop_recording
- Retry: safe, as often as needed
- Written: nothing
- Exit code: 5

## Speech, cleanup and ink

### `speech_model_not_installed`

The speech model is not installed yet, or is still installing. The recording waits, pending, and plays.

- Class: deferral
- Next: wait_for_model
- Retry: safe, as often as needed
- Written: nothing
- Exit code: 1

### `audio_unreadable`

The recording cannot be read. It is kept, with no text. This is final, not a failure to fix.

- Class: final
- Next: none
- Retry: not safe
- Written: content_kept
- Exit code: 1

### `speech_unavailable`

Speech recognition is unavailable on this device. The recording stays recorded and shows as kept with no text here, until another device takes the work. Final on this device.

- Class: final
- Next: none
- Retry: not safe
- Written: content_kept
- Exit code: 1

### `transcription_failed`

The transcriber returned an error. The recording is kept.

- Class: failure
- Next: retry
- Retry: safe, up to 5 times
- Written: content_kept
- Exit code: 1

### `cleanup_model_not_ready`

The cleanup model is still downloading or not ready.

- Class: deferral
- Next: wait_for_model
- Retry: safe, as often as needed
- Written: text_unchanged
- Exit code: 1

### `cleanup_model_unavailable`

The device cannot use the cleanup model. The raw transcript is the final text.

- Class: final
- Next: none
- Retry: not safe
- Written: text_unchanged
- Exit code: 1

### `cleanup_declined`

Cleanup declined: a refusal, a guardrail violation, an empty or malformed result, a result the guard rejected, text too long for the model, an unsupported language or an unsupported request. The raw transcript is the text, and `context.detail` says which.

- Class: failure
- Next: none
- Retry: not safe
- Written: text_unchanged
- Exit code: 1

### `cleanup_timed_out`

Cleanup took longer than its time allows. The raw transcript stays the text, and the job tries again.

- Class: failure
- Next: retry
- Retry: safe, up to 5 times
- Written: text_unchanged
- Exit code: 1

### `recognition_failed`

Handwriting recognition failed. The drawing is kept.

- Class: failure
- Next: retry
- Retry: safe, up to 5 times
- Written: content_kept
- Exit code: 1

## Deferrals: a step that cannot run now

### `requests_limited`

The system limits requests to the model for now. `context.retryAt` says when to try again, when the system gives a time.

- Class: deferral
- Next: wait_and_retry
- Retry: safe, as often as needed
- Written: nothing
- Exit code: 1

### `system_resources_limited`

The system limits its resources for now.

- Class: deferral
- Next: wait_and_retry
- Retry: safe, as often as needed
- Written: nothing
- Exit code: 1

### `no_background_time`

The app has no background time left.

- Class: deferral
- Next: open_knot
- Retry: safe, as often as needed
- Written: nothing
- Exit code: 1

### `device_locked`

The device is locked and the step needs it unlocked.

- Class: deferral
- Next: unlock_device
- Retry: safe, as often as needed
- Written: nothing
- Exit code: 1

## Inbox and watch

### `inbox_item_unreadable`

An inbox item cannot be read. It becomes a failed segment that says so, and the file is kept.

- Class: failure
- Next: report_problem
- Retry: not safe
- Written: content_kept
- Exit code: 1

### `inbox_item_newer_version`

An inbox item was written by a newer Knot. It is kept, and ingested after an update.

- Class: failure
- Next: update_knot
- Retry: safe, as often as needed
- Written: content_kept
- Exit code: 1

### `manifest_too_large`

A manifest is larger than its bound.

- Class: failure
- Next: report_problem
- Retry: not safe
- Written: content_kept
- Exit code: 1

### `checksum_mismatch`

A file from the watch does not match its manifest's checksum. The watch sends it again.

- Class: failure
- Next: wait_and_retry
- Retry: safe, as often as needed
- Written: content_kept
- Exit code: 1

## Sync (docs/architecture.md §11)

### `sync_signed_out`

The device is signed out of iCloud. Sync pauses and the notes stay.

- Class: failure
- Next: sign_in_to_icloud
- Retry: safe, as often as needed
- Written: nothing
- Exit code: 1

### `sync_account_changed`

The device signed in to another iCloud account. Nothing uploads before the answer.

- Class: failure
- Next: answer_upload_question
- Retry: not safe
- Written: nothing
- Exit code: 1

### `sync_zone_removed`

The notes were removed from iCloud. This device keeps its notes and pauses sync.

- Class: failure
- Next: answer_upload_question
- Retry: not safe
- Written: nothing
- Exit code: 1

### `sync_mass_delete_paused`

A fetch would delete more than the set share of the local notes, so sync paused.

- Class: failure
- Next: answer_upload_question
- Retry: not safe
- Written: nothing
- Exit code: 1

### `sync_upload_needs_consent`

A restored store waits for consent before it uploads.

- Class: failure
- Next: answer_upload_question
- Retry: not safe
- Written: nothing
- Exit code: 1

## Text, revisions and cursors

### `text_too_long`

Text is longer than the door it came through allows, such as a title of more than 200 characters.

- Class: failure
- Next: shorten_text
- Retry: not safe
- Written: nothing
- Exit code: 2

### `capture_id_conflict`

The same capture ID with different content.

- Class: failure
- Next: use_new_capture_id
- Retry: not safe
- Written: nothing
- Exit code: 5

### `revision_stale`

The segment or note changed since the revision the caller read.

- Class: failure
- Next: read_again
- Retry: not safe
- Written: nothing
- Exit code: 5

### `revision_foreign`

A revision from another store, or from before a restore of this one.

- Class: failure
- Next: read_again
- Retry: not safe
- Written: nothing
- Exit code: 5

### `cursor_foreign`

A cursor from another store, or from another generation of this one.

- Class: failure
- Next: read_from_start
- Retry: not safe
- Written: nothing
- Exit code: 5

### `cursor_ahead_of_store`

A cursor ahead of the store's change counter.

- Class: failure
- Next: read_from_start
- Retry: not safe
- Written: nothing
- Exit code: 5

### `not_found`

No note or segment has that ID.

- Class: failure
- Next: read_again
- Retry: not safe
- Written: nothing
- Exit code: 3

### `id_ambiguous`

The end of an ID given matches more than one note or segment.

- Class: failure
- Next: give_more_of_the_id
- Retry: not safe
- Written: nothing
- Exit code: 3

### `note_deleted`

A capture was asked into a note that is deleted.

- Class: failure
- Next: read_again
- Retry: not safe
- Written: nothing
- Exit code: 5

### `segment_capture_open`

The segment's capture is still open in the app, so it cannot be edited, deleted or moved.

- Class: failure
- Next: wait_for_capture_to_end
- Retry: safe, as often as needed
- Written: nothing
- Exit code: 5

## Moves and returns (docs/architecture.md §5)

### `move_refused_open_capture`

A move of a segment whose capture is open.

- Class: failure
- Next: wait_for_capture_to_end
- Retry: safe, as often as needed
- Written: nothing
- Exit code: 5

### `move_refused_deleted_segment`

A move of a deleted segment.

- Class: failure
- Next: none
- Retry: not safe
- Written: nothing
- Exit code: 5

### `move_refused_conflict_copy`

A move of a conflict copy, which always stays with the segment it copies.

- Class: failure
- Next: none
- Retry: not safe
- Written: nothing
- Exit code: 5

### `move_refused_only_segment`

A move of the only live segment of its note, apart from its own conflict copies.

- Class: failure
- Next: none
- Retry: not safe
- Written: nothing
- Exit code: 5

### `return_refused_note_changed`

A return after the segment's note changed again since the move.

- Class: failure
- Next: none
- Retry: not safe
- Written: nothing
- Exit code: 5

### `return_refused_note_gone`

A return to a note that is deleted or gone.

- Class: failure
- Next: none
- Retry: not safe
- Written: nothing
- Exit code: 5

### `return_refused_no_move`

A return with no move to undo on this device in the last 30 days.

- Class: failure
- Next: none
- Retry: not safe
- Written: nothing
- Exit code: 3

## Jobs and rules

### `job_died_twice`

A job was found running at launch twice. The process died inside it each time.

- Class: failure
- Next: retry
- Retry: safe, once
- Written: content_kept
- Exit code: 1

### `illegal_transition`

A state machine was asked for a transition it does not have.

- Class: failure
- Next: report_problem
- Retry: not safe
- Written: nothing
- Exit code: 1

## Settings

### `hotkey_invalid`

A hotkey needs at least one modifier, or must be a function key.

- Class: failure
- Next: choose_another_key
- Retry: not safe
- Written: nothing
- Exit code: 2

### `hotkey_taken`

Another app already uses that key.

- Class: failure
- Next: choose_another_key
- Retry: not safe
- Written: nothing
- Exit code: 2

### `append_window_invalid`

An append window outside its range.

- Class: failure
- Next: none
- Retry: not safe
- Written: nothing
- Exit code: 2

## The process

### `access_off`

Command-line access is off on this Mac.

- Class: failure
- Next: turn_on_command_line_access
- Retry: safe, as often as needed
- Written: nothing
- Exit code: 4

### `port_unavailable`

A port of `AppEnvironment.unavailable`: its package has not filled it in yet.

- Class: failure
- Next: report_problem
- Retry: not safe
- Written: nothing
- Exit code: 1

### `unexpected`

Anything else. It carries a request ID once the logging facade records one.

- Class: failure
- Next: report_problem
- Retry: not safe
- Written: unknown
- Exit code: 1

