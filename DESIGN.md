# Knot's design

Knot opens ready for the next thought. A note reads as one page, with space between its segments. Each platform supplies its own controls, colours, type and glass. Knot supplies the mark, ink as tint, the red record control, the page and the words it speaks to the person.

## Which source rules

1. The product spec sets behaviour and names. [Product spec](docs/product-spec.md)
2. A system component takes precedence over the pixels of a mock. [Architecture](docs/architecture.md)
3. The screens govern what they draw. [Screen handoff](docs/design/handoff/screens/canvas.json)
4. The design system governs the rest, including tokens, glyphs and voice. [Design system](docs/design/handoff/system/README.md)

The orchestrator set this order. The owner can change it. The owner's choice of 2026-11-26 gives the design system precedence over the screens for iPhone navigation and control placement. Notes is the root. The capture surface is a sheet at the large detent over Notes. The list button or a swipe down reveals Notes. The record control is 44 points on iPhone and iPad. A control the spec needs stays when a drawing leaves it out. [Design direction](docs/design/direction.md)

## Theme roles

Views read `knotTheme` from the environment. Use the name of the role that fits the job. [Theme source](Packages/KnotKit/Sources/KnotUI/Theme/Theme.swift)

### Colour

| Role | Token | iPhone and iPad | Mac | Watch | Use |
|---|---|---|---|---|---|
| `background` | `background` | `systemBackground` | `textBackgroundColor` | System ground | Capture, note and stream paper |
| `backgroundSecondary` | `background-secondary` | `secondarySystemBackground` | `windowBackgroundColor` | System ground | Ink canvas frame |
| `backgroundGrouped` | `background-grouped` | `systemGroupedBackground` | `windowBackgroundColor` | System ground | Settings form ground |
| `backgroundGroupedCell` | `background-grouped-cell` | `secondarySystemGroupedBackground` | System grouped Form | System ground | Settings rows |
| `backgroundElevated` | `background-elevated` | System presentation | System presentation | System presentation | Sheet or popover ground |
| `label`, `textPrimary` | `label` | `.primary` | `labelColor` | `.primary` | Written text, titles and toolbar glyphs |
| `labelSecondary`, `textSecondary`, `pending`, `quietMark` | `label-secondary` | Knot secondary ink | Knot secondary ink | Knot secondary ink | Metadata, pending states, marks and provisional words |
| `labelTertiary` | `label-tertiary` | `tertiaryLabel` | `placeholderTextColor` | Secondary at 60% opacity | Placeholders and disabled elements |
| `labelQuaternary` | `label-quaternary` | `quaternaryLabel` | `quaternaryLabelColor` | Secondary at 36% opacity | Unplayed waveform |
| `fill` | `fill` | `systemFill` | `systemFill` | Secondary at 40% opacity | Player track |
| `fillSecondary` | `fill-secondary` | `secondarySystemFill` | `secondarySystemFill` | Secondary at 30% opacity | Pressed setup row |
| `fillTertiary`, `surface` | `fill-tertiary` | `tertiarySystemFill` | `tertiarySystemFill` | Secondary at 20% opacity | Inline notice ground and menu-open highlight |
| `fillQuaternary` | `fill-quaternary` | `quaternarySystemFill` | `quaternarySystemFill` | Secondary at 10% opacity | Segment hover |
| `separator` | `separator` | `separator` | `separatorColor` | Secondary at 30% opacity | System List row separator |
| `accent`, `arrived` | `accent` | Ink | Ink | Ink | Prominent controls and arrived marks |
| `onAccent` | `on-accent` | Inverse ink | Inverse ink | Inverse ink | Content on an ink fill |
| `record`, `recording` | `record` | `Color.red` | `Color.red` | `Color.red` | Live microphone and level |
| `onRecord` | `on-record` | White | White | White | Stop glyph on red |
| `attention`, `failed` | `attention` | Knot attention | Knot attention | Knot attention | Needs you. Use for a glyph alone on coloured grounds. |
| `toggleOn` | `toggle-on` | System green | System green | System green | Reference for Toggle. Let Toggle paint itself. |
| System focus | `focus-ring` | System focus effect | System focus ring in the person's accent | System focus | Keyboard focus |

The `accent` and `arrived` roles use ink on every platform for what Knot draws. Ink is black in light appearance and white in dark. On Mac, keep any use of the role as a tint within the individual control. Selection, focus and native controls keep the person's accent. The Mac catalogue's `AccentColor` entry applies only when the person's accent is Multicolor.

Attention uses `#C55300` in light appearance, including Increase Contrast. It uses the system orange in dark appearance.

