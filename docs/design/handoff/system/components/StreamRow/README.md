# StreamRow

One note in the stream: title, preview, time, kinds, and at most one state mark.

**Provide:** the note's first line (title), a preview of its latest segment, its last-changed date, the kinds it holds, and its most urgent state.

- Title in `ios-headline` (one line, tail truncation), preview in `ios-subheadline` `label-secondary` (one line), meta line in `ios-footnote` `label-secondary`: compact time, then one glyph per kind in order of first use.
- The trailing mark: `attention` triangle (needs you) over `ellipsis.circle` (pending) over an `accent` dot (arrived, unseen).
- A recording-only note is titled "Recording, 0:42" until its text arrives.
- At accessibility sizes the preview goes first, the title wraps, and the mark joins the meta line.
- Don't show note text beyond one preview line, images, or tags.
