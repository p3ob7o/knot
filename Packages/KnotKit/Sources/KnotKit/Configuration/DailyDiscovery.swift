import Foundation

public enum DailyDiscoveryResult: Equatable, Sendable {
    case absent(path: VaultRelativePath)
    case found(path: VaultRelativePath, headings: [DiscoveredHeading])
    case tooLarge(path: VaultRelativePath)
    case unreadable(path: VaultRelativePath, message: String)
}

public enum DailyDiscovery {
    public static func discover(
        access: any VaultAccessProvider,
        settings: ValidatedSettings,
        date: Date = Date(),
        locale: Locale = Locale(identifier: "en_US"),
        timeZone: TimeZone = .current,
        explicitLargeFileAnalysis: Bool = false
    ) async -> DailyDiscoveryResult {
        let rendered = settings.compiledDailyPattern.render(date: date, locale: locale, timeZone: timeZone)
        let path: VaultRelativePath
        do {
            let generated = try VaultRelativePath(rendered, kind: .file)
            guard let leaf = generated.lastComponent else { throw PathValidationError.emptyFilename }
            path = try VaultRelativePath(
                components: settings.dailyFolder.components + generated.parent.components + [leaf.hasSuffix(".md") ? leaf : leaf + ".md"],
                kind: .file
            )
        } catch {
            return .unreadable(path: .root, message: error.localizedDescription)
        }
        let lease: VaultAccessLease
        do {
            lease = try await access.acquire()
        } catch {
            return .unreadable(path: path, message: error.localizedDescription)
        }
        defer { lease.close() }
        do {
            return try await Task.detached(priority: .userInitiated) {
                try SafeFileSystem.coordinated(root: lease.rootURL, writing: false) { root in
                    try SafeFileSystem.withRootDescriptor(root: root) { descriptor, _ in
                        let limit = explicitLargeFileAnalysis ? DailyDocument.explicitSizeLimit : DailyDocument.automaticSizeLimit
                        guard let file = try SafeFileSystem.read(rootDescriptor: descriptor, path: path, maximumBytes: limit) else {
                            return .absent(path: path)
                        }
                        return .found(path: path, headings: try DailyDocument(data: file.data, maximumBytes: limit).headings)
                    }
                }
            }.value
        } catch DailyDocumentError.tooLarge {
            return .tooLarge(path: path)
        } catch {
            return .unreadable(path: path, message: error.localizedDescription)
        }
    }

    public static func discover(
        access: any VaultAccessProvider,
        path: VaultRelativePath,
        explicitLargeFileAnalysis: Bool = false
    ) async -> DailyDiscoveryResult {
        let lease: VaultAccessLease
        do {
            lease = try await access.acquire()
        } catch {
            return .unreadable(path: path, message: error.localizedDescription)
        }
        defer { lease.close() }
        do {
            return try await Task.detached(priority: .userInitiated) {
                try SafeFileSystem.coordinated(root: lease.rootURL, writing: false) { root in
                    try SafeFileSystem.withRootDescriptor(root: root) { descriptor, _ in
                        let limit = explicitLargeFileAnalysis ? DailyDocument.explicitSizeLimit : DailyDocument.automaticSizeLimit
                        guard let file = try SafeFileSystem.read(rootDescriptor: descriptor, path: path, maximumBytes: limit) else {
                            return .absent(path: path)
                        }
                        return .found(path: path, headings: try DailyDocument(data: file.data, maximumBytes: limit).headings)
                    }
                }
            }.value
        } catch DailyDocumentError.tooLarge {
            return .tooLarge(path: path)
        } catch {
            return .unreadable(path: path, message: error.localizedDescription)
        }
    }
}
