# The `knot` command

<!-- Made from the command table, Packages/KnotKit/Sources/KnotAgent/CommandTable.swift, and the golden files of its examples. Do not edit by hand: a test fails when this page differs from what they give. -->

`knot` reads and writes your notes from a shell or an agent, on the Mac (`docs/product-spec.md` §10). It is off until command-line access is turned on in Knot's Settings on that Mac, and no command ever asks anything. A development build is `knot-dev`, with its own store.

The examples on this page run on a test's store, with its clock and its IDs, and a test runs each of them again.

Every command takes `--json`. A result goes to standard output and everything else to standard error. JSON output carries `schema`, the number of its schema, 1 today, which changes only on a breaking change.

## Quick start

Three commands: see the store, capture a line, read it back.

```console
$ knot status
tool: knot 1.0 (dev)
store: in memory
store_id: 01a1ee56-5e00-7003-8724-6d77eff2ad7f
cursor: 01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.0
command_line_access: on
sync: off
append_window: 5 minutes
next_capture: starts a new note (no_earlier_capture)
output_schema: 1
```

```console
$ knot add 'Water the plants on Friday'
new note 01a1ee57-4860-7005-8704-c879c789544b (no_earlier_capture)
capture_id: 01a1ee57-4860-7004-b77b-fa39b2a42b6f
segment_id: 01a1ee57-4860-7004-b77b-fa39b2a42b6f
outcome: stored
revision: 01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.1
cursor: 01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.1
sync: off
```

```console
$ knot list
note 01a1ee57-4860-7005-8704-c879c789544b  unsettled, settles at 2026-11-18T11:12:40Z
  last_capture: 2026-11-18T11:07:40Z
  revision: 01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.1
  segment 01a1ee57-4860-7004-b77b-fa39b2a42b6f  typed, ready, from cli, revision 01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.1
    | Water the plants on Friday

cursor: 01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.1
sync: off
```

## Commands

### `knot status`

Shows the store, how current it is, the open window and the versions in use.

```
knot status [--json]
```

- `--json`: Prints the result, or the error, as JSON.

```console
$ knot status
tool: knot 1.0 (dev)
store: in memory
store_id: 01a1ee56-5e00-7003-8724-6d77eff2ad7f
cursor: 01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.1
command_line_access: on
sync: off
append_window: 5 minutes
next_capture: joins note 01a1ee57-4860-7005-8704-c879c789544b (inside_window)
window_closes_at: 2026-11-18T11:12:40Z
output_schema: 1
```

```console
$ knot status --json
{
  "schema": 1,
  "tool": {
    "name": "knot",
    "version": "1.0",
    "flavour": "dev"
  },
  "store": {
    "location": "in memory",
    "store_id": "01a1ee56-5e00-7003-8724-6d77eff2ad7f",
    "generation": 0,
    "cursor": "01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.1"
  },
  "command_line_access": "on",
  "sync": "off",
  "append_window_minutes": 5,
  "next_capture": {
    "placement": "joins_note",
    "note_id": "01a1ee57-4860-7005-8704-c879c789544b",
    "reason": "inside_window",
    "window_closes_at": "2026-11-18T11:12:40Z"
  }
}
```

### `knot add`

Captures text, following the append window. `--new` forces a new note.

```
knot add [--new] [--capture-id <id>] [--json] <text> | -
```

- `<text>`: The text to capture. A single `-` reads it from standard input.
- `--new`: Starts a new note, inside the window too.
- `--capture-id <id>`: A full ID for the capture. Repeating the command with it changes nothing and answers with the capture as it is stored; the same ID with other text is refused.
- `--json`: Prints the result, or the error, as JSON.

```console
$ knot add 'Call the plumber about the boiler'
joined note 01a1ee57-4860-7005-8704-c879c789544b (inside_window)
capture_id: 01a1ee59-1d20-7006-832d-ffc1d17c83f7
segment_id: 01a1ee59-1d20-7006-832d-ffc1d17c83f7
outcome: stored
revision: 01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.1
cursor: 01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.2
sync: off
```

