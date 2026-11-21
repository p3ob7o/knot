# Speech results, synthetic set

WP-13 owns this folder. It writes the first results; WP-04 only made the place and states the format.

`knot-eval --set synthetic` transcribes every audio clip in `Fixtures/generated/audio/` and writes `synthetic.json` here. It transcribes each clip as the processing queue transcribes a recording: through the `Transcriber` port, in runs that each read at most `runBudgetSeconds` of audio and end at the last finished phrase. The results are text, so the file is committed; the audio is not (see [`../../README.md`](../../README.md#where-the-audio-comes-from)).

A result records the macOS build whose voices made the audio, taken from `Fixtures/generated/manifest.json`, because another build gives other audio. Results from two builds compare the engine and the voices together, and a pull request that compares them says so. A pull request that changes the speech settings, or the audio fixtures, reruns the command, commits the new file and states the results before and after.

Results from the owner's recordings (`knot-eval --set local`) are never written here. They stay in the folder that `KNOT_LOCAL_FIXTURES` names, and only their numbers are recorded at the gate.

## Format

One JSON object, indented by two spaces, keys in the order shown, so that a change reads well in a diff.

```json
{
  "schema": 2,
  "set": "synthetic",
  "fixturesManifestSha256": "<SHA-256 of Fixtures/manifest.json>",
  "engine": {
    "name": "SpeechTranscriber",
    "locale": "en-US",
    "osBuild": "<build of the Mac that ran it>",
    "assets": "<the installed model's version, or null if the API gives none>",
    "runBudgetSeconds": 60
  },
  "audio": {
    "osBuild": "<madeOn.build from Fixtures/generated/manifest.json>",
    "voices": ["<the voices listed there>"]
  },
  "normalisation": "<name of the scoring normalisation, defined in WP-13's PR>",
  "date": "<YYYY-MM-DD>",
  "results": [
    {
      "name": "clean",
      "audioSha256": "<from Fixtures/generated/manifest.json>",
      "referenceWords": 52,
      "hypothesisWords": 51,
      "substitutions": 1,
      "deletions": 1,
      "insertions": 0,
      "wer": 0.038,
      "runs": 1,
      "transcript": "<what the engine returned>",
      "transcribeSeconds": 3.1
    }
  ],
  "summary": {
    "words": 0,
    "wer": 0.0,
    "werWithoutLong": 0.0,
    "silenceWords": 0
  }
}
```

- One entry per audio fixture, in the manifest's order.
- `wer` is (substitutions + deletions + insertions) / referenceWords, after normalisation, rounded to three places.
- For `silence`, whose reference is empty, `wer` is `null` and `hypothesisWords` counts what the engine invented. `summary.silenceWords` repeats it.
- `summary.wer` pools every word of every fixture. `werWithoutLong` leaves out `long`, which would otherwise outweigh the rest.
- `runs` counts the runs a clip took. Schema 2 added it and `engine.runBudgetSeconds`; schema 1, the proof step's, transcribed each clip in one run.
- `transcript` is allowed here because the fixtures are synthetic. Nothing from the owner's recordings ever appears in this folder.
- Accuracy thresholds are not merge criteria (docs/architecture.md §17). They are checked in WP-13's own PRs and at milestones.
