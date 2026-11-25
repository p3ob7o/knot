# Platforms

One idea, four apps. Each is built from its own platform's structure at OS 27, so Knot on the Mac behaves like a Mac app and Knot on the Watch like a Watch app. Functionality stays the same as size classes change; only how much is visible changes.

## iPhone

- **Structure.** The stream is the root: a `NavigationStack` with the large title "Notes" and a plain `List`. The capture surface is a `.sheet` at the large detent over it, presented on launch and from every way in. Swiping the sheet down ends the capture and shows the stream: the stream is one gesture away, never a tab.
- **Capture surface.** Toolbar: `list.bullet` (to the stream) leading, Done (`checkmark`, `.glassProminent`, ink) trailing. The field has focus as the sheet appears. Above the keyboard, a `ToolbarItemGroup(placement: .keyboard)` carries New note (`square.and.pencil`) leading and the record control trailing; with the keyboard down they sit in the bottom toolbar. Nothing else.
- **Stream.** `.searchable` puts search in the bottom toolbar, beside New note (`square.and.pencil`), which presents the capture surface. The top bar carries one `ellipsis` menu: Settings, Recently deleted. Rows push the note.
- **Note.** A pushed page: date line, segments, the capture field last. The toolbar has the back button and one `ellipsis` menu (Copy note, Share note…, Delete note). The record control sits in the bottom toolbar while the field is not focused.
- **Ways in.** App icon and widgets open the capture surface on the keyboard. The Action Button, Lock Screen and Control Center controls start recording without opening the app (an App Intent with `AudioRecordingIntent`), show a Live Activity with a stop button, and end with the same haptics. Siri and Shortcuts expose "Add to Knot" and "Record in Knot".

## iPad

- **Structure.** `NavigationSplitView` with two columns: the stream in the sidebar column, the open note in the detail column. In compact width (Slide Over, narrow windows) it collapses to the iPhone structure on its own.
- **Capture.** The detail column is the capture surface: on launch it shows the note the append window is open on, or a new empty note, with the field focused. Done and New note are in the detail toolbar; the record control is in the bottom toolbar of the detail column.
- **Pencil.** Touching the Pencil to the page opens a blank ink canvas below the last segment (`PKCanvasView`, the system tool picker hidden; ink only, in `label`). The canvas grows as you write and ends only with Done, never with a stray touch. A Sketch control (`pencil.tip`) in the toolbar opens the same canvas with a finger.
- **Keyboard and pointer.** The menu bar (`.commands`) lists every shortcut. The pointer hovers segments onto `fill-quaternary` and shows a quiet `ellipsis` for the segment menu.

## Mac

- **Main window.** `NavigationSplitView`: the stream in the sidebar (glass, extending to the window's edge as macOS 27 draws it), the note in the detail on `background` at `readable-width`. The window toolbar holds New note, Share and the note's `ellipsis` menu; the record control sits at the trailing bottom of the note, never in the title bar.
- **Floating capture panel.** A non-activating `NSPanel` over any app, `mac-panel-width` wide, centred in the upper third of the active screen, on glass with `radius-xl` corners. The field uses `mac-title2` so a thought lands large. A footnote line names the keys (⌘↩ Done, ⌘N New note, esc Close); the 28 pt record control is trailing. It grows with the text to half the screen and never steals focus from the app behind it until you type.
- **Hotkey.** Tap to type, hold to record; releasing stops. The person chooses the key in Settings (no default steals a common shortcut); the menu bar extra shows whatever they chose.
- **Menu bar extra.** `MenuBarExtra` with the mark as a template image. Its menu: a disabled state line when there is something to say ("2 captures waiting to sync"), New Capture, Start Recording, Open Knot, Settings…, Quit Knot.
- **Settings.** The `Settings` scene, one grouped `Form`: the iPhone rows plus Hotkey (a shortcut recorder) and Open at login.
- **The command line and MCP.** `knot` and the MCP server write segments like any device; their segments carry the quiet `apple.terminal` mark.

## Apple Watch

- **One screen.** The record control at `record-control-watch`, centred, and one outcome line under it. No list, no text entry, no settings, no navigation.
- **States.** Idle shows the control and no words. Live shows the timer in `watch-title2`. Outcomes use `watch-headline` ("Saved") or `watch-body` ("Too short. Nothing was kept."), with a second line in `watch-footnote1`, `label-secondary`. The screen returns to idle after three seconds.
- **Ways in.** Complications, the Smart Stack, Control Center, the Ultra's Action Button and Double Tap all open Knot already recording.
- **After capture.** A recording is "Saved on the Watch" until the iPhone takes it; the Watch never shows text.

## Widgets, controls, complications and the Live Activity

- **Launchers, not views.** They show state, never note text: a recording's timer, how many captures wait, how many need you. Every one has one action.
- **Home Screen widget (small).** The mark top-leading, "Knot" and one state line at the bottom ("2 waiting", "1 needs you", or nothing). Opens the capture surface on the keyboard. Mark it `widgetAccentable` so tinted and clear modes render it in the person's ink.
- **Lock Screen accessory.** `accessoryCircular`: the mark. Opens on the keyboard.
- **Controls** (Control Center, Lock Screen, Action Button). A `ControlWidgetButton` "Record" with `mic`; while live it shows `stop.fill` tinted `record` and the timer.
- **Live Activity.** Lock Screen: a red dot, "Recording", the timer and a stop button, nothing else. Dynamic Island: compact leading `mic.fill` in `record`, compact trailing the timer; expanded adds the live waveform; minimal is `mic.fill` alone.
- **Complications.** Circular: the mark. Corner: the mark. Rectangular and Smart Stack: the mark, "Record" and one state line. All open recording. In tinted faces they take the face's ink.
