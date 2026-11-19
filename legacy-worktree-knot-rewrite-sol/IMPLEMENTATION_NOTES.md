# Knot Rewrite Implementation Notes

## Workspace And Baseline

- Workspace: `/Users/paolo/Documents/knot-rewrite-sol`
- Branch: `codex/rewrite-sol`
- Audited source SHA: `3a4bb5b7ce11463323c13da9442de5e4fd29941f`
- Started: 2026-09-08 (Europe/Vienna)
- Handoff documents and `rewrite-evidence/` are preserved uncommitted.

## Toolchain

- Xcode: 27.0 beta (27A5209h), selected per command with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`
- Swift: Apple Swift 6.4 (`swiftlang-6.4.0.23.5`)
- Node: 24.20.0
- npm: 12.0.2
- XcodeGen: 2.45.4
- macOS deployment target remains 26.0; iOS compatibility target remains 26.0 and experimental.

## Phase Status

| Phase | Status | Evidence |
| --- | --- | --- |
| 0 Baseline | In progress | Handoff validator passed; baseline Swift suite passed 100/100. |
| 1 Domain | Not started | |
| 2 Durable state | Not started | |
| 3 Real vault I/O | Not started | |
| 4 Setup/settings | Not started | |
| 5 Native shell | Not started | |
| 6 Rich editor | Not started | |
| 7 Hardening | Not started | |
| 8 Handoff | Not started | |

## Verification Log

### Baseline

```text
node rewrite-evidence/validate-handoff.mjs
PASS: 30 findings, 28 verification cases, 10 baseline observations, links and code fences.

env DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --package-path Packages/KnotKit \
  --scratch-path /private/tmp/knot-rewrite-sol-baseline
PASS: 100 tests, 0 failures (2026-09-08 00:35 local; build 10.47s, tests 0.095s).
```

The first sandboxed Swift invocation could not write the compiler module cache. The identical command passed with ordinary scoped SwiftPM permission; this was an environment failure, not a product failure.

## Measurements

No rewrite performance measurements yet. Phase 0 will establish deterministic fixtures and Release-mode commands before values are recorded.

## Acceptance Traceability

F01-F30 and T01-T28 remain open until exercised through their mapped production interfaces. Baseline tests and source inspection do not close rewrite gates.

## Known External Limits

- Signing, sandbox distribution behavior, notarization, and provider-specific behavior require external credentials/environments and are not yet exercised.
- No real vault, user preferences, bookmark data, or note content will be used for tests.

