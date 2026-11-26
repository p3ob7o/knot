# Knot's design

Knot opens ready for the next thought. A note reads as one page, with space between its segments. Each platform supplies its own controls, colours, type and glass. Knot supplies the mark, ink as tint, the red record control, the page and the words it speaks to the person.

## Which source rules

1. The product spec sets behaviour and names. [Product spec](docs/product-spec.md)
2. A system component takes precedence over the pixels of a mock. [Architecture](docs/architecture.md)
3. The screens govern what they draw. [Screen handoff](docs/design/handoff/screens/canvas.json)
4. The design system governs the rest, including tokens, glyphs and voice. [Design system](docs/design/handoff/system/README.md)

The owner's choice of 2026-11-26 gives the design system precedence over the screens for iPhone navigation and control placement. Notes is the root. The capture surface is a sheet at the large detent over Notes. The list button or a swipe down reveals Notes. The record control is 44 points on iPhone and iPad. A control the spec needs stays when a drawing leaves it out. [Platform handoff](docs/design/handoff/system/01-platforms.md)

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

Ink as tint is black in light appearance and white in dark. Keep the person's Mac accent when it is set. Attention uses `#C55300` in light appearance, including Increase Contrast. It uses the system orange in dark appearance.

Knot's secondary ink is an opaque sRGB grey. Its level is 0.35 in light appearance and 0.72 in dark. Increase Contrast uses 0.25 and 0.85. The resolved Mac paper measures 6.98:1 in light and 8.37:1 in dark, or 10.41:1 and 11.78:1 with Increase Contrast. On the handoff's white and black iOS paper references, the same ink calculates to 6.98:1 and 10.54:1 at standard contrast. The handoff's system secondary label is 3.4:1 in iOS light and 4.0:1 in Mac light. It is 6.4:1 and 5.9:1 in dark, respectively. Keep the tested ink until the owner rules.

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
| `Spacing.space1`, `tight` | `space-1` | 4 | Glyph gaps in metadata |
| `Spacing.space2`, `regular` | `space-2` | 8 | State line to text, play button to waveform |
| `Spacing.space3` | `space-3` | 12 | Notice padding and glyph gap, undo padding, Mac panel row gap |
| `Spacing.space4`, `loose`, `surfaceMargin` | `space-4` | 16 | Compact margin fallback |
| `Spacing.space5` | `space-5` | 20 | Regular margin fallback and Mac panel padding |
| `Spacing.space6`, `betweenSegments` | `space-6` | 24 | Between segments and above the capture field |
| `Spacing.space8` | `space-8` | 32 | Above the first segment under the toolbar |
| `Radii.radiusSm`, `small` | `radius-sm` | 8 | Small corners. The system draws sidebar selection. |
| `Radii.radiusMd`, `regular` | `radius-md` | 12 | Menu-open highlight and ink canvas frame |
| `Radii.radiusLg` | `radius-lg` | 20 | Inline notice |
| `Radii.radiusXl` | `radius-xl` | 26 | Floating Mac panel |
| `Radii.radiusFull`, `control` | `radius-full` | 999 | Capsule fallback. Use the system capsule shape. |
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

Use the system default when the handoff leaves something open. Add a line to section 2 of the deltas for the owner at M6. The orchestrator assigns changes to structure. Keep behaviour in the view model so a restyle stays in the view.

A designed state needs a named preview and a side-by-side image rendered from it. Run the system accessibility audit in each UI smoke test. Keep any exclusion with its reason in the audit file. A Mac UI test on the build Mac may launch, read the accessibility tree, audit and end the app. Use the hosted runner or the owner's M6 checklist for input. From M4, the owner opens the Mac milestone build from the folder selected for install. [WP-40 failure rules](docs/plan/WP-40.md)

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
