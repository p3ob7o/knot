# Segment

One capture inside a note (typed text, a recording, or a drawing), stacked with the others on paper with the capture field last.

**Provide:** the segment's kind, its text (plain text with light Markdown), its recording or ink, its state and any mark.

- Stack segments with `space-6` between them and nothing else: no dividers, cards, bubbles or timestamps on each.
- Typed text is `ios-body` in `label`. A voice segment is a player (`play.fill`, waveform, duration) over its words. Ink is the drawing itself, in `label`, on the paper.
- A segment's marks and states take one footnote line at its foot, in `label-secondary` with one glyph; see *States*.
- Each segment edits in place. Actions are in its context menu, never as buttons on it.
- The capture field is always the last element of a note.
