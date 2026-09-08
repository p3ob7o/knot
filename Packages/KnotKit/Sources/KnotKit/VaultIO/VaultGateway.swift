import Foundation

public enum VaultAccessStatus: String, Codable, Sendable {
    case usable
    case readOnly
    case temporarilyUnavailable
    case missing
    case bookmarkDenied
    case malformedBookmark
    case unconfigured
}

public protocol VaultAccessProvider: Sendable {
    var vaultID: VaultID { get }
    func acquire() async throws -> VaultAccessLease
}

/// A narrow ownership wrapper around platform security-scope lifetimes.
/// The provider's release callback is executed exactly once.
public final class VaultAccessLease: @unchecked Sendable {
    public let rootURL: URL
    private let lock = NSLock()
    private var releaseBody: (@Sendable () -> Void)?

    public init(rootURL: URL, release: @escaping @Sendable () -> Void) {
        self.rootURL = rootURL
        self.releaseBody = release
    }

    public func close() {
        lock.lock()
        let body = releaseBody
        releaseBody = nil
        lock.unlock()
        body?()
    }

    deinit { close() }
}

public struct DirectoryVaultAccessProvider: VaultAccessProvider {
    public let vaultID: VaultID
    public let rootURL: URL

    public init(vaultID: VaultID, rootURL: URL) {
        self.vaultID = vaultID
        self.rootURL = rootURL
    }

    public func acquire() async throws -> VaultAccessLease {
        VaultAccessLease(rootURL: rootURL, release: {})
    }
}

public struct VaultCommitReceipt: Equatable, Sendable {
    public let captureID: CaptureID
    public let notePath: VaultRelativePath
    public let assetPaths: [VaultRelativePath]
}

