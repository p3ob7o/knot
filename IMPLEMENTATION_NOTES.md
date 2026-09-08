# Knot Rewrite Implementation Notes

## Workspace And Baseline

- Actual isolated workspace: `/Users/paolo/.codex/visualizations/2026/06/01/019e8295-9364-72d3-aaea-429ccd31f34a/knot-rewrite-sol`
- Requested branch: `codex/rewrite-sol`
- Audited source baseline: `3a4bb5b7ce11463323c13da9442de5e4fd29941f`
- Nominal `/Users/paolo/Documents/knot-rewrite-sol` was not writable in the managed sandbox, so the branch was cloned into the writable isolated workspace above. The primary checkout was not modified.
- The initial implementation handoff was intentionally uncommitted. No tag, push, notarization, or release was attempted during that implementation run.

## Main-Branch Promotion Preparation

On 2026-09-08 the user authorized archiving the old version and promoting this rewrite to main. Two dated archive branches preserve the old source:
- `archive/main-before-rewrite-2026-09-08`: previous GitHub main at `75140bbd101eb1a226c6c99a527c7d3c9e057735`.
- `archive/pre-rewrite-2026-09-08`: latest pre-rewrite app at `3a4bb5b7ce11463323c13da9442de5e4fd29941f`.

Promotion preparation added the previously ignored Swift package lockfile to version control, made CI use the runner's selected Xcode, and removed two trailing blank lines flagged by Git. The complete `scripts/verify.sh` pipeline was rerun successfully: 8 web unit tests, 3 web integration tests, 80 KnotKit tests, 6 hosted macOS tests, the two-process publication exercise, native/WK runtime probes, macOS Debug/Release builds, and iOS simulator compatibility.

This source promotion does not close the partial/unavailable acceptance gates below and is not a signed or notarized release. Existing release tags and the marketing version are unchanged.

## Toolchain And Dependencies

- Xcode 27.0 beta (27A5209h), selected per command with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`
- Apple Swift 6.4 (`swiftlang-6.4.0.23.5`), Swift language mode 6 with complete strict concurrency
- Node 24.20.0, npm 12.0.2, XcodeGen 2.45.4
- GRDB 7.10.0 and swift-markdown/cmark-gfm 0.8.0 are exact SwiftPM pins
- The npm lock contains 432 runtime packages with integrity and license metadata; the shipped graph's 427 reviewed unique packages pass the offline security policy
- CaptureStore schema version 1 uses SQLite WAL, `synchronous=FULL`, foreign keys, a five-second busy timeout, private assets/staging, a durable outbox, mutation journal, receipts, migration backups, and quarantine records
- macOS deployment target is 26.0. The iOS 26.0 target remains compatibility-only and experimental.

## Phase Status

`Implemented` means the production architecture is present. `Partial gate` means one or more exact acceptance exercises remain unavailable or unperformed; it is not a claim of plan completion.

| Phase | Status | Exercised evidence |
| --- | --- | --- |
| 0 Baseline | Pass | Audit/handoff validator, preserved fixtures, pinned toolchains, locked dependencies, reproducible scripts, clean-source build |
| 1 Domain | Implemented; partial gate | Typed IDs/paths/settings, bounded formats, byte-preserving daily parser, routing/title rules; T08/T09 pass, T01/T02/T19 have remaining matrix rows |
| 2 Durable state | Implemented; partial gate | GRDB schema, draft revisions, assets, outbox, journal, recovery, reset/migration tests; exact crash/disk-full matrix remains partial |
| 3 Real vault I/O | Implemented; partial gate | Descriptor-relative `O_NOFOLLOW` access, root identity, no-clobber publication, two-process collision test, reconciliation; signed sandbox/provider test unavailable |
| 4 Setup/settings | Implemented; partial gate | Five-step resumable onboarding, hierarchy browser, 10,000-child fixture, generation cancellation, import transaction, 520x640 runtime capture; live interaction/accessibility checks remain |
| 5 Native shell | Implemented; partial gate | 150 ms durable draft path, Auto/Today/Inbox, recovery/status, transactional hotkeys, detach/frame logic, 440x460 runtime capture; manual keyboard/window matrix remains |
| 6 Rich editor | Implemented; partial gate | TypeScript codec, typed/versioned bridge, manifest/CSP/scheme isolation, assets, checkpoints, exact-revision save and real WKWebView render; forced WebContent crash and full image-input matrix remain |
| 7 Hardening | Partial gate | Full verify, dependency/license/security policy, Swift and app Thread Sanitizer, iOS build, core/rich timings; signed sandbox, Instruments memory/idle trace, macOS 26 host, and human accessibility checks remain |
| 8 Handoff | Partial gate | Obsolete writer/parser stack removed; README/USAGE/AGENTS/release/verify/docs and screenshots updated; final acceptance is blocked by the remaining gates below |

## Verification Results

Completed on 2026-09-08, Europe/Vienna:

```text
node rewrite-evidence/validate-handoff.mjs
PASS: 30 findings, 28 verification cases, 10 baseline observations.

