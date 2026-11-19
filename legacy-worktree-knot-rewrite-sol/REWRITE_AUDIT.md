# Knot Rewrite Audit

Audit baseline: commit `3a4bb5b` on `codex/gutenberg-editor`, inspected on 2026-09-07/08. This includes the macOS Gutenberg editor and attachment work, not just `main` or the v0.2.0 tag. The primary checkout was clean after that commit was pushed. The former Codex worktree no longer exists.

Implementation handoff: [REWRITE_PLAN.md](REWRITE_PLAN.md). This audit describes the existing implementation; the plan specifies the replacement. Neither document claims that the replacement has been implemented.

## Executive Assessment

Knot has a useful, compact product model: quick capture into an existing vault, with configurable daily-note and Inbox destinations. Keep that model. The highest-value rewrite is not a broader note-management application. It is a trustworthy capture pipeline with responsive native surfaces and an optional rich editor.

The critical issues are possible loss of existing daily-note content, unsafe filesystem paths, non-exclusive Inbox publication, and drafts/outbox/assets that do not form a recoverable operation. Onboarding and window state are also coupled to view lifetimes. The richer editor adds content-conversion, resource-loading, and native-bridge risks that the existing core tests cannot detect.

There is no basis for promising an exhaustive list of every possible defect. This is a source-wide, risk-prioritized analysis of the current app, its tests, configuration, build/release scripts, and documentation. Performance opportunities below are distinguished from measured regressions.

## Evidence And Limits

| Check | Observed result | What it proves / does not prove |
| --- | --- | --- |
| Current KnotKit suite | 100 tests, zero failures; full Xcode selected per command | Existing core expectations pass. Does not cover EditorModel races, onboarding lifecycle, WKWebView, or signing. |
| macOS Debug build | `BUILD SUCCEEDED`, unsigned snapshot build with Xcode beta | Swift/AppKit integration compiles with the available toolchain and copied existing web distribution. Not a clean npm build, UI test, or sandbox-access test. |
| Data-safety harness | Ten cases reproduce unsafe behavior; see `rewrite-evidence/` | Runs actual baseline core code against disposable fixtures. No user vault was used. |
| Web tests | Initial worker-startup timeouts; bounded single-thread retry also ran no assertions before 30s termination | Environment/dependency-startup limitation, not evidence of failing serializer assertions. |
| Additional JS harness | Did not finish loading installed JSDOM; explicitly stopped | Serializer findings below are source-derived, not represented as runtime reproduction. |
| Historic vault-selection beachball | Not reproduced interactively in this audit | Blocking calls on the main actor are present. Their role in that exact incident is not established. |
| UI, accessibility, Instruments, cloud providers | Not run against the app | Proposed budgets and UI acceptance tests are requirements, not current measurements. |
| iOS, signed release, notarization | Not tested | iOS remains outside the macOS release claim. |

The initial Swift test attempt with standalone Command Line Tools could not find XCTest. Using `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` fixed the environment without changing global Xcode selection. The machine-local dependency directories have sparse/cloud-backed files; their allocated `du` sizes are not meaningful bundle or installation-size measurements. The existing generated JavaScript asset has a logical size of 3,640,609 bytes.

