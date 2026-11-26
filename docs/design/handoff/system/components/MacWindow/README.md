# MacWindow

The Mac main window and menu bar extra: the stream in the sidebar, the note on paper, and the mark in the menu bar.

**Provide:** the stream, the selected note, and the state line for the menu bar extra.

- `NavigationSplitView`: sidebar rows in `mac-headline`, `mac-subheadline` and `mac-footnote`; the note in `mac-body` at `readable-width`.
- Window toolbar: New note, Share, and the note's `ellipsis` menu, grouped on glass.
- Hovering a segment lifts it onto `fill-quaternary` with a quiet `ellipsis`; it and secondary click open the segment menu.
- The menu bar extra is the mark as a template image. Its menu starts with a disabled state line only when there is something to say.
- Don't put the record control in the title bar, and don't colour the menu bar icon.
