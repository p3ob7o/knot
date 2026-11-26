# WatchRecord

The Watch app's one screen: the record control and one line of outcome.

**Provide:** the phase, the elapsed time, and the outcome (saved, discarded, couldn't start, stopped at the limit).

- Idle shows only the control. Live shows the timer in `watch-title2`. Outcomes use `watch-headline` or `watch-body`, with a second line in `watch-footnote1`, `label-secondary`.
- Every outcome plays its haptic (`WKHapticType`) and returns to idle after three seconds.
- Recordings stay "Saved on the Watch" until the iPhone takes them; the Watch never shows text or a list.
- Don't add pages, a list of recordings, a settings screen or a second button.
