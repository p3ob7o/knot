#if !os(watchOS)
    import AppIntents
    import KnotIntents

    /// The App Shortcuts of the text intents, with their phrases: "New note", "Append to note"
    /// and "Search notes" (docs/product-spec.md §6). The recording intents add theirs with
    /// WP-19's second pull request.
    struct KnotShortcuts: AppShortcutsProvider {
        static var appShortcuts: [AppShortcut] {
            AppShortcut(
                intent: CreateNoteIntent(),
                phrases: [
                    "New note in \(.applicationName)",
                    "Make a note in \(.applicationName)",
                    "Create a \(.applicationName) note",
                ],
                shortTitle: "New Note",
                systemImageName: "square.and.pencil")
            AppShortcut(
                intent: AppendTextIntent(),
                phrases: [
                    "Append to a note in \(.applicationName)",
                    "Add to a note in \(.applicationName)",
                ],
                shortTitle: "Append to Note",
                systemImageName: "text.append")
            AppShortcut(
                intent: FindNotesIntent(),
                phrases: [
                    "Search notes in \(.applicationName)",
                    "Find notes in \(.applicationName)",
                ],
                shortTitle: "Search Notes",
                systemImageName: "magnifyingglass")
        }
    }
#endif