./scripts/verify.sh
PASS: dependency integrity/licenses and offline security policy
PASS: 8 web unit tests and 3 web integration tests
PASS: 80 KnotKit tests
PASS T03: 100 captures and 100 same-name assets from two processes
PASS: macOS Debug build
PASS: production WKWebView runtime (2 visible blocks, 408014 characters,
      2 local resources, 302.5 ms, no external resource)
PASS: native onboarding 520x640 and quick 440x460 runtime captures
PASS: 6 hosted macOS tests
PASS: universal arm64/x86_64 macOS Release build
PASS: universal iOS simulator compatibility build
PASS verify

swift test --package-path Packages/KnotKit --sanitize thread
PASS: 80 tests, 0 failures, no Thread Sanitizer findings.

xcodebuild ... -enableThreadSanitizer YES test
PASS: 6 hosted macOS tests, 0 failures, no Thread Sanitizer findings.

Fresh source export (excluded .git, node_modules, dist, Knot.xcodeproj, build):
PASS: bootstrap, locked web build, XcodeGen, macOS Debug and Release.

Release artifact smoke launch with a disposable HOME:
PASS: executable remained alive for three seconds and was then terminated.

./scripts/release.sh 0.2.0
EXPECTED FAIL: error: release requires a clean source tree
```

The verified Release binary is universal arm64/x86_64, has `CFBundleShortVersionString=0.2.0`, `CFBundleVersion=1`, and SHA-256 `eab4fd9d80d2b947d5c02407c9c1074dafa561f458594844135420bf47e2a012`. It is linker-signed ad hoc only, with no TeamIdentifier or sealed-resource signature.

## Performance

Machine: Mac16,9 (Mac Studio), 48 GiB RAM, macOS 27.0 build 26A5425a, Xcode 27 beta, Swift 6.4. Core numbers are warm-cache Release runs; rich readiness is a cold Debug runtime probe using the production manifest and bridge. Each result has 30 runs.

| Workflow | Median | p95 | Budget | Result |
| --- | ---: | ---: | ---: | --- |
| 1,000 immediate folders | 6.150 ms | 9.299 ms | 250 ms | Pass |
| 10,000 immediate folders | 54.779 ms | 57.332 ms | 2,000 ms | Pass |
| Durable enqueue, 4 KiB | 0.162 ms | 0.255 ms | 100 ms | Pass |
| Daily append, 1 MiB | 31.909 ms | 38.500 ms | 200 ms | Pass |
| Rich bridge ready, cold | 218.530 ms | 220.713 ms | 2,000 ms | Pass |

The web bundle is 3,918,920 bytes (956,220 bytes gzip), 7.65% above the 3,640,609-byte reviewed baseline and within the 10% CI limit. Core results are in `rewrite-evidence/core-performance.json`; rich results are in `rewrite-evidence/rich-ready-performance.json`.

## Runtime Evidence

- `rewrite-evidence/rich-runtime-result.json`
- `rewrite-evidence/screenshots/rich-runtime.png` (1800x1400, 403225 bytes)
- `rewrite-evidence/screenshots/onboarding.png` (1040x1280 Retina, 45524 bytes)
- `rewrite-evidence/screenshots/quick.png` (880x920 Retina, 42113 bytes)

The probes assert layout bounds, nonempty PNGs, a nonblank interactive rich DOM, bundled-resource URLs, visible blocks, and bridge readiness. The environment's image-inspection tool could not open these local paths, so no manual visual-quality claim is made from the PNGs.

## Acceptance Traceability

| Gate | Status | Current evidence or remaining requirement |
| --- | --- | --- |
| T01 | Partial | Invalid UTF-8 and BOM/CRLF byte preservation pass through the production writer; denied/cloud-placeholder provider cases are not exercised |
| T02 | Partial | Traversal, absolute/ambiguous paths, symlinks, hardlinks, and outside-mutation checks pass; live root rename/parent-swap and volume case/Unicode variants remain |
| T03 | Pass | True two-process 100-capture plus 100-asset collision test passes |
| T04 | Partial | Newer revision survives older completion/duplicate send; complete close/reset/vault-change late-result UI matrix remains |
| T05 | Partial | Journal persistence, reconcile-to-receipt/review, retry identity and reopen pass; process kill after every individual publication step remains |
| T06 | Partial | Failed enqueue, missing asset, corrupt legacy queue, preservation and export UI are covered; real disk-full/database-loss injection remains |
| T07 | Unavailable | Requires a signed sandbox build, valid signing identity/profile, user-approved security-scoped vault, and provider scenarios |
| T08 | Pass | Daily parser byte/range fixtures cover fences, quoted/list headings, Setext/ATX, duplicates, emoji, missing heading, and end-of-note |
| T09 | Pass | Format/default/validation/DST/ISO/title fixtures pass |
| T10 | Pass | Every onboarding step persists/resumes; completion and reset are transactional and pending captures retain inactive profile identity |
| T11 | Partial | Immediate children and 10,000-result/prefix reachability pass; full keyboard breadcrumb/select-current UI journey remains manual |
| T12 | Pass | Old-generation cancellation/stale-publication protection passes with delayed providers |
| T13 | Pass | Obsidian import precedence, enablement, path validation, proposals, and scoped undo pass |
| T14 | Pass | TypeScript codec fixtures cover supported nested blocks/marks/media and opaque unsupported-source round trips |
| T15 | Partial | Version/session/size/JSON/checkpoint/native URL policy and local-resource WK runtime checks pass; hostile real subframe/navigation matrix is not complete |
| T16 | Partial | Native staging, chunk order/hash, parsed image rewrite, limits and object URL cleanup are covered; every paste/drop/picker format and decompression-bomb runtime case remains |
| T17 | Partial | Readiness delay, checkpoint transfer, failed-save recovery code and real runtime pass; forced WebContent termination/reopen journey remains |
| T18 | Partial | Frame validation/clamping and detach/multiwindow ownership are implemented; live typing/onboarding/removed-display journeys remain manual |
| T19 | Partial | Auto override and CR/CRLF/Unicode routing pass; live Return/send/undoable-clear keyboard journey remains manual |
| T20 | Partial | Keycode zero, disabled/default and transactional rollback pass; non-US layout/conflict/cancel/bare-key live journey remains manual |
| T21 | Unavailable | Runtime screenshots exist, but keyboard-only, VoiceOver, IME, RTL, large text and high-contrast human checks require an interactive macOS session |
| T22 | Partial | Settings and queue backups, idempotence, quarantine and reset retention pass; interrupted full legacy corpus remains incomplete |
| T23 | Pass | Swift 6 strict concurrency, package/app Thread Sanitizer, injected store faults and obsolete production writer/parser removal pass |
| T24 | Partial | Four core Release budgets plus cold rich-ready budget pass; native launch/typing, Instruments signpost/main-thread trace, RSS after 50 cycles and idle/offline CPU remain |
| T25 | Pass | Clean source export rebuilt npm/Xcode artifacts and macOS Debug/Release; manifest hashes and real WK local-only resources pass |
| T26 | Partial | Source/project/binary version agrees and dirty-tree release fails closed; Developer ID signing, notary rejection/success, staple and Gatekeeper need release credentials and authorization |
| T27 | Partial | CI definition and complete local pipeline pass, including native WK handlers; remote CI cannot run without committing/pushing the branch |
| T28 | Pass | README, USAGE, AGENTS, build/release docs, third-party notices, privacy/sync limits and experimental iOS label match the implementation |

## Runnable Artifact And Limits

- Runnable development app: `build/development/Knot.app`
- Source Release product: `/private/tmp/knot-verify-release/Build/Products/Release/Knot.app`
- This is an unsigned/ad-hoc development build, not a signed, notarized, or production-ready release.
- Full rewrite acceptance is not claimed. T07/T21 and the signed portions of T26 are externally blocked; the partial gates above also need the stated fault-injection, provider, interaction, and Instruments evidence before the plan's final acceptance conditions are satisfied.
- A live registry vulnerability query was not performed because dependency metadata egress was not authorized. The reproducible offline integrity/license/security policy passed.
