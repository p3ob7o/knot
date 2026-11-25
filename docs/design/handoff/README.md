# The design handoff

The return of the design round, as the owner gave it to the orchestrator on 2026-11-26. `PLAN.md` §6, "The design track", and `docs/architecture.md` §16 say how it is used.

- [`../direction.md`](../direction.md) records the direction it carries and which source rules where two of them differ.
- [`../handoff-check.md`](../handoff-check.md) is the check against the brief's state matrix, with the list of gaps for the designer.
- [`../handoff-differences.md`](../handoff-differences.md) lists where its two parts differ from each other and from the spec, with what holds for each.
- [`../deltas.md`](../deltas.md) lists where the handoff differs from what is built, and who has each difference.

## What is here

Two Claude Design artifacts, each as the files it was published with. Nothing was redrawn or reworded.

| Folder | Artifact | Version | Last published |
|---|---|---|---|
| `system/` | The design system, titled "Knot" | 1795598064-f94d | 2026-11-25, 09:14 UTC |
| `screens/` | The screens, titled "Knot Apps" | 1795606232-bee7 | 2026-11-25, 11:30 UTC |

The screens were drawn about two hours after the design system's last version, with that version of its tokens.

### `system/`

- `README.md` is the brand book: principles, voice, colour, typography, layout and spacing, shape and material, iconography, motion, haptics and sound, and accessibility.
- `01-platforms.md` gives the structure of each of the four apps and of the widgets, the controls, the complications and the Live Activity.
- `02-states.md` gives the record control's phases, the six states of a voice segment, the marks on a segment, the stream's marks, the notices and the first run.
- `03-elements.md` names the one system element for each need, and what Knot never has.
- `tokens.json` holds the colour roles in four themes (light, dark, and the Mac's two), the type styles of iOS, macOS and watchOS, spacing, radii, sizes and shadows.
- `components/` holds sixteen components. Fifteen have guidelines in a `README.md` and a `preview.html`; `Cover` is the artifact's cover and has a preview only. `components/bundle.css` holds the styles the previews use.
- `assets/Logos/` holds the mark in black and in white, with its rules. The paths are those of `Resources/Brand/knot-mark.svg`.
- `design-system.json` is the artifact's index.

### `screens/`

Nine artboards, and `canvas.json`, which lists them with their frames.

| File | Artboard | Views |
|---|---|---|
| `Main.dc.html` | iPhone, capture | Adding, Blank |
| `iPhone-Recording.dc.html` | iPhone, recording | Live, Starting, Saved |
| `iPhone-Stream.dc.html` | iPhone, Notes | |
| `iPhone-Note.dc.html` | iPhone, an open note | |
| `iPhone-Settings.dc.html` | iPhone, Settings | |
| `Mac-Window.dc.html` | Mac, the main window | |
| `States.dc.html` | Segment states and notices | |
| `Watch.dc.html` | Apple Watch, record: ready, live, saved, too short | |
| `Widgets.dc.html` | Widgets and the mark | |

`ds/knot/tokens.json` is the copy of the design system's tokens that the screens were drawn with. It has the same bytes as `system/tokens.json`.

## How to read the files

- A `.dc.html` file is a design component page. Its markup is the screen. `sc-if` shows a part on a condition and `sc-for` repeats one, and the script at the end of the file gives their values and names the views. A length in CSS pixels is a length in points.
- The pages load a runtime of the design tool, `support.js`, which is not here. They are read as source, and they do not draw from this folder.
- A `preview.html` draws a component with the classes of `components/bundle.css`.
- The values in `tokens.json` are references for design work. The brand book says that the apps use the system's semantic colours and text styles by name.
- The glyphs in the pages are hand-drawn stand-ins. The brand book's table names the SF Symbol for each.

## What is not here

- The links to the two artifacts. This repository is public, and each link opens its artifact to whoever holds it. The orchestrator's journal has them.
- One value was taken out for the same reason: the link in the `designSystems` entry of `screens/canvas.json`, which is now an empty string.
- The design tool's own pages and runtime.

## The text in the pictures

The notes that the screens and the previews show are the design tool's samples. None is a note of anyone's.
