import Foundation

public enum ImportEnablement: String, Codable, Equatable, Sendable {
    case enabled
    case disabled
    case unknown
}

public enum ImportFileState: String, Codable, Equatable, Sendable {
    case loaded
    case absent
    case malformed
    case oversized
    case unavailable
}

public struct ImportDiagnostic: Codable, Equatable, Sendable {
    public let file: String
    public let state: ImportFileState

    public init(file: String, state: ImportFileState) {
        self.file = file
        self.state = state
    }
}

public struct ImportedDailyProposal: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Equatable, Sendable {
        case periodicNotes = "obsidian.periodic-notes"
        case coreDailyNotes = "obsidian.daily-notes"
    }

    public let folder: String
    public let filenameFormat: String
    public let templatePath: String?
    public let source: Source
    public let enablement: ImportEnablement
    public let validationErrors: [String]

    public var automaticAdoptionAllowed: Bool {
        enablement == .enabled && validationErrors.isEmpty
    }
}

public struct ImportedAttachmentProposal: Codable, Equatable, Sendable {
    public let value: String
    public let validationErrors: [String]
}

public struct ImportedVaultConfiguration: Codable, Equatable, Sendable {
    public let daily: ImportedDailyProposal?
    public let attachment: ImportedAttachmentProposal?
    public let diagnostics: [ImportDiagnostic]

    public init(
        daily: ImportedDailyProposal?,
        attachment: ImportedAttachmentProposal?,
        diagnostics: [ImportDiagnostic] = []
    ) {
        self.daily = daily
        self.attachment = attachment
        self.diagnostics = diagnostics
    }
}

public enum ObsidianConfigurationReader {
    public static let maximumJSONBytes = 1_048_576

    private struct PeriodicFile: Decodable {
        let daily: Daily?
        struct Daily: Decodable {
            let enabled: Bool?
            let folder: String?
            let format: String?
            let template: String?
        }
    }

    private struct CoreFile: Decodable {
        let folder: String?
        let format: String?
        let template: String?
    }

    private struct AppFile: Decodable {
        let attachmentFolderPath: String?
    }

    private enum ReadResult {
        case data(Data)
        case failure(ImportFileState)
    }

    public static func read(access: any VaultAccessProvider) async -> ImportedVaultConfiguration {
        let lease: VaultAccessLease
        do {
            lease = try await access.acquire()
        } catch {
            return ImportedVaultConfiguration(
                daily: nil,
                attachment: nil,
                diagnostics: [ImportDiagnostic(file: ".obsidian", state: .unavailable)]
            )
        }
        defer { lease.close() }

        do {
            return try SafeFileSystem.coordinated(root: lease.rootURL, writing: false) { root in
                try SafeFileSystem.withRootDescriptor(root: root) { descriptor, _ in
                    read(rootDescriptor: descriptor)
                }
            }
        } catch {
            return ImportedVaultConfiguration(
                daily: nil,
                attachment: nil,
                diagnostics: [ImportDiagnostic(file: ".obsidian", state: .unavailable)]
            )
        }
    }

