# VoiceStates

The six states of a voice segment, each named for what you can do, shown as one footnote line under the player.

**Provide:** the state and, for "Saved, text being made elsewhere", which device is doing the work.

- Use the words exactly: Saved on the Watch; Saved, text on its way; Saved, text being made elsewhere; Ready; Needs you; Kept, no text.
- Only "Needs you" is coloured (`attention`, with `exclamationmark.triangle.fill` and a Retry button). Pending states are `label-secondary` with a glyph. Ready has no line. "Kept, no text" has no glyph: it is final, not an error.
- Don't animate pending glyphs beyond the symbol's own `variableColor` effect, and never show a spinner.
