# Baseline Verification Record

Source: `3a4bb5b7ce11463323c13da9442de5e4fd29941f`, branch `codex/gutenberg-editor`. Verified on 2026-09-07/08. All fixture content is synthetic. No real vault or application preferences were used, and no app source was changed for the audit.

The compile snapshot includes the committed Gutenberg/attachment code. Byte comparison of 69 tracked Swift, JavaScript/JSX/MJS, JSON, YAML and entitlement files between the temporary snapshot and the primary checkout found zero differences. The root analysis documents are the deliverables; the snapshot itself is temporary and is not required to implement the plan.

## Toolchain

- Xcode 27.0 beta, build 27A5209h, at `/Applications/Xcode-beta.app`.
- Apple Swift 6.4, swiftlang-6.4.0.23.5; target arm64-apple-macosx27.0.0.
- Node v24.20.0; installed Vitest v4.1.8.
- Project deployment settings remain macOS 26 / iOS 26. This audit does not establish minimum-OS runtime compatibility.
- Full Xcode selected per command with DEVELOPER_DIR. Global `xcode-select` was not changed.

## Swift Tests

Executed from the primary checkout:

```sh
env DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --package-path Packages/KnotKit \
  --scratch-path /private/tmp/knot-commit-check-20260907
```

Final verified run finished at 2026-09-08 00:15 local time:

```text
Test Suite 'KnotKitTests.xctest' passed
Executed 100 tests, with 0 failures (0 unexpected)
Test Suite 'All tests' passed
Executed 100 tests, with 0 failures (0 unexpected)
```

These are XCTest tests. The additional Swift Testing runner reports zero tests, which is not a contradiction. The baseline test names/expectations do not cover the unsafe scenarios in results.json.

## macOS Build

Executed `xcodegen generate` in a temporary source snapshot. Copied the existing ignored GutenbergWeb/dist into that snapshot; did not claim to rebuild npm dependencies successfully. Then ran:

```sh
env DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project Knot.xcodeproj -scheme Knot-macOS \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/knot-rewrite-audit-20260907/derived-data \
  CODE_SIGNING_ALLOWED=NO build
```

Result: `BUILD SUCCEEDED`, exit 0. The only warning matched in the build log was skipped AppIntents metadata extraction because the framework was not linked. This is an unsigned development compile, not a signed-sandbox, launch, notarization, clean-web-build or UI verification result. The existing generated index JavaScript asset's logical byte size is 3,640,609 bytes; its sparse disk allocation is not a bundle-size benchmark.

## Safety Characterization

From a checkout of the audited commit, run:

```sh
env DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  bash rewrite-evidence/run-baseline.sh "$PWD"
```

Select an installed full Xcode path on another machine. The runner checks source SHA and tracked core modifications, compiles the actual baseline KnotKit sources with Characterization.swift, then exercises a disposable UUID-named temporary vault. It removes only its own compilation/fixture directories. It does not need Obsidian, settings changes or access to a real vault.

Exit zero means the characterization ran, NOT that the app meets safe behavior. [results.json](results.json) contains the ten observed outputs. The expected-safe outcomes are in the audit's reproduction table. R04/R05 prove missing application-level containment in an unsandboxed harness, not a general bypass of the macOS sandbox. R06 places the capture after a fenced example and before the intended real heading; it does not place the bullet inside the code fence.

## Web Test Limit

An earlier default-worker run reported four worker startup timeouts. A final bounded retry used the installed Vitest directly:

```sh
node Knot/macOS/GutenbergWeb/node_modules/vitest/vitest.mjs run \
  --environment jsdom --pool threads --maxWorkers 1 \
  --root Knot/macOS/GutenbergWeb
```

The actual runner used absolute paths and an external 30-second process-group timeout. Its final output was:

```text
RUN v4.1.8
AUDIT_TIMEOUT: web test process exceeded 30 seconds; terminating its process group
```

Exit 124; no assertions executed. A separate JSDOM-dependent serializer probe also stalled and was stopped. A preliminary attempt with an unsupported `--minWorkers` flag was corrected before this bounded run; it is not an application failure. No serializer result is labeled reproduced from these attempts. No web build or UI-performance claim is inferred from them.

## Documentation Check

Run `node rewrite-evidence/validate-handoff.mjs` to verify local artifact links, the 30 finding IDs, their test coverage references, 28 test IDs, ten reproduction IDs and basic Markdown integrity. This is a structural documentation check only. It does not prove that the future rewrite is implemented or that a prose test specification has passed.

Not exercised: real native UI/VoiceOver/IME, signed sandbox permissions, multiple processes/providers under load, Instruments budgets, iOS, release signing/notarization. Those are explicit future implementation gates, not waived requirements.
