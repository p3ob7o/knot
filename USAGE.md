# Using Knot

Knot 0.2.0 captures Markdown into an authorized vault. The macOS app is the supported product; the iOS target is experimental compatibility work.

## First Run

Setup has five resumable steps. Closing Knot during setup does not mark partial settings complete.

1. **Connect Vault:** choose the folder that should be the vault root. A folder without `.obsidian` is valid.
2. **Choose Inbox:** browse to the destination for standalone notes.
3. **Choose Daily Notes:** browse to the daily-note folder and review the filename pattern.
4. **Choose Daily Target:** select a discovered heading, enter a manual heading, or choose end of note. Decide whether a missing heading may be created.
5. **Review Destinations:** confirm the vault, Inbox, Daily path, and target.

Folder browsing deliberately separates navigation from selection:

- Clicking a child opens that child; it does not select it.
- `Use Vault Root` or `Use <folder>` selects the folder currently displayed.
- Back and breadcrumb controls navigate the hierarchy.
- Typing a vault-relative path filters immediate matches. A valid nonexistent path offers an explicit create confirmation.
- An empty path means the vault root.

If today's daily note is absent, Knot may inspect a configured template. You can also choose a sample Markdown file. Large daily notes require explicit `Analyze up to 64 MiB` permission before heading discovery.

Knot proposes valid enabled Obsidian configuration when available. Periodic Notes takes precedence over Core Daily Notes. Imported fields are shown as a diff and can later be undone without reverting unrelated settings changes.

## Quick Capture

1. Press Control-Option-K by default or click the Knot menu-bar item.
2. Type Markdown. Ordinary Return inserts a line break.
3. Leave automatic routing in place, or choose `Today` or `Inbox` for this draft.
4. Press Command-Return, Control-Return, or the arrow button to send.

Escape hides the quick surface and preserves the draft. The eraser button clears through the native text system, so normal Undo can restore the text.

The mode control shows the resolved destination. After a successful send, the next draft returns to automatic routing.

### Automatic Routing

With default settings:

| Input | Destination |
| --- | --- |
| 280 characters or fewer and one line | Today |
| More than 280 characters or any recognized line break | Inbox |

Routing counts trimmed Swift extended grapheme clusters only for the decision. Knot preserves the original nonblank Markdown body, including indentation and trailing spaces. LF, CRLF, lone CR, and Unicode line and paragraph separators count as multiline input.

Manual `Today` remains available for multiline content. Continuation lines are indented under the one bullet instead of becoming independent captures.

### Today

Today appends one formatted capture to the configured daily file. A target can be:

- a heading with a level and title;
- a heading that Knot creates at the end when missing;
- a heading that stops for user review when missing;
- the end of the note.

Knot preserves UTF-8 BOM and CRLF style when present. It does not treat fenced code, indented code, Setext headings, or heading-like text as the selected ATX heading.

Default result:

```markdown
## Quick notes

- 14:32 captured text
```

### Inbox

Inbox creates a new `.md` file and never overwrites an existing note. Same-name collisions receive a counter.

A first line that is exactly an H1 with 1 to 7 whitespace-delimited words supplies a sanitized, Unicode-preserving basename. Knot removes that H1 from the body. Other heading shapes use the configured timestamp filename. Date-generated parent folders are retained in either case.

## Rich Inbox Editor

Choose the square-and-pencil button from the quick surface to promote its current draft into the optional rich editor. The rich editor is an Inbox composer, not an existing-vault-note editor.

It supports paragraphs, headings, ordered and unordered lists, quotes, code, separators, links, formatting, and images. Images can come from paste, drop, or the native picker. Supported input types are PNG, JPEG, GIF, WebP, and HEIC, subject to per-file, per-draft, dimension, and decoded-pixel limits.

The editor writes acknowledged checkpoints to Knot's local store. `Save` first durably enqueues the exact checkpoint and its attachments, then publishes it to Inbox. Closing asks the web editor for a final local checkpoint; if that acknowledgement fails, Knot offers Keep Open, Export, or explicit Discard.

External links open only from a direct link activation in the editor. Scripted bridge requests and file, data, blob, and custom-scheme navigation cannot gain native privileges.

