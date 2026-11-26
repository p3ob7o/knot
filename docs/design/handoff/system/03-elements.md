# Elements

The one system element to use for each need, and what never to use instead. If a need is not in this table, it is probably a feature Knot does not have; ask before adding an element.

| Need | Use | Never |
| --- | --- | --- |
| The stream | `List` with `.listStyle(.plain)` (iOS), `.sidebar` (Mac sidebar) | `LazyVStack` of cards, `.insetGrouped`, custom separators |
| A stream row | a `VStack` of three `Text`s in a `NavigationLink`; trailing state glyph | images, avatars, swipe-only actions |
| Row actions | `.swipeActions` (Delete, trailing; Copy, leading) and the same in `.contextMenu` | buttons inside the row |
| Search | `.searchable` (bottom toolbar on iPhone, sidebar on iPad and Mac) | a custom search bar |
| The capture surface (iPhone) | `.sheet` at the large detent, `.interactiveDismissDisabled(false)` | `fullScreenCover`, a custom modal, a tab |
| Two columns (iPad, Mac) | `NavigationSplitView` | `HStack` of panes, `TabView` |
| Toolbars | `.toolbar` with `ToolbarItem`s; `ToolbarSpacer` between groups | an overlay `HStack` of buttons |
| Done | `Button` with `checkmark`, `.buttonStyle(.glassProminent)`, `.keyboardShortcut(.return, modifiers: .command)` | text "Save", a coloured bar |
| New note | `Button` with `square.and.pencil`, `.keyboardShortcut("n")` | a floating action button |
| The record control | a custom `Button` with `.buttonStyle(.glass)` that becomes `.glassProminent` tinted `record` while live | a `Toggle`, a custom blob or ring |
| Note text and the field | `TextEditor` / `TextField(axis: .vertical)` per segment, plain style, no border | `TextField` with a rounded border, a form field |
| Ink | `PKCanvasView` wrapped in `UIViewRepresentable`, tool picker hidden | a custom drawing view |
| Voice playback | `Button` (`play.fill` / `pause.fill`) + Knot's waveform + `Text` duration | `VideoPlayer`, a `Slider` with a thumb |
| Segment actions | `.contextMenu` (and `accessibilityActions`); on hover, a quiet `Menu` with `ellipsis` | a button row on each segment, an action sheet |
| Delete | `Button(role: .destructive)` in a menu | a red button on screen, an alert to confirm |
| Undo after delete | Knot's glass undo capsule + `UndoManager` (shake, ⌘Z) | a toast library, an alert |
| Notices | Knot's inline notice view with `.buttonStyle(.bordered)` `.controlSize(.small)` actions | `.alert`, banners sliding from the top, toasts |
| Settings | `Form` with `.formStyle(.grouped)`; `Stepper`, `Toggle`, `Picker(.menu)`, `NavigationLink` | custom rows, segmented controls, sliders |
| Export, share, copy | `ShareLink`, `fileExporter`, `UIPasteboard` / `NSPasteboard` | custom share sheets |
| Mac quick capture | `NSPanel` (non-activating) hosting SwiftUI, `.glassEffect()` | a second `WindowGroup` window |
| Mac menu bar | `MenuBarExtra` with a template image of the mark | a coloured status item |
| Mac settings | the `Settings` scene | a preferences window of its own |
| Keyboard shortcuts | `.keyboardShortcut` and `.commands` | undiscoverable key handlers |
| Watch | one `View` with the record control; `WKHapticType` | `NavigationStack`, `List`, `TabView` pages |
| Widgets and controls | `WidgetKit` small and `accessoryCircular` widgets; `ControlWidgetButton` | medium or large widgets with note text |
| Recording outside the app | an App Intent conforming to `AudioRecordingIntent`, with a Live Activity | a background trick that skips the Live Activity |

## Things Knot never has

Tab bars, onboarding pages, empty-state illustrations, badges with counts on the app icon, folders, tags, colours per note, pinned notes, rich-text toolbars, custom fonts, custom alerts, splash screens, rating prompts, and any control that only some people would use.