```console
$ knot add --json 'Ask Sam for the model number of the boiler'
{
  "schema": 1,
  "capture_id": "01a1ee59-9250-7007-8226-40675f51d85f",
  "note_id": "01a1ee57-4860-7005-8704-c879c789544b",
  "segment_ids": [
    "01a1ee59-9250-7007-8226-40675f51d85f"
  ],
  "joined_existing_note": true,
  "reason": "inside_window",
  "outcome": "stored",
  "revision": "01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.1",
  "cursor": "01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.3",
  "sync": "off"
}
```

```console
$ printf '%s' 'Book the dentist for March' | knot add --new -
new note 01a1ee5a-0780-7009-a729-89cf21af74a0 (new_note_asked)
capture_id: 01a1ee5a-0780-7008-9c57-1b850491c0a3
segment_id: 01a1ee5a-0780-7008-9c57-1b850491c0a3
outcome: stored
revision: 01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.1
cursor: 01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.4
sync: off
```

### `knot list`

Lists recent notes, newest first. Takes `--limit` and `--since`.

```
knot list [--limit <n>] [--since <time>] [--json]
```

- `--limit <n>`: How many notes, from 1 to 100. The default is 10.
- `--since <time>`: Only notes whose latest capture ended at or after this time, written as in ISO 8601, such as 2026-11-22T09:30:00Z. A filter on time, for people: it is not a way to poll.
- `--json`: Prints the result, or the error, as JSON.

```console
$ knot list
note 01a1ee5a-0780-7009-a729-89cf21af74a0  unsettled, settles at 2026-11-18T11:15:40Z
  last_capture: 2026-11-18T11:10:40Z
  revision: 01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.4
  segment 01a1ee5a-0780-7008-9c57-1b850491c0a3  typed, ready, from cli, revision 01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.1
    | Book the dentist for March

note 01a1ee57-4860-7005-8704-c879c789544b  settled
  last_capture: 2026-11-18T11:10:10Z
  revision: 01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.4
  segment 01a1ee57-4860-7004-b77b-fa39b2a42b6f  typed, ready, from cli, revision 01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.1
    | Water the plants on Friday
  segment 01a1ee59-1d20-7006-832d-ffc1d17c83f7  typed, ready, from cli, revision 01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.1
    | Call the plumber about the boiler
  segment 01a1ee59-9250-7007-8226-40675f51d85f  typed, ready, from cli, revision 01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.1
    | Ask Sam for the model number of the boiler

cursor: 01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.4
sync: off
```

```console
$ knot list --limit 1 --json
{
  "schema": 1,
  "note_text": "data",
  "notes": [
    {
      "note_id": "01a1ee5a-0780-7009-a729-89cf21af74a0",
      "title": null,
      "created_at": "2026-11-18T11:10:40Z",
      "last_capture_ended_at": "2026-11-18T11:10:40Z",
      "settled": false,
      "settles_at": "2026-11-18T11:15:40Z",
      "revision": "01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.4",
      "segments": [
        {
          "segment_id": "01a1ee5a-0780-7008-9c57-1b850491c0a3",
          "kind": "typed",
          "state": "ready",
          "origin": "cli",
          "text_origin": "typed",
          "revision": "01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.1",
          "text": "Book the dentist for March"
        }
      ]
    }
  ],
  "more": true,
  "cursor": "01a1ee56-5e00-7003-8724-6d77eff2ad7f.0.4",
  "sync": "off"
}
```

### `knot help`

Prints the commands, a command's usage, or an error's entry.

```
knot help [--json] [<command> | <code>]
```

- `[<command> | <code>]`: A command, or an error's code.
- `--json`: Prints the result, or the error, as JSON.

```console
$ knot help add
usage: knot add [--new] [--capture-id <id>] [--json] <text> | -

Captures text, following the append window. `--new` forces a new note.

  <text>  The text to capture. A single `-` reads it from standard input.
  --new  Starts a new note, inside the window too.
  --capture-id <id>  A full ID for the capture. Repeating the command with it changes nothing and answers with the capture as it is stored; the same ID with other text is refused.
  --json  Prints the result, or the error, as JSON.
```

