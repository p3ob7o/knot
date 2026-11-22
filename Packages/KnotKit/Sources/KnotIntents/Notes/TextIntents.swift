// The system notes schema is unavailable on watchOS, where KnotIntents is linked for its other
// types, and the Watch has no store to write to.
#if !os(watchOS)
    import AppIntents
    import Foundation
    import KnotCore

    /// CreateNote: a new note, on the system notes schema's `createNote` (docs/architecture.md
    /// §14). It only writes, so it runs on a locked device, in the app's process, in the
    /// background. The capture goes through the engine; the title, once the capture is stored,
    /// through `NoteStore.setTitle` (`TextIntentActions.createNote`).
    ///
    /// What Knot does with the schema's parameters is the orchestrator's ruling of 2026-11-22:
    /// `name` and `content` by `CreateNoteRule`; `attachments` refused, with nothing written;
    /// `isPinned` and `folder` ignored, with the note saved and the dialog saying so.
    @AppIntent(schema: .notes.createNote)
    public struct CreateNoteIntent: KnotEnvironmentReading {
        public static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
        public static var allowedExecutionTargets: ExecutionTargets { [.main] }
        public static var supportedModes: IntentModes { .background }

        public var name: AttributedString
        public var content: AttributedString?
        public var attachments: [IntentFile]
        public var isPinned: Bool
        public var folder: NoteFolderEntity?

        @Dependency(default: KnotIntentEnvironment.unavailable) public var knot: KnotIntentEnvironment

        public init() {}

        /// An intent that reads the dependency from `manager`, for tests.
        public init(manager: AppDependencyManager) {
            _knot = Dependency(manager: manager, default: KnotIntentEnvironment.unavailable)
        }

        public func perform() async throws -> some ReturnsValue<NoteEntity> & ProvidesDialog {
            let environment = try IntentFailure.accessor { () throws(KnotError) in try self.environment() }
            guard attachments.isEmpty else { throw IntentFailure(.attachmentsRefused) }
            guard let plan = CreateNoteRule.plan(name: String(name.characters), content: content.map(Self.text))
            else { throw IntentFailure(.noText) }
            let written = try await IntentFailure.actions { () async throws(TextIntentError) in
                try await TextIntentActions.createNote(plan, in: environment)
            }
            let pinned = isPinned
            let foldered = folder != nil
            if pinned || foldered {
                TextIntentActions.log.capture(
                    written.capture.captureID, "intent_create_note_setting_ignored", .flag("pinned", pinned),
                    .flag("folder", foldered))
            }
            let dialog = Self.dialogText(pinned: pinned, foldered: foldered)
            return .result(
                value: NoteEntity(written.note), dialog: IntentDialog(LocalizedStringResource(stringLiteral: dialog)))
        }

        static func text(_ attributed: AttributedString) -> String {
            String(attributed.characters)
        }

        /// What Siri says once the note is saved, and why a pin or a folder asked for is not there.
        static func dialogText(pinned: Bool, foldered: Bool) -> String {
            switch (pinned, foldered) {
            case (false, false): "Saved to Knot."
            case (true, false): "Saved to Knot. Knot has no pins, so the note is not pinned."
            case (false, true): "Saved to Knot. Knot has no folders, so the note is in the stream."
            case (true, true): "Saved to Knot. Knot has no pins and no folders, so the note is in the stream, unpinned."
            }
        }
    }

    /// AppendText: text added to the end of a note, on the system notes schema's `appendText`
    /// (docs/architecture.md §14). It writes, so it runs only in the app's process, and it picks a
    /// note, so it requires the device unlocked, as the schema's own policy does.
    @AppIntent(schema: .notes.appendText)
    public struct AppendTextIntent: KnotEnvironmentReading {
        public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
        public static var allowedExecutionTargets: ExecutionTargets { [.main] }
        public static var supportedModes: IntentModes { .background }

        public var content: AttributedString
        public var target: NoteEntity

        @Dependency(default: KnotIntentEnvironment.unavailable) public var knot: KnotIntentEnvironment

        public init() {}

        /// An intent that reads the dependency from `manager`, for tests.
        public init(manager: AppDependencyManager) {
            _knot = Dependency(manager: manager, default: KnotIntentEnvironment.unavailable)
        }

        public func perform() async throws -> some ReturnsValue<NoteEntity> & ProvidesDialog {
            let environment = try IntentFailure.accessor { () throws(KnotError) in try self.environment() }
            guard let reference = NoteReference(target.id) else {
                throw IntentFailure(.knot(KnotError.notFound))
            }
            let text = String(content.characters)
            let written = try await IntentFailure.actions { () async throws(TextIntentError) in
                try await TextIntentActions.appendText(text, to: reference, in: environment)
            }
            return .result(value: NoteEntity(written.note), dialog: "Added to the note in Knot.")
        }
    }

    /// FindNotes: the notes whose title or text holds every word of a search, or the latest
    /// notes, newest first (docs/architecture.md §14). It reads notes, so it requires the device
    /// unlocked, and it runs only in the app's process, which alone opens the store.
    public struct FindNotesIntent: AppIntent, KnotEnvironmentReading {
        public static var title: LocalizedStringResource { "Find Notes" }
        public static var description: IntentDescription? {
            IntentDescription("Finds the notes in Knot that hold every word you search for, newest first.")
        }
        public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }
        public static var allowedExecutionTargets: ExecutionTargets { [.main] }
        public static var supportedModes: IntentModes { .background }

        @Parameter(title: "Search for", description: "The words to look for. With none, the latest notes.")
        public var query: String?

        @Dependency(default: KnotIntentEnvironment.unavailable) public var knot: KnotIntentEnvironment

        public init() {}

        /// An intent that reads the dependency from `manager`, for tests.
        public init(manager: AppDependencyManager) {
            _knot = Dependency(manager: manager, default: KnotIntentEnvironment.unavailable)
        }

        public static var parameterSummary: some ParameterSummary {
            Summary("Find notes with \(\.$query)")
        }

        public func perform() async throws -> some ReturnsValue<[NoteEntity]> {
            let environment = try IntentFailure.accessor { () throws(KnotError) in try self.environment() }
            let query = self.query
            let found = try await IntentFailure.ports { () async throws(KnotError) in
                try await TextIntentActions.findNotes(query, in: environment)
            }
            return .result(value: found.map(NoteEntity.init))
        }
    }
#endif
