#if os(iOS)
    import SwiftUI

    /// Notes keeps the native search field next to the control that opens capture.
    public struct PhoneNotesToolbar: ToolbarContent {
        let openSettings: () -> Void
        let showRecentlyDeleted: () -> Void
        let showCapture: () -> Void

        public init(
            openSettings: @escaping () -> Void, showRecentlyDeleted: @escaping () -> Void,
            showCapture: @escaping () -> Void
        ) {
            self.openSettings = openSettings
            self.showRecentlyDeleted = showRecentlyDeleted
            self.showCapture = showCapture
        }

        public var body: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: openSettings) { Text("Settings", bundle: .module) }
                    Button(SettingsRow.recentlyDeleted.title, action: showRecentlyDeleted)
                } label: {
                    moreLabel
                }
                .accessibilityShowsLargeContentViewer { moreLabel }
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button(action: showCapture) { captureLabel }
                    .accessibilityShowsLargeContentViewer { captureLabel }
                    .accessibilityIdentifier("shell.compose")
            }
        }

        private var moreLabel: some View {
            Label {
                Text("More", bundle: .module)
            } icon: {
                Image(systemName: "ellipsis")
            }
        }

        private var captureLabel: some View {
            Label {
                Text("Capture", bundle: .module)
            } icon: {
                Image(systemName: "square.and.pencil")
            }
        }
    }

    /// The leading button that dismisses the capture sheet back to Notes.
    public struct CaptureSheetToolbar: ToolbarContent {
        let showNotes: () -> Void

        public init(showNotes: @escaping () -> Void) {
            self.showNotes = showNotes
        }

        public var body: some ToolbarContent {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: showNotes) { notesLabel }
                    .accessibilityShowsLargeContentViewer { notesLabel }
                    .accessibilityIdentifier("shell.notes")
            }
        }

        private var notesLabel: some View {
            Label {
                Text("Notes", bundle: .module)
            } icon: {
                Image(systemName: "list.bullet")
            }
        }
    }
    /// The pushed note uses the same menu label and toolbar placement in the app and previews.
    public struct PhoneNoteToolbar<Items: View>: ToolbarContent {
        let items: Items

        public init(@ViewBuilder items: () -> Items) {
            self.items = items()
        }

        public var body: some ToolbarContent {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    items
                } label: {
                    label
                }
                .accessibilityShowsLargeContentViewer { label }
            }
        }

        private var label: some View {
            Label {
                Text("Note actions", bundle: .module)
            } icon: {
                Image(systemName: "ellipsis")
            }
        }
    }
#endif