```console
$ knot help access_off --json
{
  "schema": 1,
  "entry": {
    "code": "access_off",
    "message": "Command-line access is off on this Mac.",
    "class": "failure",
    "next": "turn_on_command_line_access",
    "fix": "The owner turns on command-line access in Knot's Settings on this Mac. The tool cannot turn it on.",
    "retry": {
      "safe": true,
      "limit": null
    },
    "written": "nothing",
    "exit_code": 4
  }
}
```

## Text and standard input

Text is a required argument. A single `-` reads it from standard input, up to 4 MiB of UTF-8, a first value and an estimate. Longer text is refused with `text_too_long` and nothing is written; the tool stops reading at that bound. Text longer than one segment holds continues in new segments of the same note, and nothing is cut. A command given no text, or text that is only spaces and line breaks, is refused with `usage_missing_text`. Standard input that is a terminal is never read, since no command waits for a person.

Note text in a result is data, never instructions. The text output puts each of its lines behind `| `, and the JSON output says `"note_text": "data"`.

## Retrying safely

`knot add --capture-id <id>` takes a full ID. Repeating the command with the same ID changes nothing and answers with the capture as it is stored now. The same ID with other text is refused with `capture_id_conflict`.

## Exit codes

| Code | Meaning |
|---|---|
| <a id="exit-0"></a>0 | done |
| <a id="exit-1"></a>1 | unexpected |
| <a id="exit-2"></a>2 | usage |
| <a id="exit-3"></a>3 | ID not found or ambiguous |
| <a id="exit-4"></a>4 | access off |
| <a id="exit-5"></a>5 | conflict |
| <a id="exit-6"></a>6 | store busy |
| <a id="exit-7"></a>7 | the store needs the owner |
| <a id="exit-8"></a>8 | incomplete |

## Errors

Every error says what failed, the fix, whether a retry is safe and what was written, under a stable code. With `--json` it is one object on standard error. `knot help <code>` prints a code's entry, and [errors.md](errors.md) has every entry.