    static func read(rootDescriptor: Int32) -> ImportedVaultConfiguration {
        var diagnostics: [ImportDiagnostic] = []
        let community = readJSON(rootDescriptor, ".obsidian/community-plugins.json", diagnostics: &diagnostics)
        let periodic = readJSON(rootDescriptor, ".obsidian/plugins/periodic-notes/data.json", diagnostics: &diagnostics)
        let corePlugins = readJSON(rootDescriptor, ".obsidian/core-plugins.json", diagnostics: &diagnostics)
        let coreDaily = readJSON(rootDescriptor, ".obsidian/daily-notes.json", diagnostics: &diagnostics)
        let app = readJSON(rootDescriptor, ".obsidian/app.json", diagnostics: &diagnostics)

        let communityIDs = decode([String].self, from: community, file: ".obsidian/community-plugins.json", diagnostics: &diagnostics)
        let periodicFile = decode(PeriodicFile.self, from: periodic, file: ".obsidian/plugins/periodic-notes/data.json", diagnostics: &diagnostics)
        let coreIDs = decode([String].self, from: corePlugins, file: ".obsidian/core-plugins.json", diagnostics: &diagnostics)
        let coreFile = decode(CoreFile.self, from: coreDaily, file: ".obsidian/daily-notes.json", diagnostics: &diagnostics)
        let appFile = decode(AppFile.self, from: app, file: ".obsidian/app.json", diagnostics: &diagnostics)

        let daily: ImportedDailyProposal?
        if communityIDs?.contains("periodic-notes") == true,
           let periodicDaily = periodicFile?.daily,
           periodicDaily.enabled == true,
           let format = periodicDaily.format,
           !format.isEmpty {
            daily = makeDaily(
                folder: periodicDaily.folder ?? "",
                format: format,
                template: periodicDaily.template,
                source: .periodicNotes,
                enablement: .enabled
            )
        } else if let coreFile {
            let enablement: ImportEnablement
            if let coreIDs {
                enablement = coreIDs.contains("daily-notes") ? .enabled : .disabled
            } else {
                enablement = .unknown
            }
            daily = makeDaily(
                folder: coreFile.folder ?? "",
                format: coreFile.format.flatMap { $0.isEmpty ? nil : $0 } ?? "YYYY-MM-DD",
                template: coreFile.template,
                source: .coreDailyNotes,
                enablement: enablement
            )
        } else {
            daily = nil
        }

        let attachment = appFile?.attachmentFolderPath.map { raw -> ImportedAttachmentProposal in
            let value = normalizeAttachment(raw)
            let errors = validationErrors { _ = try AttachmentDestination(obsidianValue: value) }
            return ImportedAttachmentProposal(value: value, validationErrors: errors)
        }
        return ImportedVaultConfiguration(daily: daily, attachment: attachment, diagnostics: diagnostics)
    }

    private static func makeDaily(
        folder: String,
        format: String,
        template: String?,
        source: ImportedDailyProposal.Source,
        enablement: ImportEnablement
    ) -> ImportedDailyProposal {
        var errors = validationErrors {
            _ = try VaultRelativePath(folder, kind: .folder)
            _ = try CompiledDatePattern(format)
        }
        let templateValue = template?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let templateValue, !templateValue.isEmpty {
            errors += validationErrors { _ = try VaultRelativePath(templateValue, kind: .file) }
        }
        return ImportedDailyProposal(
            folder: folder,
            filenameFormat: format,
            templatePath: templateValue.flatMap { $0.isEmpty ? nil : $0 },
            source: source,
            enablement: enablement,
            validationErrors: errors
        )
    }

    private static func readJSON(
        _ rootDescriptor: Int32,
        _ rawPath: String,
        diagnostics: inout [ImportDiagnostic]
    ) -> ReadResult {
        do {
            let path = try VaultRelativePath(rawPath, kind: .file)
            guard let file = try SafeFileSystem.read(
                rootDescriptor: rootDescriptor,
                path: path,
                maximumBytes: maximumJSONBytes
            ) else {
                diagnostics.append(.init(file: rawPath, state: .absent))
                return .failure(.absent)
            }
            diagnostics.append(.init(file: rawPath, state: .loaded))
            return .data(file.data)
        } catch DailyDocumentError.tooLarge {
            diagnostics.append(.init(file: rawPath, state: .oversized))
            return .failure(.oversized)
        } catch {
            diagnostics.append(.init(file: rawPath, state: .unavailable))
            return .failure(.unavailable)
        }
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from result: ReadResult,
        file: String,
        diagnostics: inout [ImportDiagnostic]
    ) -> T? {
        guard case .data(let data) = result else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            if let index = diagnostics.lastIndex(where: { $0.file == file }) {
                diagnostics[index] = ImportDiagnostic(file: file, state: .malformed)
            }
            return nil
        }
    }

    private static func validationErrors(_ body: () throws -> Void) -> [String] {
        do {
            try body()
            return []
        } catch {
            return [String(describing: error)]
        }
    }

    private static func normalizeAttachment(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "/" ? "" : trimmed
    }
}