Baseline source links use the immutable [audited commit](https://github.com/p3ob7o/knot/tree/3a4bb5b). In the tables, `Kit/` means `Packages/KnotKit/Sources/KnotKit/`; app paths are repository-relative. Line numbers refer to this commit, not future rewritten files.

Severity: P0 = potential destructive write outside the intended target or loss of existing content; P1 = capture reliability/security/release blocker; P2 = important usability, maintainability, or performance improvement. These are engineering priorities, not remotely exploitable vulnerability ratings.

## Findings

### Data Integrity And Security

| ID | Priority / evidence | Finding and source | Required outcome |
| --- | --- | --- | --- |
| F01 | P0 / reproduced R01 | `Kit/DailyAppender.swift:52` treats an unreadable or invalid-UTF-8 daily note as empty, then atomically replaces it. Atomic replacement does not make the fallback safe. | Fail closed on read/decoding errors. Preserve bytes and keep the capture pending. |
| F02 | P0 / reproduced R04-R05 | `Kit/VaultStructure.swift:37` normalizes without rejecting `..`; `DailyAppender.swift:20` and `InboxWriter.swift:31` build unrestricted paths. `AttachmentWriter.swift:138` checks standardized components but follows symlinks. | Validate configured and generated paths, reject descendant symlinks, and enforce containment during actual I/O. |
| F03 | P1 / reproduced R03 | `Kit/InboxWriter.swift:31` selects a free filename before coordinated writing; `:65` later writes with replacement semantics. Two plans can select one URL and the second overwrites the first. Attachment naming has the same check-then-write pattern at `AttachmentWriter.swift:43`. | No-clobber publication, collision handling at commit, and concurrent-writer tests. |
| F04 | P1 / source | `Knot/Shared/EditorModel.swift:274` clears current content after saving an older snapshot. The editor remains editable during send. `:345` reset also clears content without invalidating in-flight completion. `GutenbergEditorWindowController.swift:17` replaces an existing editor root on reopen. | Revisioned durable drafts; completion only acknowledges its own snapshot. Closing, reset, detachment, and reopen must preserve newer content. |
| F05 | P1 / source + R08 | `Kit/Queue.swift:15` has unsynchronized append; `:29` silently discards malformed records. No app caller replays `loadAll`. `EditorModel.swift:60,189,264` ignores queue creation/enqueue failures. Notes lack vault/settings/assets context. | Transactional outbox with explicit recovery, acknowledgments, retry, corrupt-record preservation, and no automatic legacy-vault inference. |
| F06 | P1 / source | `EditorModel.swift:232` writes rich-editor assets and note directly after bookmark probing has ended its access scope. Unlike `Vault.write`, it never starts its own scope. Assets may be left behind; a queued failure may contain unresolved tokens or stripped content without attachment bytes. | One vault-access lifetime and one durable multi-file operation journal for plain and rich captures. |
| F07 | P1 / reproduced R02,R06,R07 | `Kit/HeadingSplicer.swift:25` returns the original document for a blank heading while callers report success. `:48,104` can match headings inside fenced examples. `VaultStructure.swift:146` also lists those headings with duplicate raw-text IDs. | Shared Markdown-aware discovery/splicing, explicit end-of-note mode, stable occurrence selection, and verified insertion. |
| F08 | P1 / reproduced R09 + source | A bullet template without `{{content}}` silently discards the thought. `AppSettings.swift:93` defaults the entire settings object on malformed JSON; `MomentFormat.swift:95` treats unsupported tokens as literals, despite README's broader claims. | Validated versioned settings with previews, migration backup, mandatory content placeholder, and explicit supported-format grammar. |
| F09 | P1 / source | `GutenbergWeb/src/serializer.js:23,74` reads old quote attributes instead of nested blocks; `:30` drops unknown blocks. `:57` ignores ordered-list start. Inline conversion lacks Markdown escaping, links permit unsafe schemes, and code fences are only three/four ticks. `blockSpecs.js:49` parses only a leading H1, flattening other Markdown on promotion. | Grammar-backed conversion, nested-block fixtures, source preservation for unsupported syntax, safe link policy, and no silent deletion. |
| F10 | P1 / source | `GutenbergEditorWindowController.swift:403` accepts messages based on body/type, not main frame, origin, version, draft, or request identity. `:440` permits arbitrary file/about/blob/data navigations. The manually assembled shell at `:296` allows inline/blob/data scripts. | Exact local-resource allowlist, main-frame/session-validated bridge, bounded schemas, strict navigation, restrictive CSP. No remote exploit is asserted. |
| F11 | P1 / source | `GutenbergWeb/src/main.jsx:120,153` reads image files as whole base64 strings and retains them; `GutenbergEditorWindowController.swift:138` decodes unbounded payloads on the main actor. `AttachmentWriter.swift:107` has no byte/type/pixel limit or wiki-link delimiter escaping. | Native streamed staging, content validation, bounded transfers, safe embeds, and owned-asset cleanup. |

The traversal and symlink reproductions use a temporary unsandboxed harness. They prove missing containment in Knot's core, not that macOS sandbox restrictions can universally be escaped. A surrounding path already accessible to the process can still be damaged; the app must enforce the user's selected-vault intent independently of ambient permissions.

### Onboarding And Everyday Use

| ID | Priority / evidence | Finding and source | Required outcome |
| --- | --- | --- | --- |
| F12 | P1 / source | `EditorModel.swift:359` treats a stored bookmark without a completion key as legacy-complete. First setup stores the bookmark before completion; quitting mid-wizard can skip the remaining questions next time. `OnboardingView.swift:41` reseeds on appearance. | Persist an incomplete onboarding transaction immediately; resume its exact state; commit configuration only on Finish. |
| F13 | P1 / source | `EditorModel.swift:83,100,166` probes/imports vault files on the main actor; `OnboardingView.swift:413` synchronously reads/parses today's note. A large, offline, or coordinated file can stall UI. | Asynchronous, bounded filesystem operations with visible loading/retry states and cancellation generations. |
| F14 | P2 / source | `OnboardingView.swift:212,248,310` uses an unfiltered cached-path lookup, eager folder rows, and a 170pt list in a fixed-height surface. Child clicks both choose and navigate. It does not implement the requested distinction between entering a child and selecting the current folder. | Taller adaptive setup surface; immediate children only; pinned select-current action; breadcrumb/back; actual component autocomplete and virtualized rows. |
| F15 | P1 / source | `OnboardingView.swift:442,471` rebuilds known-folder sets while typing; cache/tasks are keyed by path, not vault identity/generation. Late results from an old vault can replace a new vault's same path; errors look empty. | Bounded identity-keyed cache, latest-request validation, invalidation, and separate empty/error/offline states. |
| F16 | P1 / source | `Kit/VaultStore.swift:83,92` refreshes stale bookmarks before starting scope and compresses several failure modes into inaccessible state. No writability classification. `MenuBarController.swift:103` opens without refreshing access. | Distinguish missing, denied, read-only, provider-offline, and reconnect-required; retain the original profile and pending captures. |
| F17 | P2 / source | `OnboardingView.swift:413,420` consults only today's note and silently chooses the first heading if the saved heading is absent. Import undo at `EditorModel.swift:135` restores all previous settings, potentially reverting later Inbox edits. | Show discovery provenance and missing-heading choices; static template/sample fallback; field-scoped, revision-aware import undo. |
| F18 | P1 / source | `GutenbergEditorWindowController.swift:123` has no correlated save deadline; malformed messages can leave busy state stuck. Startup probes at `:336` may race readiness; no web-process termination recovery. Save failures can be visible only on the other editor surface. | Explicit loading/ready/saving/recovering states, request IDs, error recovery, durable checkpoints, and errors on the originating surface. |
| F19 | P2 / source | `MenuBarController.swift:172,242,409` uses a non-resizable fixed root and accepts saved frames that merely intersect a display. Rehosting destroys view-local state. Activation policy is changed independently by popover, settings, picker, and rich-window controllers. | One surface coordinator, persistent presentation-independent state, finite/clamped frames, and deliberate app activation ownership. |
| F20 | P2 / source | `KnotMacApp.swift:32` installs the status item without automatically presenting first-run setup. Its Settings view is 520x1080. Errors in `EditorView.swift:117` are constrained to a crowded one-line area; Escape clears without recovery. | First-run discoverability, screen-fitting scrollable Settings, actionable status area, and undoable clear. |
| F21 | P2 / source | `Hotkey/Shortcut.swift:52` uses keycode zero as disabled even though ANSI A has keycode zero. `HotkeyManager.swift:41` unregisters the old shortcut before validating the replacement; failure loses a working binding. Recording is mouse-led. | Optional shortcut state, transactional replacement, keyboard-accessible recording, and layout-change handling. |
| F22 | P2 / source | `ChromelessTextEditor.swift:26` overrides the system Always Show Scrollbars preference. Full-string updates can reset selection/undo/IME; focus changes are not fully propagated. Fixed text metrics and status controls lack comprehensive accessible behavior. | Respect system preferences, incremental text integration, IME/RTL/VoiceOver tests, and semantic controls. |
| F23 | P2 / source + R10 | `Routing.swift:24` detects LF but not lone CR. `ModeToggle.swift:35` cannot restore automatic routing until send succeeds. Whole-content trim in `Vault.swift:38` can remove meaningful code indentation. | Explicit Auto/Today/Inbox choice; documented grapheme-count/newline rules; preserve nonblank content bytes. |

### Architecture, Build, And Maintainability

| ID | Priority / evidence | Finding and source | Required outcome |
| --- | --- | --- | --- |
| F24 | P1 / source | EditorModel owns preferences, bookmark state, onboarding, import, writing, queueing, and transient feedback; views also parse headings and manage task caches. `@unchecked Sendable` covers mutable queue state. Dependencies partly ignore injected defaults. | Small domain interfaces with actors for mutable persistence, one writer implementation, injected clock/filesystem/preferences, and strict Swift concurrency. |
| F25 | P2 / source / unmeasured cost | Formatting repeatedly creates Foundation formatters; folder lookups rebuild sets; the rich bundle loads substantial WordPress code. These are plausible costs, not profiled regressions. | Compile/cache format descriptions, incremental folder filtering, lazy rich-editor loading, and measured budgets before more optimization. |
| F26 | P1 / source | Web `package.json` uses `latest` and internal WordPress import paths. A lockfile now exists, but bootstrap's node_modules mtime shortcut can reuse stale dependencies. `dist` is ignored; release does not run npm build. | Reproducible locked installs, explicit resource build dependencies, pinned adapter compatibility tests, no generated-file assumptions. |
| F27 | P1 / source | `GutenbergEditorWindowController.swift:232,266` ignores the built HTML and chooses the first matching index JS, so stale multiple assets are ambiguous. The native CSP differs from `index.html`. | Load the actual built entry via a manifest-backed custom scheme; test all referenced resources and CSP in real WKWebView. |
| F28 | P1 / source | `scripts/release.sh:40,94,111` accepts a version for DMG naming but does not necessarily align binary MARKETING_VERSION or regenerate the web bundle. `:162` masks codesign verification failure. | Version/tag/binary equality, fresh web build, required tests, fail-closed signature/notarization gates, and immutable release artifacts. |
| F29 | P1 / coverage gap | No checked-in CI workflow, app-model tests, native-bridge runtime tests, or UI test target. `GutenbergWeb/tests/nativeBridge.test.js` uses source regex checks, not message/frame behavior. | Fault-injected persistence tests, real sandbox/WK smoke tests, native UI tests, and clean-checkout CI. |
| F30 | P2 / source | README/AGENTS still describe v0.1 and no editor; USAGE/build instructions lag the Node dependency. README overstates Moment coverage and assumes cross-device conflict naming. iOS readiness claims exceed the user's macOS-only release intent. | Update user/developer/release docs to actual supported behavior; qualify sync guarantees and clearly mark iOS experimental. |

## Reproductions

`rewrite-evidence/run-baseline.sh` compiles the baseline core with a self-contained harness. It creates one UUID-named fixture tree in the system temporary directory and removes only that tree on exit. Run only against the audited baseline to compare the recorded results. A rewrite should turn the specified expected-safe behaviors into permanent tests rather than preserve these defects.

| Case | Input / operation | Observed baseline | Expected-safe behavior |
| --- | --- | --- | --- |
| R01 | Existing daily file with invalid UTF-8; append | File replaced with generated UTF-8 | Throw; original bytes unchanged; capture retained |
| R02 | Blank daily heading; append | Success, no insertion | Explicit end-of-note option appends, or invalid configuration error |
| R03 | Plan two Inbox writes before executing either | Same URL; second content replaces first | Distinct destination paths; both contents survive |
| R04 | Inbox `../Outside` | Sibling file created outside vault | Reject path before any mutation |
| R05 | Vault/assets symlink to sibling directory | Image written to symlink target | Reject descendant symlink; no outside file |
| R06 | Fenced example contains heading before real heading | Capture inserted after the fence but before the real section | Ignore fenced heading; append to real section |
| R07 | Discover headings in that same file | Two headings with one unique ID | One valid top-level document heading |
| R08 | One valid queue line plus malformed JSON line | One record returned, no error | Preserve/report corrupt raw record; do not silently discard |
| R09 | Template `- {{HH:mm}}` and a thought | Thought absent from output | Validation prevents sending with a content-dropping template |
| R10 | `one\rtwo` with default routing | Daily | Inbox because the note is multiline |

These cases do not simulate power loss, read/write races from other devices, or a sandboxed signed application. The plan contains those broader tests because a few passing reproductions cannot establish capture safety.

## Design Conclusions

1. Implement the durable capture/outbox and validated vault writer before rebuilding UI. This prevents the old failure patterns from reappearing behind a cleaner screen.
2. Keep the native quick-capture path independent of WebKit initialization. The rich editor is useful, but must remain optional to the fast path.
3. Make onboarding an explicit resumable transaction, not incidental `@State` initialized from partly committed preferences.
4. Use a Markdown parser for document structure and source-range edits. Do not normalize/re-serialize an existing daily note merely to insert a bullet.
5. Treat WKWebView as an untrusted document host. A local-only app still needs origin checks, safe navigation, resource limits, and data-preserving serialization.
6. Make release reproducibility and failure recovery acceptance criteria, not follow-up cleanup.

The plan retains all established capture capabilities and the committed rich-editor work. It intentionally does not add accounts, telemetry, cloud sync, a vault-wide search/index, widgets, or a full Obsidian replacement.
