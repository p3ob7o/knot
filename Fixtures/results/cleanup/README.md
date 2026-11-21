# Cleanup results, synthetic set

WP-14 owns this folder. It writes the first results; WP-04 only made the place and stated the format, which WP-14's first pull request extended with the punctuation-only results and the titles.

`knot-eval cleanup --set synthetic`, or `knot-eval --set synthetic`, cleans every case of [`../../cleanup/cases.json`](../../cleanup/cases.json) and of [`../../cleanup/cases-extra.json`](../../cleanup/cases-extra.json) twice, with full cleanup and with punctuation only, as the app cleans it through `ModelCleaner`, proposes a title for each, and writes `synthetic.json` here. The results are text, so the file is committed. With greedy sampling, two runs on the same model write the same file, but for its date.

The synthetic cleanup set is text and uses no audio. A result that runs on transcripts of the generated audio records the macOS build whose voices made that audio, as `audio.osBuild` from `Fixtures/generated/manifest.json`, because another build gives other audio and so other transcripts. A pull request that changes the cleanup instructions, the guard or the cases reruns the command, commits the new file and states the results before and after.

Results from the owner's recordings, including the ten cleanup pairs, are never written here. They stay in the folder that `KNOT_LOCAL_FIXTURES` names, and only their numbers are recorded at the gate.

## Format

One JSON object, indented by two spaces, keys in the order shown, so that a change reads well in a diff.

```json
{
  "schema": 1,
  "set": "synthetic",
  "casesSha256": "<SHA-256 of Fixtures/cleanup/cases.json>",
  "extraCasesSha256": "<SHA-256 of Fixtures/cleanup/cases-extra.json>",
  "model": {
    "name": "<SystemLanguageModel.variant.displayName>",
    "osBuild": "<build of the Mac that ran it>",
    "sampling": "greedy"
  },
  "instructionsSha256": "<SHA-256 of the three instructions, full, punctuation only and title, joined by a line \"--\">",
  "guardSha256": "<SHA-256 of the guard's table of allowed differences>",
  "date": "<YYYY-MM-DD>",
  "results": [
    {
      "id": "c13",
      "group": "main",
      "meaningCritical": true,
      "categories": ["punctuation", "amount", "negation"],
      "outcome": "cleaned",
      "modelOutput": "<the model's body, before the guard>",
      "guard": "accepted",
      "finalText": "<what the segment would show>",
      "keptAll": true,
      "matchedForbidden": [],
      "removed": [],
      "readingsHeld": true,
      "questionAdded": false,
      "meaningChanged": false,
      "pass": true,
      "title": "<the proposed title that passed the title check, or null>",
      "titleDropped": "<why the title was dropped: does_not_fit, filler_sounds, negation_left_out, or null>",
      "punctuationOnly": {
        "outcome": "cleaned",
        "modelOutput": "<the model's body under punctuation only, before the guard>",
        "guard": "accepted",
        "readingsHeld": true,
        "questionAdded": false,
        "meaningChanged": false,
        "pass": true
      }
    }
  ],
  "summary": {
    "meaningCritical": { "cases": 17, "pass": 0, "meaningChanged": 0, "reachedTheNote": 0 },
    "punctuationOnly": { "cases": 4, "pass": 0, "meaningChanged": 0, "reachedTheNote": 0 },
    "other": { "cases": 13, "pass": 0, "meaningChanged": 0, "reachedTheNote": 0 },
    "beyondTheGuard": { "cases": 5, "pass": 0, "meaningChanged": 0, "reachedTheNote": 0 },
    "transcriberForm": { "cases": 6, "pass": 0, "meaningChanged": 0, "reachedTheNote": 0 },
    "guardRejected": 0,
    "declined": 0,
    "punctuationOnlyMode": { "cleaned": 0, "rejected": 0, "declined": 0, "meaningChanged": 0, "reachedTheNote": 0, "meaningCriticalPass": 0 },
    "titles": { "kept": 0, "droppedForNegationLeftOut": 0 }
  }
}
```

- One entry per case, in the order of `cases.json`.
- `outcome` is `cleaned`, `declined` (a refusal, a guardrail violation, or an empty or malformed result) or `rejected` (the guard refused it). `guard` is `accepted`, `rejected:` followed by the guard's reason code, or `not_run` for a decline, which the guard never sees.
- `finalText` is `modelOutput` when the guard accepted it, and the raw transcript otherwise.
- `keptAll`, `matchedForbidden` and `readingsHeld` are measured on `finalText`. `readingsHeld` is null for a case with no readings, and for a final text that is the raw transcript, which is the speaker's own. `questionAdded` is true when the final text ends as a question and neither the case's reference nor its raw text does, unless the case has `mayEndAsQuestion`; every case is judged for it. `pass` is `keptAll`, no forbidden match, no reading broken and no question added.
- `group` is `main` for the cases of `cases.json`, and `beyond-the-guard` or `transcriber-form` for those of `cases-extra.json`. `summary.meaningCritical`, `punctuationOnly` and `other` count the main set; `beyondTheGuard` and `transcriberForm` count the extra cases apart.
- `reachedTheNote` counts the changed meanings that the guard accepted, so that the note shows them: what the guard cannot see.
- `meaningChanged` is measured on `modelOutput`: a lost `keep` phrase, a forbidden match, a broken reading or a question added. It shows what the model did even when the guard saved the note.
- `removed` lists the words of `raw` that `finalText` leaves out.
- `summary.punctuationOnly` counts the `punctuation` cases, which are also in `meaningCritical`.
- The top-level fields of a result score full cleanup. `punctuationOnly` scores the same case under punctuation only, by the same rules, and `summary.punctuationOnlyMode` counts those: the owner chooses between full cleanup, punctuation only and off.
- `title` is what `ModelCleaner` proposes for the full cleanup's final text, after KnotCore's `TitleRule.fits`.
- The command prints counts only. A meaning-critical case whose `pass` was `true` in the file it replaces is printed by its ID, and the command then exits with status 1.

## What the results decide

- One changed meaning among the meaning-critical cases sends the cleanup default to the owner's decision.
- A meaning-critical case whose `pass` was `true` in the committed file and is `false` in the new one blocks the pull request.
