# Cleanup results, synthetic set

WP-14 owns this folder. It writes the first results; WP-04 only made the place and states the format.

`knot-eval --set synthetic` cleans every case of [`../../cleanup/cases.json`](../../cleanup/cases.json) and writes `synthetic.json` here. The results are text, so the file is committed.

The synthetic cleanup set is text and uses no audio. A result that runs on transcripts of the generated audio records the macOS build whose voices made that audio, as `audio.osBuild` from `Fixtures/generated/manifest.json`, because another build gives other audio and so other transcripts. A pull request that changes the cleanup instructions, the guard or the cases reruns the command, commits the new file and states the results before and after.

Results from the owner's recordings, including the ten cleanup pairs, are never written here. They stay in the folder that `KNOT_LOCAL_FIXTURES` names, and only their numbers are recorded at the gate.

## Format

One JSON object, indented by two spaces, keys in the order shown, so that a change reads well in a diff.

```json
{
  "schema": 1,
  "set": "synthetic",
  "casesSha256": "<SHA-256 of Fixtures/cleanup/cases.json>",
  "model": {
    "name": "SystemLanguageModel.default",
    "osBuild": "<build of the Mac that ran it>",
    "sampling": "greedy"
  },
  "instructionsSha256": "<SHA-256 of the cleanup instructions>",
  "guardSha256": "<SHA-256 of the guard's table of allowed differences>",
  "date": "<YYYY-MM-DD>",
  "results": [
    {
      "id": "c13",
      "meaningCritical": true,
      "categories": ["punctuation", "amount", "negation"],
      "outcome": "cleaned",
      "modelOutput": "<the model's body, before the guard>",
      "guard": "accepted",
      "finalText": "<what the segment would show>",
      "keptAll": true,
      "matchedForbidden": [],
      "removed": [],
      "meaningChanged": false,
      "pass": true
    }
  ],
  "summary": {
    "meaningCritical": { "cases": 17, "pass": 0, "meaningChanged": 0 },
    "punctuationOnly": { "cases": 4, "pass": 0, "meaningChanged": 0 },
    "other": { "cases": 13, "pass": 0, "meaningChanged": 0 },
    "guardRejected": 0,
    "declined": 0
  }
}
```

- One entry per case, in the order of `cases.json`.
- `outcome` is `cleaned`, `declined` (a refusal, or an empty or malformed result) or `rejected` (the guard refused it). `guard` is `accepted`, or `rejected:` followed by the guard's reason code.
- `finalText` is `modelOutput` when the guard accepted it, and the raw transcript otherwise.
- `keptAll` and `matchedForbidden` are measured on `finalText`. `pass` is `keptAll` with no forbidden match.
- `meaningChanged` is measured on `modelOutput`: a lost `keep` phrase or a forbidden match. It shows what the model did even when the guard saved the note.
- `removed` lists the words of `raw` that `finalText` leaves out.
- `summary.punctuationOnly` counts the `punctuation` cases, which are also in `meaningCritical`.

## What the results decide

- One changed meaning among the meaning-critical cases sends the cleanup default to the owner's decision.
- A meaning-critical case whose `pass` was `true` in the committed file and is `false` in the new one blocks the pull request.
