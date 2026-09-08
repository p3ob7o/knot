import Foundation

public struct ValidatedSettings: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let dailyFolder: VaultRelativePath
    public let inboxFolder: VaultRelativePath
    public let dailyFilenameFormat: String
    public let inboxFilenameFormat: String
    public let dailyTarget: DailyTarget
    public let dailyBulletFormat: String
    public let routingMaxChars: Int
    public let routingRequiresSingleLine: Bool
    public let attachmentFolderPath: String

    public init(
        dailyFolder: String = "Daily",
        inboxFolder: String = "Inbox",
        dailyFilenameFormat: String = "YYYY-MM-DD",
        inboxFilenameFormat: String = "YYYY-MM-DD HHmm",
        dailyTarget: DailyTarget = .heading(
            try! HeadingSelector(title: "Quick notes", level: 2),
            missing: .createAtEnd
        ),
        dailyBulletFormat: String = "- {{HH:mm}} {{content}}",
        routingMaxChars: Int = 280,
        routingRequiresSingleLine: Bool = true,
        attachmentFolderPath: String = ""
    ) throws {
        guard (1...100_000).contains(routingMaxChars) else {
            throw DomainValidationError.invalidRoutingLimit
        }
        _ = try CompiledDatePattern(dailyFilenameFormat)
        _ = try CompiledDatePattern(inboxFilenameFormat)
        _ = try CompiledBulletTemplate(dailyBulletFormat)
        _ = try AttachmentDestination(obsidianValue: attachmentFolderPath)
        self.schemaVersion = Self.schemaVersion
        self.dailyFolder = try VaultRelativePath(dailyFolder, kind: .folder)
        self.inboxFolder = try VaultRelativePath(inboxFolder, kind: .folder)
        self.dailyFilenameFormat = dailyFilenameFormat
        self.inboxFilenameFormat = inboxFilenameFormat
        self.dailyTarget = dailyTarget
        self.dailyBulletFormat = dailyBulletFormat
        self.routingMaxChars = routingMaxChars
        self.routingRequiresSingleLine = routingRequiresSingleLine
        self.attachmentFolderPath = attachmentFolderPath
    }

    public var compiledDailyPattern: CompiledDatePattern {
        try! CompiledDatePattern(dailyFilenameFormat)
    }

    public var compiledInboxPattern: CompiledDatePattern {
        try! CompiledDatePattern(inboxFilenameFormat)
    }

    public var compiledBulletTemplate: CompiledBulletTemplate {
        try! CompiledBulletTemplate(dailyBulletFormat)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, dailyFolder, inboxFolder, dailyFilenameFormat
        case inboxFilenameFormat, dailyTarget, dailyBulletFormat
        case routingMaxChars, routingRequiresSingleLine, attachmentFolderPath
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try values.decode(Int.self, forKey: .schemaVersion)
        guard schema == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported settings schema."
            )
        }
        try self.init(
            dailyFolder: values.decode(VaultRelativePath.self, forKey: .dailyFolder).string,
            inboxFolder: values.decode(VaultRelativePath.self, forKey: .inboxFolder).string,
            dailyFilenameFormat: values.decode(String.self, forKey: .dailyFilenameFormat),
            inboxFilenameFormat: values.decode(String.self, forKey: .inboxFilenameFormat),
            dailyTarget: values.decode(DailyTarget.self, forKey: .dailyTarget),
            dailyBulletFormat: values.decode(String.self, forKey: .dailyBulletFormat),
            routingMaxChars: values.decode(Int.self, forKey: .routingMaxChars),
            routingRequiresSingleLine: values.decode(Bool.self, forKey: .routingRequiresSingleLine),
            attachmentFolderPath: values.decode(String.self, forKey: .attachmentFolderPath)
        )
    }
}

public extension AppSettings {
    func validated() throws -> ValidatedSettings {
        let trimmed = dailyHeading.trimmingCharacters(in: .whitespacesAndNewlines)
        let hashes = trimmed.prefix { $0 == "#" }.count
        let title = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        let selector = try HeadingSelector(
            title: title.isEmpty ? "Quick notes" : title,
            level: (1...6).contains(hashes) ? hashes : 2
        )
        return try ValidatedSettings(
            dailyFolder: dailyFolder,
            inboxFolder: inboxFolder,
            dailyFilenameFormat: dailyFilenameFormat,
            inboxFilenameFormat: inboxFilenameFormat,
            dailyTarget: .heading(selector, missing: .createAtEnd),
            dailyBulletFormat: dailyBulletFormat,
            routingMaxChars: routingMaxChars,
            routingRequiresSingleLine: routingRequiresSingleLine,
            attachmentFolderPath: attachmentFolderPath
        )
    }
}

public extension RoutingPolicy {
    init(settings: ValidatedSettings) {
        self.init(
            maxCharsForDaily: settings.routingMaxChars,
            requireSingleLineForDaily: settings.routingRequiresSingleLine
        )
    }

    func resolve(_ choice: RoutingChoice, content: String) -> NoteMode {
        switch choice {
        case .automatic: decide(for: content)
        case .today: .daily
        case .inbox: .inbox
        }
    }
}