Knot's secondary ink is the system's primary colour at 72% opacity (`Color.primary.opacity(0.72)`). The Mac accessibility audit guided this choice. The handoff's system secondary label and an opaque grey with higher nominal contrast both failed the audit on small text. The opaque grey failed at Subheadline in the Mac's main window, on the line that names the note being added to. Keep the translucent primary ink until the owner rules. On glass, including the Mac sidebar and floating panel, the ink's contrast depends on what lies behind it. WP-40c checks it on those surfaces.

A widget or Live Activity checks a role in both appearances before adopting it.

The system paints elevated grounds and Mac grouped rows. A transparent role leaves that paint visible. The Watch also supplies its own ground. The Watch's label, fill and separator fallbacks are for shared views where UIKit's semantic colours are unavailable.

`glass`, `glass-edge`, `shadow-glass` and `shadow-panel` are web preview stand-ins. The system draws the material, its rim and its shadow. [Colour tokens](docs/design/handoff/system/tokens.json)

### Type

Use system text styles at every Dynamic Type size. Use the style's emphasized weight for emphasis. System components draw their own titles, including the stream's Large Title on iPhone. The Watch fallbacks cover shared roles on a device with no note page or stream.

| Role | iPhone and iPad | Mac | Watch | Use |
|---|---|---|---|---|
| `noteTitle` | Title 2, emphasized (fallback) | Title 2, emphasized (fallback) | Title 2, emphasized (fallback) | Editable note heading |
| `rowTitle` | Headline (`ios-headline`) | Headline (`mac-headline`) | Headline (fallback) | Stream or sidebar title |
| `rowPreview` | Subheadline (`ios-subheadline`) | Subheadline (`mac-subheadline`) | Subheadline (fallback) | Latest segment preview |
| `body`, `emphasizedBody` | Body (`ios-body`) | Body (`mac-body`) | Body (`watch-body`) | Note text, provisional words, Settings rows and emphasis |
| `captureField` | Body (`ios-body`) | Title 2 (`mac-title2`) | Body (fallback) | Capture field on iPhone and iPad, floating panel field on Mac. The inline Mac field uses `body`. |
| `markdownHeading1` | Title 2, emphasized (`ios-title2`) | Title 1, emphasized (`mac-title1`) | Title 2, emphasized (fallback) | Markdown first heading |
| `markdownHeading2` | Title 3, emphasized (`ios-title3`) | Title 2, emphasized (`mac-title2`) | Title 3, emphasized (fallback) | Markdown second heading |
| `stateLine`, `caption` | Footnote (`ios-footnote`) | Subheadline (`mac-subheadline`) | Footnote (`watch-footnote1`) | Segment state or mark |
| `emphasizedStateLine` | Footnote, emphasized (`ios-footnote`) | Subheadline, emphasized (`mac-subheadline`) | Footnote, emphasized (`watch-footnote1`) | Needs you |
| `metaLine` | Footnote (`ios-footnote`) | Footnote (`mac-footnote`) | Footnote (fallback) | Stream time and kind glyphs |
| `appendCaption` | Footnote (`ios-footnote`) | Subheadline (`mac-subheadline`) | Footnote (fallback) | Adding to the note at a given time |
| `playerTime` | Caption (`ios-caption1`) | Caption (`mac-caption1`) | Caption (fallback) | Player time with monospaced digits |
| `recordingTime` | Body (`ios-body`) | Body (`mac-body`) | Title 2 (`watch-title2`) | Live timer with monospaced digits |
| `outcomeTitle` | Headline (fallback) | Headline (fallback) | Headline (`watch-headline`) | Short Watch outcome |
| `outcomeBody` | Body (fallback) | Body (fallback) | Body (`watch-body`) | Watch outcome sentence |
| `outcomeDetail` | Footnote (fallback) | Subheadline (fallback) | Footnote (`watch-footnote1`) | Second line of a Watch outcome |
| `notice`, `banner` | Callout (`ios-callout`) | Callout (`mac-callout`) | Callout (fallback) | Inline notice sentence |

### Spacing, shape and size

