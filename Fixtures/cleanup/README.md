# Cleanup evaluation set

`cases.json` holds 30 raw transcripts, each with notes on what a correct cleanup keeps and removes. 17 are meaning-critical: negations, amounts, dates, names, spoken self-corrections, cases in which only the punctuation differs, and one filler look-alike. The evaluation reports them apart from the other 13.

They follow the v1 rules of docs/product-spec.md §5 and docs/architecture.md §9: cleanup may add punctuation, case and structure, and remove fillers, repeated words and restarts that begin again with the same word. It may not add, replace or reorder a word. It leaves a spoken self-correction as it was said, and numbers as they were transcribed.

## Fields

| Field | Meaning |
|---|---|
| `id` | `c01` to `c30`. Never reused. |
| `title` | A short name. |
| `categories` | What the case tests: `negation`, `amount`, `date`, `name`, `self-correction`, `punctuation`, `filler`, `filler-lookalike`, `repeat`, `restart`, `list`, `paragraphs`, `question`, `already-clean`, `run-on`, `casing`, `single-filler`. |
| `meaningCritical` | `true` when a wrong cleanup changes what the note means. |
| `raw` | The transcript as a transcriber might give it: lower case except names, `I` and acronyms, no punctuation, numbers as digits or words. |
| `reference` | One correct cleanup. Others may be correct too. |
| `keep` | Phrases a correct cleanup must keep, in this order. Compare them as words: ignore case, punctuation and hyphens, so "forty-two" matches "forty two". |
| `remove` | The words the reference removes. A cleanup that keeps them is less clean, not wrong. |
| `mustNotMatch` | Case-insensitive regular expressions that a correct cleanup never matches. Every `punctuation` case has them, because the guard cannot catch those errors: the words stay the same. |
| `readings` | Correct cleanups written with their marks, for every meaning-critical case. Between two words a cleanup has none, a pause (`,` `;` `:` or a dash), a stop (`.` `!` or a line break) or a question (`?`). Where a reading has none or a pause, a cleanup may have none or a pause; where it has a stop, a pause or a stop; a gap written `{…}` allows exactly what the braces hold: `_` none, `,` a pause, `.` a stop, `?` a question. The end compares as a question or not. A cleanup matches when it matches one reading, so a break in a place nobody foresaw fails. `knot-eval`'s `CleanupReadings` reads them. |
| `group` | In `cases-extra.json` only: `beyond-the-guard` or `transcriber-form`. |
| `mayEndAsQuestion` | `true` for a case whose text may fairly end as a question though its reference does not, with `notes` saying why. Every other case changes its meaning when a cleanup ends it as a question and neither its reference nor its raw text does. |
| `wrong` | Example outputs that change the meaning, each with `why`. |
| `notes` | What the case is about, for a person reading the results. |

`Fixtures/tools/generate.sh --check` checks the set itself: 30 cases, at least ten meaning-critical ones with each category the brief names, a reference that only removes the words in `remove` (words compared without case, punctuation or hyphens), `keep` phrases present in order, and a `mustNotMatch` that catches every wrong output of a punctuation case and spares the reference.

## The extra cases

[`cases-extra.json`](cases-extra.json) holds cases that WP-14's review added, in the same form, counted apart from the 30: five of the changes the guard cannot see (`beyond-the-guard`: a restart that swaps a name or an item, a meant repeat of a word that is not protected), and six written as the transcriber writes (`transcriber-form`: mostly capitalised and punctuated, numbers in digits and in words, fillers left in). `Fixtures/tools/generate.sh --check` checks `cases.json` only.

## Scoring

WP-14 owns the evaluation and its format, in [`../results/cleanup/README.md`](../results/cleanup/README.md). The rules this set assumes:

- A case passes when the final text keeps every `keep` phrase in order, matches no `mustNotMatch` pattern, does not end as a question where the case does not (`mayEndAsQuestion`), and, when the final text is the cleaned one, matches one of its `readings`. The final text is the cleaned text when the guard accepts it, and the raw transcript when it does not.
- A case changes the meaning when the model's output, before the guard, loses a `keep` phrase, matches a `mustNotMatch` pattern, matches none of its `readings`, or ends as a question where the case does not. Results record this for every case, so that what the model does is visible even when the guard saves the note.
- One changed meaning among the meaning-critical cases sends the cleanup default to the owner's decision (WP-04 failure rules).
- A meaning-critical case that passed and now fails blocks the pull request.

## Adding a case

Add it at the end with the next free ID, keep the categories to the list above, and run `Fixtures/tools/generate.sh --check --lint-only`. A new case changes the committed results, so the same pull request reruns `knot-eval --set synthetic`.
