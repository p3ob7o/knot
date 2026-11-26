# RecordControl

The red dot: Knot's one custom control, which starts and stops a recording on every device.

**Provide:** the phase (`idle`, `starting`, `live`, `stopping`, `saved`, `couldNotStart`), the elapsed time while live or stopping, and the action. Its size comes from where it sits: 44 pt in an iPhone or iPad toolbar, 28 pt in the Mac panel, `record-control-watch` (88 pt) on the Watch.

**Use it** wherever recording can start: the capture surface, an open note, the Mac panel and window, the Watch. One per screen.

- Idle and Starting are `.buttonStyle(.glass)`; Live and Stopping are `.glassProminent` tinted `record`, carrying `stop.fill` in `on-record`. Saved shows `checkmark` for one second.
- Put the timer beside the control in `label` with monospaced digits, never on the red.
- The control that started a recording stops it. Press and hold is only for the Mac hotkey.
- Label it for VoiceOver by phase: "Record", "Stop recording, 0:12", "Saved".
- Don't add a ring, a glow, a pulse or a second colour. Don't put the word "Record" on it.
