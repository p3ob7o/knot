# Notice

An inline message in the content layer, at the top of the note or stream it concerns.

**Provide:** a glyph, one or two sentences, up to two actions, and whether it can be dismissed.

- `fill-tertiary` ground, `radius-lg`, `space-3` vertical and `space-4` leading padding; the sentence in `ios-callout`; actions as `.bordered` `.controlSize(.small)` capsules in ink.
- The glyph is `label`, or `attention` for a surface problem and when notes can't be read.
- Show a close button only when ignoring the notice is safe. A notice that needs a decision (an edit conflict) stays until decided.
- Never use an alert, a toast or a banner sliding over content for these. The full list is in *States*.