public actor VaultGateway {
    private struct StagedAsset: Sendable {
        let id: AssetID
        let metadata: AssetMetadata
        let data: Data
    }

    private struct AssetPublication: Sendable {
        let id: AssetID
        let path: VaultRelativePath
        let data: Data
        let hash: String
        let sequence: Int
    }

    private struct PublicationPlan: Sendable {
        let operationID: OperationID
        var notePath: VaultRelativePath
        var noteData: Data
        let existingNote: ExistingFile?
        let assets: [AssetPublication]
        let noteSequence: Int
        let beforeHash: String?
        let beforeData: Data?

        var records: [MutationRecord] {
            assets.map {
                MutationRecord(
                    operationID: operationID,
                    sequence: $0.sequence,
                    captureID: captureID,
                    kind: .asset,
                    relativeTarget: $0.path,
                    beforeHash: nil,
                    afterHash: $0.hash,
                    beforeBlob: nil,
                    afterBlob: $0.data
                )
            } + [
                MutationRecord(
                    operationID: operationID,
                    sequence: noteSequence,
                    captureID: captureID,
                    kind: .note,
                    relativeTarget: notePath,
                    beforeHash: beforeHash,
                    afterHash: SafeFileSystem.hash(noteData),
                    beforeBlob: beforeData,
                    afterBlob: noteData
                )
            ]
        }

        let captureID: CaptureID
    }

    private let store: CaptureStore
    private let access: any VaultAccessProvider
    private let privateRoot: URL
    private var expectedRootIdentity: FileIdentity?

    public init(
        store: CaptureStore,
        access: any VaultAccessProvider,
        privateRoot: URL
    ) {
        self.store = store
        self.access = access
        self.privateRoot = privateRoot
    }

    public func inspect() async -> VaultAccessStatus {
        do {
            let lease = try await access.acquire()
            defer { lease.close() }
            expectedRootIdentity = try SafeFileSystem.rootIdentity(lease.rootURL)
            return .usable
        } catch VaultIOError.readOnly {
            return .readOnly
        } catch VaultIOError.temporarilyUnavailable {
            return .temporarilyUnavailable
        } catch VaultIOError.missing {
            return .missing
        } catch VaultIOError.denied {
            return .bookmarkDenied
        } catch {
            return .malformedBookmark
        }
    }

    public func commit(captureID: CaptureID) async throws -> VaultCommitReceipt {
        guard var capture = try await store.capture(id: captureID) else {
            throw CaptureStoreError.captureMissing
        }
        switch capture.state {
        case .pending, .retryableFailure, .waitingForVault:
            try await store.transition(captureID: captureID, to: .preparing)
            capture = try await store.capture(id: captureID) ?? capture
        case .preparing:
            break
        case .committing:
            return try await reconcile(captureID: captureID)
        case .committed:
            guard let receipt = try await store.receipt(captureID: captureID) else {
                throw CaptureStoreError.corruptRecord
            }
            return VaultCommitReceipt(captureID: captureID, notePath: receipt.noteRelativePath, assetPaths: [])
        case .needsReview, .cancelled:
            throw CaptureStoreError.illegalTransition(from: capture.state, to: .preparing)
        }

        let stagedAssets = try await loadAssets(capture.snapshot.assetIDs)
        let lease: VaultAccessLease
        do {
            lease = try await access.acquire()
        } catch {
            try? await store.transition(captureID: captureID, to: .waitingForVault, errorCode: "vaultAccess")
            throw error
        }
        defer { lease.close() }

        do {
            let identity = try SafeFileSystem.rootIdentity(lease.rootURL)
            if let expectedRootIdentity, expectedRootIdentity != identity {
                throw VaultIOError.unsafeRoot
            }
            expectedRootIdentity = identity
            var plan = try prepare(
                capture: capture,
                assets: stagedAssets,
                root: lease.rootURL,
                rootIdentity: identity
            )
            try await store.recordMutationPlan(plan.records)
            try await store.transition(captureID: captureID, to: .committing)

            var publishedAssets: [(AssetPublication, FileIdentity)] = []
            for asset in plan.assets {
                let published = try SafeFileSystem.coordinated(root: lease.rootURL, writing: true) { accessor in
                    try SafeFileSystem.withRootDescriptor(root: accessor, expectedIdentity: identity) { descriptor, _ in
                        try SafeFileSystem.publishNew(
                            rootDescriptor: descriptor,
                            path: asset.path,
                            data: asset.data,
                            operationID: plan.operationID,
                            sequence: asset.sequence
                        )
                    }
                }
                publishedAssets.append((asset, published))
            }

            var counter = 0
            var noteIdentity: FileIdentity
            while true {
                do {
                    noteIdentity = try SafeFileSystem.coordinated(root: lease.rootURL, writing: true) { accessor in
                        try SafeFileSystem.withRootDescriptor(root: accessor, expectedIdentity: identity) { descriptor, _ in
                            if let existing = plan.existingNote {
                                return try SafeFileSystem.replace(
                                    rootDescriptor: descriptor,
                                    path: plan.notePath,
                                    data: plan.noteData,
                                    expected: existing,
                                    operationID: plan.operationID,
                                    sequence: plan.noteSequence
                                )
                            }
                            return try SafeFileSystem.publishNew(
                                rootDescriptor: descriptor,
                                path: plan.notePath,
                                data: plan.noteData,
                                operationID: plan.operationID,
                                sequence: plan.noteSequence
                            )
                        }
                    }
                    break
                } catch VaultIOError.collision {
                    guard case .inbox = capture.snapshot.destination, counter < 999 else { throw VaultIOError.collision }
                    counter += 1
                    plan.notePath = try collisionPath(from: plan.notePath, counter: counter)
                    try await store.recordMutationPlan(plan.records)
                }
            }

            for (asset, published) in publishedAssets {
                try await store.markMutation(
                    operationID: plan.operationID,
                    sequence: asset.sequence,
                    phase: .published,
                    publishedResourceID: try JSONEncoder().encode(published)
                )
            }
            try await store.markMutation(
                operationID: plan.operationID,
                sequence: plan.noteSequence,
                phase: .published,
                publishedResourceID: try JSONEncoder().encode(noteIdentity)
            )
            let receipt = CaptureReceipt(
                captureID: captureID,
                noteRelativePath: plan.notePath,
                noteHashAtCommit: SafeFileSystem.hash(plan.noteData),
                assetResultsJSON: try JSONEncoder().encode(plan.assets.map(\.path))
            )
            try await store.storeReceipt(receipt)
            return VaultCommitReceipt(
                captureID: captureID,
                notePath: plan.notePath,
                assetPaths: plan.assets.map(\.path)
            )
        } catch {
            let records = (try? await store.mutations(captureID: captureID)) ?? []
            let currentState = try? await store.capture(id: captureID)?.state
            let uncertain = records.contains { $0.phase != .planned } || currentState == .committing
            if uncertain {
                try? await store.transition(captureID: captureID, to: .needsReview, errorCode: "outcomeUncertain")
            } else if Self.isRetryable(error) {
                let attempt = (try? await store.capture(id: captureID)?.attemptCount) ?? 1
                let next = CaptureRetrySchedule.nextAttemptDate(
                    afterAttempt: attempt, captureID: captureID, now: Date()
                )
                try? await store.transition(
                    captureID: captureID, to: .retryableFailure,
                    errorCode: Self.errorCode(error), nextAttemptAt: next
                )
            } else {
                try? await store.transition(captureID: captureID, to: .needsReview, errorCode: Self.errorCode(error))
            }
            throw error
        }
    }

    public func reconcile(captureID: CaptureID) async throws -> VaultCommitReceipt {
        guard try await store.capture(id: captureID) != nil else {
            throw CaptureStoreError.captureMissing
        }
        let records = try await store.mutations(captureID: captureID)
        guard !records.isEmpty else {
            try? await store.transition(captureID: captureID, to: .needsReview, errorCode: "journalMissing")
            throw CaptureStoreError.corruptRecord
        }
        let lease = try await access.acquire()
        defer { lease.close() }
        let identity = try SafeFileSystem.rootIdentity(lease.rootURL)
        var allAfter = true
        var allKnown = true
        for record in records {
            let existing = try SafeFileSystem.coordinated(root: lease.rootURL, writing: false) { accessor in
                try SafeFileSystem.withRootDescriptor(root: accessor, expectedIdentity: identity) { descriptor, _ in
                    try SafeFileSystem.read(
                        rootDescriptor: descriptor,
                        path: record.relativeTarget,
                        maximumBytes: max(record.afterBlob.count * 2, DailyDocument.explicitSizeLimit)
                    )
                }
            }
            let currentHash = existing.map { SafeFileSystem.hash($0.data) }
            if currentHash == record.afterHash {
                try await store.markMutation(
                    operationID: record.operationID,
                    sequence: record.sequence,
                    phase: .published,
                    publishedResourceID: existing.flatMap { try? JSONEncoder().encode($0.identity) }
                )
            } else {
                allAfter = false
                let knownBefore = (record.beforeHash == nil && existing == nil) || currentHash == record.beforeHash
                if !knownBefore { allKnown = false }
            }
        }

        guard let note = records.last(where: { $0.kind == .note }) else {
            throw CaptureStoreError.corruptRecord
        }
        if allAfter {
            try await store.storeReceipt(CaptureReceipt(
                captureID: captureID,
                noteRelativePath: note.relativeTarget,
                noteHashAtCommit: note.afterHash
            ))
            return VaultCommitReceipt(
                captureID: captureID,
                notePath: note.relativeTarget,
                assetPaths: records.filter { $0.kind == .asset }.map(\.relativeTarget)
            )
        }
        if allKnown {
            try? await store.transition(captureID: captureID, to: .retryableFailure, errorCode: "reconciledBefore")
        } else {
            try? await store.transition(captureID: captureID, to: .needsReview, errorCode: "externalModification")
        }
        throw VaultIOError.concurrentModification
    }

    private func prepare(
        capture: StoredCapture,
        assets: [StagedAsset],
        root: URL,
        rootIdentity: FileIdentity
    ) throws -> PublicationPlan {
        try SafeFileSystem.coordinated(root: root, writing: false) { accessor in
            try SafeFileSystem.withRootDescriptor(root: accessor, expectedIdentity: rootIdentity) { descriptor, _ in
                let operationID = OperationID()
                var notePath: VaultRelativePath
                var noteData: Data
                var existingNote: ExistingFile?

                switch capture.snapshot.destination {
                case .today(let path, let target):
                    notePath = path
                    existingNote = try SafeFileSystem.read(
                        rootDescriptor: descriptor,
                        path: path,
                        maximumBytes: DailyDocument.explicitSizeLimit
                    )
                    let document = try DailyDocument(
                        data: existingNote?.data ?? Data(),
                        maximumBytes: DailyDocument.explicitSizeLimit
                    )
                    let timeZone = TimeZone(identifier: capture.snapshot.timeZoneIdentifier) ?? .gmt
                    let locale = Locale(identifier: capture.snapshot.localeIdentifier)
                    let bullet = capture.snapshot.settings.compiledBulletTemplate.render(
                        content: capture.snapshot.document.markdown,
                        date: capture.snapshot.createdAt,
                        locale: locale,
                        timeZone: timeZone,
                        lineSeparator: document.newline
                    )
                    noteData = try document.inserting(bullet, target: target)

                case .inbox(let parent, let filenameStem):
                    let safeStem = try SafeFilename.stem(from: filenameStem)
                    notePath = try parent.appending(component: safeStem + ".md", kind: .file)
                    var counter = 0
                    while try SafeFileSystem.read(
                        rootDescriptor: descriptor,
                        path: notePath,
                        maximumBytes: CaptureDocument.maximumMarkdownBytes
                    ) != nil {
                        counter += 1
                        notePath = try collisionPath(from: notePath, counter: counter)
                    }
                    existingNote = nil
                    noteData = Data(capture.snapshot.document.markdown.utf8)
                }

                var assetPlans: [AssetPublication] = []
                for (index, asset) in assets.enumerated() {
                    let path = try assetPath(
                        metadata: asset.metadata,
                        assetID: asset.id,
                        notePath: notePath,
                        setting: capture.snapshot.settings.attachmentFolderPath
                    )
                    assetPlans.append(AssetPublication(
                        id: asset.id,
                        path: path,
                        data: asset.data,
                        hash: asset.metadata.sha256,
                        sequence: index
                    ))
                }
                if let markdown = String(data: noteData, encoding: .utf8) {
                    let destinations = Dictionary(uniqueKeysWithValues: assetPlans.map {
                        (
                            "knot-asset://\($0.id.description)",
                            markdownPath(from: notePath.parent, to: $0.path)
                        )
                    })
                    noteData = Data(AssetReferenceRewriter.rewrite(
                        markdown,
                        destinations: destinations
                    ).utf8)
                }
                return PublicationPlan(
                    operationID: operationID,
                    notePath: notePath,
                    noteData: noteData,
                    existingNote: existingNote,
                    assets: assetPlans,
                    noteSequence: assetPlans.count,
                    beforeHash: existingNote.map { SafeFileSystem.hash($0.data) },
                    beforeData: existingNote?.data,
                    captureID: capture.snapshot.id
                )
            }
        }
    }

    private func loadAssets(_ ids: [AssetID]) async throws -> [StagedAsset] {
        var result: [StagedAsset] = []
        result.reserveCapacity(ids.count)
        for id in ids {
            guard let metadata = try await store.asset(id: id) else {
                throw CaptureStoreError.assetMissing
            }
            let url = privateRoot.appending(path: metadata.localRelativePath)
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count == metadata.byteCount,
                  AssetStager.sha256(data) == metadata.sha256 else {
                throw CaptureStoreError.assetMissing
            }
            result.append(StagedAsset(id: id, metadata: metadata, data: data))
        }
        return result
    }

    private func assetPath(
        metadata: AssetMetadata,
        assetID: AssetID,
        notePath: VaultRelativePath,
        setting: String
    ) throws -> VaultRelativePath {
        let destination = try AttachmentDestination(obsidianValue: setting)
        let original = metadata.originalName as NSString
        let ext = original.pathExtension.isEmpty ? extensionForMediaType(metadata.mediaType) : original.pathExtension
        let stem = try SafeFilename.stem(from: original.deletingPathExtension)
        let uniqueStem = stem + "-" + assetID.description.prefix(8)
        let filename = uniqueStem + (ext.isEmpty ? "" : "." + ext.lowercased())
        let parent: VaultRelativePath
        switch destination {
        case .vaultRoot:
            parent = .root
        case .vaultRelative(let folder):
            parent = folder
        case .besideNote:
            parent = notePath.parent
        case .besideNoteSubfolder(let folder):
            parent = try VaultRelativePath(components: notePath.parent.components + folder.components)
        }
        return try parent.appending(component: filename, kind: .file)
    }

    private func collisionPath(from path: VaultRelativePath, counter: Int) throws -> VaultRelativePath {
        guard let filename = path.lastComponent else { throw PathValidationError.emptyFilename }
        let value = filename as NSString
        let ext = value.pathExtension
        let stem = value.deletingPathExtension.replacingOccurrences(
            of: #" \([0-9]+\)$"#,
            with: "",
            options: .regularExpression
        )
        let candidate = stem + " (\(counter))" + (ext.isEmpty ? "" : "." + ext)
        return try path.parent.appending(component: candidate, kind: .file)
    }

    private func markdownPath(from parent: VaultRelativePath, to target: VaultRelativePath) -> String {
        var common = 0
        while common < parent.components.count,
              common < target.components.count,
              parent.components[common] == target.components[common] {
            common += 1
        }
        let upwards = Array(repeating: "..", count: parent.components.count - common)
        let downwards = Array(target.components.dropFirst(common))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return (upwards + downwards).map {
            $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0
        }.joined(separator: "/")
    }

    private func extensionForMediaType(_ mediaType: String) -> String {
        switch mediaType {
        case "image/png": "png"
        case "image/jpeg": "jpg"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "image/heic": "heic"
        default: ""
        }
    }

    private static func isRetryable(_ error: any Error) -> Bool {
        guard let value = error as? VaultIOError else { return false }
        switch value {
        case .temporarilyUnavailable:
            return true
        case .ioFailure(let code):
            return [EAGAIN, EBUSY, ETIMEDOUT, ENOSPC, EIO].contains(code)
        default:
            return false
        }
    }

    private static func errorCode(_ error: any Error) -> String {
        if let value = error as? VaultIOError {
            return String(describing: value)
        }
        if let value = error as? DailyDocumentError {
            return String(describing: value)
        }
        return "unknown"
    }
}