| Theme value | Token | Points | Use |
|---|---|---:|---|
| `spacing.space1`, `spacing.tight` | `space-1` | 4 | Glyph gaps in metadata |
| `spacing.space2`, `spacing.regular` | `space-2` | 8 | State line to text, play button to waveform |
| `spacing.space3` | `space-3` | 12 | Notice padding and glyph gap, undo padding, Mac panel row gap |
| `spacing.space4`, `spacing.loose`, `spacing.surfaceMargin` | `space-4` | 16 | Compact margin fallback |
| `spacing.space5` | `space-5` | 20 | Regular margin fallback and Mac panel padding |
| `spacing.space6`, `spacing.betweenSegments` | `space-6` | 24 | Between segments and above the capture field |
| `spacing.space8` | `space-8` | 32 | Above the first segment under the toolbar |
| `radii.radiusSm`, `radii.small` | `radius-sm` | 8 | Small corners. The system draws sidebar selection. |
| `radii.radiusMd`, `radii.regular` | `radius-md` | 12 | Menu-open highlight and ink canvas frame |
| `radii.radiusLg` | `radius-lg` | 20 | Inline notice |
| `radii.radiusXl` | `radius-xl` | 26 | Floating Mac panel |
| `radii.radiusFull`, `radii.control` | `radius-full` | 999 | Capsule fallback. Use the system capsule shape. |
| `sizes.hitTarget` | `hit-target` | 44 | Minimum tap size and the iPhone and iPad record control |
| `sizes.hitTargetMac` | `hit-target-mac` | 28 | Minimum click size and the Mac panel record control |
| `sizes.recordControlWatch` | `record-control-watch` | 88 | Watch record control diameter |
| `sizes.readableWidth` | `readable-width` | 672 | iPad and Mac text column fallback at default type size |
| `sizes.macPanelWidth` | `mac-panel-width` | 640 | Floating Mac panel width |
| `sizes.waveformBar` | `waveform-bar` | 2 | Waveform bar width and gap |

Use the safe area and system layout margins. Use the system's readable width so the text column can grow with Dynamic Type. Keep nested corners concentric. Use system shapes for system controls.

### Motion

| Role | System spring | Use |
|---|---|---|
| `listChange` | `.smooth` | A row or segment appears or leaves |
| `recordingPhase` | `.snappy` | The record control changes phase |
| `banner` | `.smooth` | A notice appears or leaves |

Resolve motion through `animation(for:reduceMotion:)`. With Reduce Motion on, the theme returns `nil` for each role. The handoff's crossfades await the owner's ruling. [Design deltas](docs/design/deltas.md)

## When a mock differs from the system

Use the system component and record the difference. Translate point sizes to Dynamic Type styles, hex values to colour roles and effects to system materials. Give controls, complications, widgets and the Live Activity the handoff's content, glyphs and strings. Let the system draw them.

Use the system default when the handoff leaves something open. Add a line to section 2 of the deltas for the owner to clear at M6. When the design changes structure, the orchestrator lists each difference in the deltas and assigns it. WP-40 owns the view models those differences touch. A late handoff or a change to structure can mean reworking the UI. Keep behaviour in view models and keep views thin so WP-40 can restyle them. [Design deltas](docs/design/deltas.md)

A test fails when a cell marked as designed in the brief's state matrix has no named preview. Render the side-by-side images from those previews. WP-40c renders the Mac images.

Run the system accessibility audit in each UI smoke test. Keep all exclusions in one file and give a reason for each. WP-41 makes the audit clean on every designed cell.

On the build Mac, a UI test may launch the app, read the accessibility tree, audit it and end it. Keep clicks, keystrokes, menu actions and `activate()` out of those tests. Use the hosted runner or the owner's M6 checklist for input.

Starting with M4, keep milestone installs and runs off the build Mac. For a Mac build, `scripts/install.sh` writes it to a folder the owner names. The owner opens it there. [WP-40 failure rules](docs/plan/WP-40.md)

## Review a view

- Take the stream, search, actions, toolbars, forms and other controls from the element map. [Element map](docs/design/handoff/system/03-elements.md)
- Keep actions used each visit in the toolbar. Put occasional actions in menus and segment actions in context menus with accessible equivalents.
- Keep notes, segments, stream rows, notices, Settings rows and widget content off glass. Use regular system glass for the named controls and keep glass from stacking.
- Use ink for content and tint. Use red for a live microphone, orange for Needs you and the system's own colours for native controls.
- Use SF Symbols at the text's weight. Keep the mark where Knot stands for itself outside its windows.
- Give each outcome a clear word or sentence, a glyph and its platform cue. Read recording start and stop with VoiceOver and keep focus steady.
- Let row previews give way at accessibility sizes. Keep titles, times and failed marks readable.
- Address the reader as “you”. Keep sentences short and in the present tense. Say what happened and what is safe. Start actions with verbs, use the spec's names and use compact absolute times. [Voice and accessibility](docs/design/handoff/system/README.md)

## Design sources

- [Handoff index](docs/design/handoff/README.md)
- [Chosen direction](docs/design/direction.md)
- [Resolutions where the handoff differs](docs/design/handoff-differences.md)
- [Differences from the implementation](docs/design/deltas.md)
- [States the handoff leaves open](docs/design/handoff-check.md)
