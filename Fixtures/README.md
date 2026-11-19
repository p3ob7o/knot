# Fixtures

Synthetic test data that packages share. Nothing here comes from a real note, a real recording or a real person. The owner's own recordings are not here either: they live outside every worktree, in the folder that `KNOT_LOCAL_FIXTURES` names (see [The owner's recordings](#the-owners-recordings)).

| Path | What it holds | Committed | Used first by |
|---|---|---|---|
| `audio/<name>.txt` | The text each clip speaks, which is also its reference transcript | yes | WP-13, `knot-eval --set synthetic` |
| `audio/long.source.txt`, `audio/long.txt` | The paragraphs of the ten-minute clip, and its reference | yes | WP-13 |
| `generated/audio/` | The audio itself, spoken on this Mac | **no**, git ignores it | WP-12, WP-13, the soak, the end-to-end suite |
| `generated/manifest.json` | The macOS build, voices, lengths and checksums of this Mac's audio | **no** | tests, `knot-eval` |
| `ink/<name>.json`, `ink/<name>.svg` | Strokes built from Bézier paths, and a preview of each | yes | WP-18 |
| `cleanup/cases.json` | 30 raw transcripts with what a correct cleanup keeps and removes | yes | WP-14, `knot-eval --set synthetic` |
| `read-aloud/<NN>.txt` | The reference text of the owner's ten read-aloud passages | yes | WP-13, `knot-eval --set local` |
| `results/speech/`, `results/cleanup/` | The committed results of the synthetic evaluation | yes | WP-13 and WP-14 write them |
| `manifest.json` | Describes every clip (text, voice, format, expected length) and every committed file with its checksum | yes | tests, the checker |
| `tools/` | The generator and the checker | yes | everyone |

## Where the audio comes from

The audio is spoken by voices that ship with macOS, so it is not committed: Apple's licence for those voices does not allow redistributing what they make, and this repository is public. Each Mac makes its own with `Fixtures/tools/generate.sh --audio`, into `Fixtures/generated/`, which git ignores. The repository keeps only what is ours: the texts, the reference transcripts, and the code that speaks them.

The script uses the Eloquence voices built into macOS, in `/System/Library/PrivateFrameworks/TextToSpeechKonaSupport.framework`: Reed (English (US)), Shelley (English (US)), Sandy (English (US)), Eddy (English (US)), Flo (English (US)) and Reed (English (UK)). They need no download.

## Audio

All clips are mono at 16 kHz. Every clip but one is 16-bit linear PCM in WAV, so that the recorder's tests can inject exact frames. The ten-minute clip is AAC at 32 kbit/s in `.m4a`, Knot's own stored format.

| Name | Seconds | Voice | What it is |
|---|---|---|---|
| `clean` | about 17.5 | Reed (US) | Clean speech: four plain sentences. |
| `fillers` | about 17.9 | Shelley (US) | Scripted fillers (um, uh, I mean), a repeated word and two spoken self-corrections. |
| `list` | about 6.6 | Sandy (US) | A spoken shopping list. |
| `numbers-names` | about 18.3 | Eddy (US) | Times, a date, an amount, a flight number, a room number and four names. |
| `short` | about 1.4 | Sandy (US) | A clip under two seconds, for the soak and the discard rule. |
| `canary` | about 6.7 | Shelley (US) | Holds the made-up canary word, Quillfarrow. |
| `noisy` | about 11.3 | Flo (US) | Speech mixed with seeded low-passed noise at 10 dB SNR. |
| `silence` | 10.0 | none | A noise floor near −60 dBFS and no speech. Its reference is empty. |
| `long` | 600.0 | Reed (US), Shelley (US), Reed (UK) | Exactly ten minutes: 25 paragraphs in turn, each followed by a 1.2 s pause. |

The lengths were measured on macOS 27.3 (build 26C5047e). `manifest.json` gives each clip's expected length and tolerance. Every speech clip carries the same −60 dBFS noise floor, so no clip holds digital silence.

The reference transcript is the text the voice was given, written as a person would type it: digits for times and amounts, capitals for names. Scoring normalises case, punctuation and number forms first; WP-13 defines that normalisation and states it with its results.

**The canary.** docs/architecture.md §17 asks the end-to-end suite for a made-up word that must never reach a log line, an error or a diagnostics file. That word is `Quillfarrow`, in the `canary` clip. A recogniser may write it differently, for example as two words, so the end-to-end test checks both the word itself and the words the transcriber returned.

## Ink

Three drawings, made from a small single-line print alphabet and a few shapes, with seeded jitter so that no two letters are identical. They are committed: they come from this repository's code alone.

| Name | Expected text | What it is |
|---|---|---|
| `line` | `call the vet at noon` | One line of print handwriting. |
| `list` | `- milk`, `- eggs`, `- bread` on three lines | A list of three items, each with a dash. |
| `sketch` | none | A house, a sun and an arrow. Recognition should return no words. |

Each `ink/<name>.json` holds:

- `canvas`: the size in points, origin at the top left, y pointing down, as in UIKit.
- `ink`: a pen, black, 3 points wide.
- `strokes`: one entry per touch of the pen, in drawing order. `path` is the source: `M`, `L` and `C` (cubic Bézier) segments in canvas points. `points` is the path sampled about every two points.
- `pointFields`: the meaning of each value in a point: `x`, `y`, `t` (seconds since the drawing began), `size` (points), `opacity`, `force`, `azimuth` and `altitude` (radians). The pen moves at 120 points a second, with short pauses between strokes, letters, words and lines, and a force that rises at the start of each stroke and falls at its end.

The format names no PencilKit type, so that this package reads no OS 27 API. WP-18 builds `PKStroke` and `PKDrawing` values from these points after reading their declarations in the SDK. Open `ink/<name>.svg` to see a drawing.

## Where tests find them

- Tests read the files from the repository's `Fixtures/` folder. They find it by walking up from their own source file (`#filePath`) to the first folder that holds `Fixtures/manifest.json`. A Swift package cannot bundle files from outside its own folder, so fixtures are not package resources.
- A test names a clip by its `file` in `manifest.json`, such as `generated/audio/clean.wav`, and its reference by `reference`, such as `audio/clean.txt`.
- A committed file is checked against its SHA-256 in `manifest.json` before use. Audio has no committed checksum, because each Mac makes its own; `generated/manifest.json` records this Mac's.
- Tests in the iOS Simulator read the same path, because the Simulator's processes see the Mac's file system. A UI test that needs a fixture inside the app copies it in through `project.yml`.
- One helper in KnotTestSupport should do this for every package, so that the lookup and the errors below exist once. This package does not own KnotTestSupport, so the PR asks the orchestrator to assign it.

## When a fixture is absent

A missing or changed fixture fails the test. It never skips it: skipping is only for a model that is unavailable (docs/architecture.md §17). Audio that has not been made on this Mac yet is missing, and the failure says how to make it:

```
fixture_missing: Fixtures/generated/audio/clean.wav has not been made on this Mac (looked under <repository root>).
Run `Fixtures/tools/generate.sh --audio` to speak the audio fixtures with the system voices.
```

A committed file that is missing or no longer matches the manifest fails the same way:

```
fixture_missing: Fixtures/ink/line.json is not in this checkout. Restore it with `git checkout -- Fixtures`.
fixture_changed: Fixtures/ink/line.json does not match Fixtures/manifest.json.
Restore it with `git checkout -- Fixtures/ink/line.json`, or regenerate the committed files and the manifest together.
```

`Fixtures/tools/generate.sh --check` reports the same codes.

## Making them

```
Fixtures/tools/generate.sh                    # the committed files, then this Mac's audio
Fixtures/tools/generate.sh --audio            # only this Mac's audio, into Fixtures/generated/
Fixtures/tools/generate.sh --committed        # only the committed files (needs no voices)
Fixtures/tools/generate.sh --out <folder>     # the same, under another folder
Fixtures/tools/generate.sh --check            # compare the committed files with a fresh run, speak the audio
                                              # into a temporary folder and check each clip's format and length,
                                              # then lint the cleanup set, the read-aloud script and the checklists
Fixtures/tools/generate.sh --check --lint-only   # the same without speaking the audio
```

It uses `/usr/bin/python3`, `/usr/bin/say` and `/usr/bin/afconvert`, which ship with macOS and the Command Line Tools. It needs no Xcode, no network and no microphone.

What is reproducible, and what is not claimed:

- **The committed files are byte-identical on every run:** `manifest.json`, `audio/long.txt`, and the ink JSON and SVG files. They come from this repository's texts and code only. `--check` remakes them in a temporary folder and compares them byte for byte, wherever `TMPDIR` points.
- **Encoded audio is not claimed to be byte-identical**, not even on the same Mac, and nothing compares it so. `--check` instead checks each clip's format, and its length against the manifest. A voice that changes with an update of macOS shows up there as a clip outside its tolerance.
- The speaking rate is pinned at 175 words a minute, so a user's speech setting cannot leak in. Noise and jitter come from a seeded xorshift generator, mixed in integer arithmetic.

## The owner's recordings

The owner records the [read-aloud script](../docs/checklists/G4-read-aloud.md) and [ten spontaneous notes](../docs/checklists/G4-spontaneous-notes.md) with Voice Memos, on the iPhone and on the Watch, at gate G4. The files go in the folder that `KNOT_LOCAL_FIXTURES` names, which sits outside every worktree, named:

- `read-aloud-<NN>-<device>.m4a`, with `<NN>` from `01` to `10` and `<device>` `iphone` or `watch`: 20 files;
- `note-<NN>-<device>.m4a`, with `01` to `05` on the iPhone and `06` to `10` on the Watch: 10 files.

The reference text for `read-aloud-<NN>-*.m4a` is `read-aloud/<NN>.txt` here. The spontaneous notes have no reference.

Only `knot-eval --set local` reads that folder. Nothing in this repository reads or writes it. No file from it, and nothing derived from it, enters a commit, a pull request, a log or a test. `.gitignore` here ignores those file names, and `--check` fails if one appears anywhere in the tree.
