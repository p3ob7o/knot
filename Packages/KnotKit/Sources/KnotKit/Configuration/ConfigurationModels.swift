import Foundation

public enum OnboardingStep: String, Codable, CaseIterable, Sendable {
    case vault
    case inbox
    case dailyFolder
    case heading
    case summary
}

public struct FolderBrowserState: Codable, Equatable, Sendable {
    public var browserPath: VaultRelativePath
    public var selectedPath: VaultRelativePath?
    public var query: String
    public var highlightedPath: VaultRelativePath?

    public init(
        browserPath: VaultRelativePath = .root,
        selectedPath: VaultRelativePath? = nil,
        query: String = "",
        highlightedPath: VaultRelativePath? = nil
    ) {
        self.browserPath = browserPath
        self.selectedPath = selectedPath
        self.query = query
        self.highlightedPath = highlightedPath
    }
}

public struct OnboardingSession: Codable, Equatable, Sendable {
    public let id: OnboardingSessionID
    public var profileID: VaultID?
    public var generation: Int
    public var step: OnboardingStep
    public var workingSettings: ValidatedSettings
    public var proposedBookmark: Data?
    public var importDiff: ConfigDiff?
    public var browserState: FolderBrowserState
    public var folderCreationIntents: [VaultRelativePath]
    public var dailyTemplatePath: VaultRelativePath?
    public var updatedAt: Date

    public init(
        id: OnboardingSessionID = OnboardingSessionID(),
        profileID: VaultID? = nil,
        generation: Int = 0,
        step: OnboardingStep = .vault,
        workingSettings: ValidatedSettings,
        proposedBookmark: Data? = nil,
        importDiff: ConfigDiff? = nil,
        browserState: FolderBrowserState = FolderBrowserState(),
        folderCreationIntents: [VaultRelativePath] = [],
        dailyTemplatePath: VaultRelativePath? = nil,
        updatedAt: Date = Date()
    ) throws {
        guard generation >= 0 else { throw ConfigurationError.invalidGeneration }
        self.id = id
        self.profileID = profileID
        self.generation = generation
        self.step = step
        self.workingSettings = workingSettings
        self.proposedBookmark = proposedBookmark
        self.importDiff = importDiff
        self.browserState = browserState
        self.folderCreationIntents = folderCreationIntents
        self.dailyTemplatePath = dailyTemplatePath
        self.updatedAt = updatedAt
    }
}

public enum ConfigurationField: String, Codable, CaseIterable, Sendable {
    case dailyFolder
    case inboxFolder
    case dailyFilenameFormat
    case inboxFilenameFormat
    case dailyTarget
    case dailyBulletFormat
    case routingMaxChars
    case routingRequiresSingleLine
    case attachmentFolderPath
}

public struct ConfigDiffEntry: Codable, Equatable, Sendable {
    public let field: ConfigurationField
    public let source: String
    public let oldValue: String
    public let proposedValue: String

    public init(field: ConfigurationField, source: String, oldValue: String, proposedValue: String) {
        self.field = field
        self.source = source
        self.oldValue = oldValue
        self.proposedValue = proposedValue
    }
}

public struct ConfigDiff: Codable, Equatable, Sendable {
    public let vaultID: VaultID?
    public let baseRevision: Revision
    public let entries: [ConfigDiffEntry]

    public init(vaultID: VaultID?, baseRevision: Revision, entries: [ConfigDiffEntry]) {
        self.vaultID = vaultID
        self.baseRevision = baseRevision
        self.entries = entries
    }
}

public struct SettingsWorkingCopy: Equatable, Sendable {
    public let profileID: VaultID
    public let baseRevision: Revision
    public var value: ValidatedSettings

    public init(profile: VaultProfileRecord) {
        profileID = profile.id
        baseRevision = profile.settingsRevision
        value = profile.settings
    }
}

public enum ConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case invalidGeneration
    case staleResult
    case sessionMissing
    case incompleteSession
    case revisionConflict(current: Revision)
    case invalidImport(field: ConfigurationField, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidGeneration: "The setup generation is invalid."
        case .staleResult: "This setup result belongs to an older vault selection."
        case .sessionMissing: "The setup session could not be found."
        case .incompleteSession: "Setup is not ready to finish."
        case .revisionConflict: "Settings changed in another window."
        case .invalidImport(let field, _): "The imported \(field.rawValue) value is invalid."
        }
    }
}
