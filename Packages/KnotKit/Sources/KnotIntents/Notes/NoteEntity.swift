// The system notes schema is unavailable on watchOS, where KnotIntents is linked for its other
// types; the Watch shows no note content in any case (docs/product-spec.md §6).
#if !os(watchOS)
    import AppIntents
    import Foundation
    import KnotCore

    /// A note, as Siri and Shortcuts see it: the entity of the system notes schema.
    ///
    /// It is not indexed, so nothing about a note appears in Spotlight (docs/architecture.md §14),
    /// and its query requires the device unlocked, as the schema's own policy for the entity does.
    /// Knot has no pins, no folders and no attachments (docs/product-spec.md §15): the entity
    /// reports none of them.
    @AppEntity(schema: .notes.note)
    public struct NoteEntity {
        public static let defaultQuery = NoteQuery()

        /// A `NoteReference` in its text form.
        public let id: String

        /// The title, or the first line where there is none, as the stream shows it.
        public var name: AttributedString
        public var content: AttributedString?
        public var attachments: [IntentFile]
        public var isPinned: Bool
        public var creationDate: Date?
        public var modificationDate: Date?
        public var folder: NoteFolderEntity?

        public init(_ summary: NoteSummary) {
            id = summary.reference.text
            name = AttributedString(summary.name)
            content = summary.content.map { AttributedString($0) }
            attachments = []
            isPinned = false
            creationDate = summary.createdAt
            modificationDate = summary.modifiedAt
            folder = nil
        }

        public var displayRepresentation: DisplayRepresentation {
            DisplayRepresentation(title: "\(String(name.characters))")
        }
    }

    /// The query of the note entity: by ID, by words, and the latest notes as suggestions. It
    /// reads the store, so it runs only in the app, and the entity's own policy keeps it to an
    /// unlocked device.
    public struct NoteQuery: EntityStringQuery, KnotEnvironmentReading {
        @Dependency(default: KnotIntentEnvironment.unavailable) public var knot: KnotIntentEnvironment

        public static var allowedExecutionTargets: ExecutionTargets { [.main] }

        public init() {}

        public func entities(for identifiers: [String]) async throws -> [NoteEntity] {
            try await Self.entities(for: identifiers, from: knot)
        }

        public func entities(matching string: String) async throws -> [NoteEntity] {
            try await Self.find(string, from: knot)
        }

        public func suggestedEntities() async throws -> [NoteEntity] {
            try await Self.find(nil, from: knot)
        }

        /// The notes these IDs name, as the system's flow gives the query its dependency.
        static func entities(for identifiers: [String], from knot: KnotIntentEnvironment) async throws
            -> [NoteEntity]
        {
            let environment = try IntentFailure.accessor { () throws(KnotError) in try knot.environment() }
            var entities: [NoteEntity] = []
            for identifier in identifiers {
                guard let reference = NoteReference(identifier) else { continue }
                let record = try await IntentFailure.ports { () async throws(KnotError) in
                    try await TextIntentActions.shownNote(reference, in: environment)
                }
                guard let record else { continue }
                // The entity keeps the ID it was asked for, so a capture's reference resolves.
                var summary = NoteSummary(record)
                summary.reference = reference
                entities.append(NoteEntity(summary))
            }
            return entities
        }

        /// The notes that hold every word of `query`, or the latest notes.
        static func find(_ query: String?, from knot: KnotIntentEnvironment) async throws -> [NoteEntity] {
            let environment = try IntentFailure.accessor { () throws(KnotError) in try knot.environment() }
            return try await IntentFailure.ports { () async throws(KnotError) in
                try await TextIntentActions.findNotes(query, in: environment).map(NoteEntity.init)
            }
        }
    }

    /// A folder of the system notes schema, which `createNote` names as a parameter and the
    /// note entity as a property. Knot has no folders (docs/product-spec.md §15), so its query
    /// returns none, and nothing can be chosen. The orchestrator's ruling of 2026-11-22.
    @AppEntity(schema: .notes.folder)
    public struct NoteFolderEntity {
        public static let defaultQuery = NoteFolderQuery()

        public let id: String
        public var name: String
        public var parentFolder: NoteFolderEntity?
        public var account: NoteAccountEntity?

        /// A folder of that name. Knot makes none; a value can only come from elsewhere.
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }

        public var displayRepresentation: DisplayRepresentation {
            DisplayRepresentation(title: "\(name)")
        }
    }

    /// The query of the folder entity: Knot has no folders, so it finds none.
    public struct NoteFolderQuery: EntityStringQuery {
        public static var allowedExecutionTargets: ExecutionTargets { [.main] }

        public init() {}

        public func entities(for identifiers: [String]) async throws -> [NoteFolderEntity] { [] }
        public func entities(matching string: String) async throws -> [NoteFolderEntity] { [] }
        public func suggestedEntities() async throws -> [NoteFolderEntity] { [] }
    }

    /// An account of the system notes schema. The schema's folder entity requires it as a
    /// property, so Knot declares it, although docs/architecture.md §14 does not name it. Knot
    /// has no accounts, so its query finds none.
    @AppEntity(schema: .notes.account)
    public struct NoteAccountEntity {
        public static let defaultQuery = NoteAccountQuery()

        public let id: String
        public var name: String

        public var displayRepresentation: DisplayRepresentation {
            DisplayRepresentation(title: "\(name)")
        }
    }

    /// The query of the account entity: Knot has no accounts, so it finds none.
    public struct NoteAccountQuery: EntityStringQuery {
        public static var allowedExecutionTargets: ExecutionTargets { [.main] }

        public init() {}

        public func entities(for identifiers: [String]) async throws -> [NoteAccountEntity] { [] }
        public func entities(matching string: String) async throws -> [NoteAccountEntity] { [] }
        public func suggestedEntities() async throws -> [NoteAccountEntity] { [] }
    }
#endif
