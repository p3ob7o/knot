# MacCapture

The Mac's floating capture panel: a glass panel over any app, opened by the hotkey.

**Provide:** the field's text, the append-window note (if open), and the record control's phase.

- `mac-panel-width` wide, `radius-xl` corners, `space-5` padding, centred in the upper third of the active screen; it grows with the text up to half the screen.
- Set the field in `mac-title2`; the append caption and key hints in `mac-subheadline`.
- Tap the hotkey to type; hold it to record, release to stop. Esc, ⌘↩ or clicking elsewhere ends the capture.
- Use a non-activating `NSPanel` so the app behind keeps its menu bar until you type.
- Don't add a title bar, traffic lights, a toolbar or a list of recent notes.
