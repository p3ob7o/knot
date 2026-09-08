import Foundation

public enum RoutingChoice: String, Codable, CaseIterable, Sendable {
    case automatic
    case today
    case inbox
}

public enum MissingHeadingPolicy: String, Codable, CaseIterable, Sendable {
    case createAtEnd
    case ask
}

public struct HeadingSelector: Codable, Hashable, Sendable {
    public let title: String
    public let level: Int
    public let ancestorPath: [String]
    public let occurrence: Int
    public let sampleFingerprint: String?

    public init(
        title: String,
        level: Int,
        ancestorPath: [String] = [],
        occurrence: Int = 0,
        sampleFingerprint: String? = nil
    ) throws {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, (1...6).contains(level), occurrence >= 0 else {
            throw DomainValidationError.invalidHeading
        }
        self.title = cleaned
        self.level = level
        self.ancestorPath = ancestorPath
        self.occurrence = occurrence
        self.sampleFingerprint = sampleFingerprint
    }
}

public enum DailyTarget: Codable, Hashable, Sendable {
    case endOfNote
    case heading(HeadingSelector, missing: MissingHeadingPolicy)
}

public enum CaptureRepresentation: String, Codable, Sendable {
    case markdown
    case blocks
}

public struct CaptureDocument: Codable, Equatable, Sendable {
    public static let maximumMarkdownBytes = 8 * 1_024 * 1_024

    public let markdown: String
    public let representation: CaptureRepresentation
    public let representationVersion: Int
    public let blocksJSON: Data?
    public let opaqueSourcesJSON: Data?

    public init(
        markdown: String,
        representation: CaptureRepresentation = .markdown,
        representationVersion: Int = 1,
        blocksJSON: Data? = nil,
        opaqueSourcesJSON: Data? = nil,
        assetIDs: [AssetID] = []
    ) throws {
        guard markdown.utf8.count <= Self.maximumMarkdownBytes else {
            throw DomainValidationError.documentTooLarge
        }
        let hasText = markdown.unicodeScalars.contains { !$0.properties.isWhitespace }
        guard hasText || !assetIDs.isEmpty else { throw DomainValidationError.blankCapture }
        self.markdown = markdown
        self.representation = representation
        self.representationVersion = representationVersion
        self.blocksJSON = blocksJSON
        self.opaqueSourcesJSON = opaqueSourcesJSON
    }
}

public enum ResolvedDestination: Codable, Equatable, Sendable {
    case today(notePath: VaultRelativePath, target: DailyTarget)
    case inbox(parent: VaultRelativePath, filenameStem: String)
}

public struct CaptureSnapshot: Codable, Equatable, Sendable {
    public let id: CaptureID
    public let draftID: DraftID
    public let draftRevision: Revision
    public let vaultID: VaultID
    public let settingsRevision: Revision
    public let settings: ValidatedSettings
    public let createdAt: Date
    public let timeZoneIdentifier: String
    public let localeIdentifier: String
    public let destination: ResolvedDestination
    public let document: CaptureDocument
    public let assetIDs: [AssetID]

    public init(
        id: CaptureID = CaptureID(),
        draftID: DraftID,
        draftRevision: Revision,
        vaultID: VaultID,
        settingsRevision: Revision,
        settings: ValidatedSettings,
        createdAt: Date,
        timeZoneIdentifier: String,
        localeIdentifier: String,
        destination: ResolvedDestination,
        document: CaptureDocument,
        assetIDs: [AssetID] = []
    ) throws {
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw DomainValidationError.invalidTimeZone
        }
        guard !localeIdentifier.isEmpty else { throw DomainValidationError.invalidLocale }
        self.id = id
        self.draftID = draftID
        self.draftRevision = draftRevision
        self.vaultID = vaultID
        self.settingsRevision = settingsRevision
        self.settings = settings
        self.createdAt = createdAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.localeIdentifier = localeIdentifier
        self.destination = destination
        self.document = document
        self.assetIDs = assetIDs
    }
}

public enum DraftState: String, Codable, CaseIterable, Sendable {
    case active
    case parked
    case captured
    case discarded
}

public enum CaptureState: String, Codable, CaseIterable, Sendable {
    case pending
    case preparing
    case committing
    case committed
    case retryableFailure
    case waitingForVault
    case needsReview
    case cancelled
}
