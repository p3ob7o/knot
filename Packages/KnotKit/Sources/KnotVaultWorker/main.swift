import Foundation
import KnotKit

private struct WorkerResult: Codable {
    let process: String
    let captures: Int
    let notePaths: [String]
    let assetPaths: [String]
}

@main
private struct KnotVaultWorker {
    static func main() async throws {
        let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
        let store = try CaptureStore(directory: options.support)
        let settings = try ValidatedSettings(inboxFolder: "Inbox", attachmentFolderPath: "Media")
        if options.initialize {
            _ = try await store.createProfile(
                id: options.profile,
                displayName: "Two-process fixture",
                bookmark: Data("fixture".utf8),
                settings: settings
            )
            return
        }
        guard try await store.profile(id: options.profile) != nil else {
            throw WorkerError.profileMissing
        }

        let gateway = VaultGateway(
            store: store,
            access: DirectoryVaultAccessProvider(vaultID: options.profile, rootURL: options.vault),
            privateRoot: options.support
        )
        let stager = AssetStager(rootDirectory: options.support, store: store)
        let png = try Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ).unwrap()
        var notes: [String] = []
        var assets: [String] = []

        for index in options.start..<(options.start + options.count) {
            let body = "body-" + String(format: "%03d", index)
            let draft = DraftID()
            try await store.checkpointDraft(try DraftCheckpoint(
                id: draft,
                profileID: options.profile,
                revision: .zero,
                markdown: Data(body.utf8)
            ))
            let asset = try await stager.stage(
                data: png,
                originalName: "same.png",
                declaredMediaType: "image/png",
                draftID: draft
            )
            let markdown = body + "\n\n![fixture](knot-asset://" + asset.id.description + ")"
            try await store.checkpointDraft(try DraftCheckpoint(
                id: draft,
                profileID: options.profile,
                revision: .zero,
                markdown: Data(markdown.utf8)
            ))
            let snapshot = try CaptureSnapshot(
                draftID: draft,
                draftRevision: .zero,
                vaultID: options.profile,
                settingsRevision: .zero,
                settings: settings,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                timeZoneIdentifier: "UTC",
                localeIdentifier: "en_US",
                destination: .inbox(parent: try VaultRelativePath("Inbox"), filenameStem: "same"),
                document: try CaptureDocument(markdown: markdown, assetIDs: [asset.id]),
                assetIDs: [asset.id]
            )
            _ = try await store.enqueue(snapshot)
            let receipt = try await gateway.commit(captureID: snapshot.id)
            notes.append(receipt.notePath.string)
            assets.append(contentsOf: receipt.assetPaths.map(\.string))
        }

        let result = WorkerResult(
            process: options.label,
            captures: options.count,
            notePaths: notes,
            assetPaths: assets
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: options.output, options: .atomic)
    }
}

private struct Options {
    let vault: URL
    let support: URL
    let profile: VaultID
    let label: String
    let start: Int
    let count: Int
    let output: URL
    let initialize: Bool

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var initialize = false
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--initialize" {
                initialize = true
                index += 1
                continue
            }
            guard index + 1 < arguments.count else { throw WorkerError.invalidArguments }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        guard let vault = values["--vault"],
              let support = values["--support"],
              let profileText = values["--profile"],
              let profileUUID = UUID(uuidString: profileText) else {
            throw WorkerError.invalidArguments
        }
        self.vault = URL(fileURLWithPath: vault, isDirectory: true)
        self.support = URL(fileURLWithPath: support, isDirectory: true)
        self.profile = VaultID(rawValue: profileUUID)
        self.label = values["--label"] ?? "initialize"
        self.start = Int(values["--start"] ?? "0") ?? 0
        self.count = Int(values["--count"] ?? "0") ?? 0
        self.output = URL(fileURLWithPath: values["--output"] ?? "/dev/null")
        self.initialize = initialize
        guard initialize || (count > 0 && count <= 100 && !label.isEmpty && values["--output"] != nil) else {
            throw WorkerError.invalidArguments
        }
    }
}

private enum WorkerError: Error, LocalizedError {
    case invalidArguments, profileMissing, invalidFixture

    var errorDescription: String? {
        switch self {
        case .invalidArguments: "Invalid two-process fixture worker arguments."
        case .profileMissing: "The fixture profile was not initialized."
        case .invalidFixture: "The fixture image could not be decoded."
        }
    }
}

private extension Optional where Wrapped == Data {
    func unwrap() throws -> Data {
        guard let self else { throw WorkerError.invalidFixture }
        return self
    }
}
