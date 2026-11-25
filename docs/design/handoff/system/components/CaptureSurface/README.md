# CaptureSurface

The iPhone capture surface: a sheet over the stream that appears with the field focused and the keyboard up.

**Provide:** the note the append window is open on (or none), the field's text, and the record control's phase.

- Toolbar: `list.bullet` leading (to the stream), Done trailing (`checkmark`, `.glassProminent`, ink). Above the keyboard: New note leading, the record control trailing.
- While the append window is open, show the note being added to above the field in `label-secondary`, under a footnote line: "Adding to the note from 9:38". New note is always one tap (⌘N) away.
- There is no save button. Text saves as typed; the capture ends on Done, ⌘↩, swiping the sheet down, or leaving the app.
- While recording, the field steps aside for the live segment; words appear in `label-secondary` and settle into `label`.
- Don't add a title field, formatting bar, mode switcher or tabs. Don't show the stream behind a tab bar.