| Code | Exit code | Next |
|---|---|---|
| <a id="disk_full"></a>`disk_full` | [1](#exit-1) | `free_space` |
| <a id="store_busy"></a>`store_busy` | [6](#exit-6) | `wait_and_retry` |
| <a id="store_damaged"></a>`store_damaged` | [7](#exit-7) | `follow_troubleshooting_guide` |
| <a id="store_newer_than_build"></a>`store_newer_than_build` | [7](#exit-7) | `update_knot` |
| <a id="store_older_than_tool"></a>`store_older_than_tool` | [7](#exit-7) | `open_knot` |
| <a id="store_not_created_by_knot"></a>`store_not_created_by_knot` | [7](#exit-7) | `follow_troubleshooting_guide` |
| <a id="store_not_open"></a>`store_not_open` | [6](#exit-6) | `wait_and_retry` |
| <a id="write_failed"></a>`write_failed` | [1](#exit-1) | `retry` |
| <a id="group_container_missing"></a>`group_container_missing` | [7](#exit-7) | `reinstall_knot` |
| <a id="agent_refused_milestone_store"></a>`agent_refused_milestone_store` | [7](#exit-7) | `use_development_build` |
| <a id="asset_conflict"></a>`asset_conflict` | [5](#exit-5) | `report_problem` |
| <a id="dev_store_folder_invalid"></a>`dev_store_folder_invalid` | [7](#exit-7) | `build_from_worktree` |
| <a id="microphone_permission_refused"></a>`microphone_permission_refused` | [1](#exit-1) | `allow_microphone` |
| <a id="no_input_device"></a>`no_input_device` | [1](#exit-1) | `connect_microphone` |
| <a id="audio_session_busy"></a>`audio_session_busy` | [1](#exit-1) | `wait_and_retry` |
| <a id="too_little_space"></a>`too_little_space` | [1](#exit-1) | `free_space` |
| <a id="capture_stopped_disk_full"></a>`capture_stopped_disk_full` | [1](#exit-1) | `free_space` |
| <a id="conversion_failed"></a>`conversion_failed` | [1](#exit-1) | `retry` |
| <a id="capture_blocked_by_recording"></a>`capture_blocked_by_recording` | [5](#exit-5) | `stop_recording` |
| <a id="speech_model_not_installed"></a>`speech_model_not_installed` | [1](#exit-1) | `wait_for_model` |
| <a id="audio_unreadable"></a>`audio_unreadable` | [1](#exit-1) | `none` |
| <a id="speech_unavailable"></a>`speech_unavailable` | [1](#exit-1) | `none` |
| <a id="transcription_failed"></a>`transcription_failed` | [1](#exit-1) | `retry` |
| <a id="cleanup_model_not_ready"></a>`cleanup_model_not_ready` | [1](#exit-1) | `wait_for_model` |
| <a id="cleanup_model_unavailable"></a>`cleanup_model_unavailable` | [1](#exit-1) | `none` |
| <a id="cleanup_declined"></a>`cleanup_declined` | [1](#exit-1) | `none` |
| <a id="cleanup_timed_out"></a>`cleanup_timed_out` | [1](#exit-1) | `retry` |
| <a id="recognition_failed"></a>`recognition_failed` | [1](#exit-1) | `retry` |
| <a id="drawing_unreadable"></a>`drawing_unreadable` | [1](#exit-1) | `none` |
| <a id="handwriting_language_unsupported"></a>`handwriting_language_unsupported` | [1](#exit-1) | `none` |
| <a id="requests_limited"></a>`requests_limited` | [1](#exit-1) | `wait_and_retry` |
| <a id="system_resources_limited"></a>`system_resources_limited` | [1](#exit-1) | `wait_and_retry` |
| <a id="no_background_time"></a>`no_background_time` | [1](#exit-1) | `open_knot` |
| <a id="device_locked"></a>`device_locked` | [1](#exit-1) | `unlock_device` |
| <a id="app_not_in_foreground"></a>`app_not_in_foreground` | [1](#exit-1) | `open_knot` |
| <a id="cancelled"></a>`cancelled` | [1](#exit-1) | `none` |
| <a id="inbox_item_unreadable"></a>`inbox_item_unreadable` | [1](#exit-1) | `report_problem` |
| <a id="inbox_item_newer_version"></a>`inbox_item_newer_version` | [1](#exit-1) | `update_knot` |
| <a id="manifest_too_large"></a>`manifest_too_large` | [1](#exit-1) | `report_problem` |
| <a id="checksum_mismatch"></a>`checksum_mismatch` | [1](#exit-1) | `wait_and_retry` |
| <a id="link_not_ready"></a>`link_not_ready` | [1](#exit-1) | `wait_and_retry` |
| <a id="counterpart_missing"></a>`counterpart_missing` | [1](#exit-1) | `wait_and_retry` |
| <a id="counterpart_full"></a>`counterpart_full` | [1](#exit-1) | `free_iphone_space` |
| <a id="delivery_failed"></a>`delivery_failed` | [1](#exit-1) | `wait_and_retry` |
| <a id="outbox_file_missing"></a>`outbox_file_missing` | [1](#exit-1) | `report_problem` |
| <a id="sync_signed_out"></a>`sync_signed_out` | [1](#exit-1) | `sign_in_to_icloud` |
| <a id="sync_account_changed"></a>`sync_account_changed` | [1](#exit-1) | `answer_upload_question` |
| <a id="sync_zone_removed"></a>`sync_zone_removed` | [1](#exit-1) | `answer_upload_question` |
| <a id="sync_mass_delete_paused"></a>`sync_mass_delete_paused` | [1](#exit-1) | `answer_upload_question` |
| <a id="sync_upload_needs_consent"></a>`sync_upload_needs_consent` | [1](#exit-1) | `answer_upload_question` |
| <a id="sync_transient"></a>`sync_transient` | [1](#exit-1) | `wait_and_retry` |
| <a id="sync_server_record_changed"></a>`sync_server_record_changed` | [1](#exit-1) | `retry` |
| <a id="sync_zone_missing"></a>`sync_zone_missing` | [1](#exit-1) | `answer_upload_question` |
| <a id="sync_limit_exceeded"></a>`sync_limit_exceeded` | [1](#exit-1) | `retry` |
| <a id="sync_quota_exceeded"></a>`sync_quota_exceeded` | [1](#exit-1) | `free_icloud_storage` |
| <a id="sync_unknown_item"></a>`sync_unknown_item` | [1](#exit-1) | `none` |
| <a id="sync_final"></a>`sync_final` | [1](#exit-1) | `report_problem` |
| <a id="text_too_long"></a>`text_too_long` | [2](#exit-2) | `shorten_text` |
| <a id="capture_id_conflict"></a>`capture_id_conflict` | [5](#exit-5) | `use_new_capture_id` |
| <a id="capture_invalid"></a>`capture_invalid` | [1](#exit-1) | `report_problem` |
| <a id="revision_stale"></a>`revision_stale` | [5](#exit-5) | `read_again` |
| <a id="revision_foreign"></a>`revision_foreign` | [5](#exit-5) | `read_again` |
| <a id="cursor_foreign"></a>`cursor_foreign` | [5](#exit-5) | `read_from_start` |
| <a id="cursor_ahead_of_store"></a>`cursor_ahead_of_store` | [5](#exit-5) | `read_from_start` |
| <a id="not_found"></a>`not_found` | [3](#exit-3) | `read_again` |
| <a id="id_ambiguous"></a>`id_ambiguous` | [3](#exit-3) | `give_more_of_the_id` |
| <a id="note_deleted"></a>`note_deleted` | [5](#exit-5) | `read_again` |
| <a id="segment_capture_open"></a>`segment_capture_open` | [5](#exit-5) | `wait_for_capture_to_end` |
| <a id="remove_recording_refused_no_text"></a>`remove_recording_refused_no_text` | [5](#exit-5) | `wait_and_retry` |
| <a id="move_refused_open_capture"></a>`move_refused_open_capture` | [5](#exit-5) | `wait_for_capture_to_end` |
| <a id="move_refused_deleted_segment"></a>`move_refused_deleted_segment` | [5](#exit-5) | `none` |
| <a id="move_refused_conflict_copy"></a>`move_refused_conflict_copy` | [5](#exit-5) | `none` |
| <a id="move_refused_only_segment"></a>`move_refused_only_segment` | [5](#exit-5) | `none` |
| <a id="return_refused_note_changed"></a>`return_refused_note_changed` | [5](#exit-5) | `none` |
| <a id="return_refused_note_gone"></a>`return_refused_note_gone` | [5](#exit-5) | `none` |
| <a id="return_refused_no_move"></a>`return_refused_no_move` | [3](#exit-3) | `none` |
| <a id="job_died_twice"></a>`job_died_twice` | [1](#exit-1) | `retry` |
| <a id="illegal_transition"></a>`illegal_transition` | [1](#exit-1) | `report_problem` |
| <a id="hotkey_invalid"></a>`hotkey_invalid` | [2](#exit-2) | `choose_another_key` |
| <a id="hotkey_taken"></a>`hotkey_taken` | [2](#exit-2) | `choose_another_key` |
| <a id="append_window_invalid"></a>`append_window_invalid` | [2](#exit-2) | `none` |
| <a id="usage_missing_text"></a>`usage_missing_text` | [2](#exit-2) | `see_usage` |
| <a id="usage_unknown_command"></a>`usage_unknown_command` | [2](#exit-2) | `see_usage` |
| <a id="usage_invalid_argument"></a>`usage_invalid_argument` | [2](#exit-2) | `see_usage` |
| <a id="access_off"></a>`access_off` | [4](#exit-4) | `turn_on_command_line_access` |
| <a id="port_unavailable"></a>`port_unavailable` | [1](#exit-1) | `report_problem` |
| <a id="unexpected"></a>`unexpected` | [1](#exit-1) | `report_problem` |