## Status And Recovery

Status language is intentional:

- **Saving draft:** the native draft checkpoint is being updated.
- **Pending:** the immutable capture and required assets are durable locally, but vault publication is not complete.
- **Saved to vault:** the note and attachments were published and a receipt was recorded.
- **Retryable:** publication did not begin or is known safe to retry with the original snapshot.
- **Needs review:** an interrupted or externally changed operation has an uncertain outcome. Knot will not duplicate it automatically.

Right-click the menu-bar item and choose `Recovery...`. The recovery window can:

- reopen a local draft;
- export a draft or capture as Markdown;
- retry or cancel a pending capture;
- mark a needs-review capture already saved after checking the target;
- retry a needs-review capture as new, after an explicit duplicate-content warning.

Retry uses the capture's original vault identity, destination, timestamp, timezone, locale, settings revision, and asset IDs. Changing settings later does not reinterpret pending work.

## Settings

Right-click the menu-bar item and choose `Settings...`. Settings use a working copy: `Apply` validates and commits changes; `Cancel` restores the last committed values.

### Vault

- **Change:** authorize another vault. Current drafts and pending captures remain associated with their stored profile.
- **Reimport:** inspect Obsidian configuration again.
- **Undo Import:** restore only fields changed by the relevant import.

### Global Shortcut

Click the recorder and press one character key with Command, Control, or Option; Shift can be included. Delete disables the shortcut and Escape cancels recording. Knot reports registration conflicts and preserves the previous working binding when replacement fails.

Imported legacy bare-key shortcuts remain disabled until separately approved because they can intercept normal typing. Key code zero is a valid `A` key, not the disabled sentinel.

### Daily And Inbox

- Daily folder and Inbox folder are validated vault-relative paths. Empty means root.
- Daily and Inbox filename values use the supported date grammar below and omit `.md`.
- The Daily heading is an ATX heading such as `## Quick notes`.
- The Daily bullet template must contain exact `{{content}}`.
- Settings shows the generated Daily path before Apply.

### Attachments

The destination follows Obsidian-compatible path meanings:

- empty or `/`: vault root;
- `.`: beside the note;
- `./assets`: an `assets` folder beside the note;
- another relative path: that folder under the vault root.

### Local Data And Reset

`Erase Local Drafts` deletes active and parked drafts only. It does not delete pending captures or any vault file.

`Reset Configuration` clears the current vault configuration, global shortcut, and saved detached-window state, then restarts setup. Drafts and pending captures remain in Recovery, and vault files are not deleted.

## Format Reference

Knot implements this validated Moment-compatible date-token subset:

```text
YYYY GGGG MMMM DDDo DDDD SSS MMM DDD dddd
YY GG MM Mo DD Do ddd dd ww wo WW Wo HH hh kk mm ss SS ZZ
Qo Q M D do d E w W H h k m s S A a Z X x
```

Literal text goes in brackets. Slashes create subfolders:

```text
[Notes]/YYYY/MM/YYYY-MM-DD
```

Unknown letter tokens, unmatched brackets, unsafe generated paths, and patterns over the size limit are rejected.

Bullet templates use double braces. `{{content}}` is required; every other placeholder is one supported date pattern:

```text
- {{HH:mm}} {{content}}
- [[{{YYYY-MM-DD}}]] {{HH:mm}} {{content}}
```

## Window Behavior

The quick editor normally appears as a menu-bar popover. Use the context menu to detach or reattach it, or drag the popover using the system detach gesture. The detached window remembers a constrained on-screen frame. Settings, Recovery, and the rich editor are regular windows and can coexist without changing the quick draft's ownership.

## Privacy And Sync Limits

Knot's application runtime is local-only: no account, server, telemetry, remote font, runtime CDN, or network API. Build tooling downloads pinned dependencies when they are not already cached.

The vault bookmark, durable drafts, pending captures, journals, receipts, and staged assets live in Knot's app container. The app requests access only to the selected vault and files explicitly chosen for import.

Knot coordinates local file access and detects changed identities and hashes. It does not provide distributed locking, control an external sync provider, prescribe provider conflict filenames, or guarantee that another device cannot create an independent conflict.
