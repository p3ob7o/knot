import Darwin
import Foundation

public struct DirectoryIdentity: Codable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public struct FolderEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String { path.string }
    public let name: String
    public let path: VaultRelativePath
    public let identity: DirectoryIdentity
}

public struct FolderListing: Codable, Equatable, Sendable {
    public let path: VaultRelativePath
    public let identity: DirectoryIdentity
    public let children: [FolderEntry]

    public init(path: VaultRelativePath, identity: DirectoryIdentity, children: [FolderEntry]) {
        self.path = path
        self.identity = identity
        self.children = children
    }
}

public enum FolderListingFailure: Error, Codable, Equatable, Sendable {
    case denied
    case unavailable
    case missing
    case unsafePath
}

public protocol FolderListingProvider: Sendable {
    var vaultID: VaultID { get }
    func list(path: VaultRelativePath) async throws -> FolderListing
}

public struct DescriptorFolderListingProvider: FolderListingProvider {
    public let vaultID: VaultID
    private let access: any VaultAccessProvider

    public init(access: any VaultAccessProvider) {
        vaultID = access.vaultID
        self.access = access
    }

    public func list(path: VaultRelativePath) async throws -> FolderListing {
        let lease: VaultAccessLease
        do {
            lease = try await access.acquire()
        } catch VaultIOError.denied {
            throw FolderListingFailure.denied
        } catch {
            throw FolderListingFailure.unavailable
        }
        defer { lease.close() }
        do {
            return try await Task.detached(priority: .userInitiated) {
                try SafeFileSystem.coordinated(root: lease.rootURL, writing: false) { root in
                    try SafeFileSystem.withRootDescriptor(root: root) { descriptor, _ in
                        try listDirectories(rootDescriptor: descriptor, path: path)
                    }
                }
            }.value
        } catch VaultIOError.denied {
            throw FolderListingFailure.denied
        } catch VaultIOError.missing {
            throw FolderListingFailure.missing
        } catch VaultIOError.temporarilyUnavailable {
            throw FolderListingFailure.unavailable
        } catch {
            throw FolderListingFailure.unsafePath
        }
    }
}

public struct FolderSuggestions: Equatable, Sendable {
    public let parent: VaultRelativePath
    public let prefix: String
    public let exactMatch: FolderEntry?
    public let matches: [FolderEntry]
}

public actor VaultBrowser {
    private struct CacheKey: Hashable {
        let vaultID: VaultID
        let generation: Int
        let identity: DirectoryIdentity
    }

    private struct Cached {
        let listing: FolderListing
        let expiresAt: Date
        let touchedAt: Date
    }

    private let provider: any FolderListingProvider
    private let ttl: TimeInterval
    private let capacity: Int
    private var generation: Int
    private var latestRequestID: UUID?
    private var identitiesByPath: [VaultRelativePath: DirectoryIdentity] = [:]
    private var cache: [CacheKey: Cached] = [:]

    public init(
        provider: any FolderListingProvider,
        generation: Int = 0,
        cacheCapacity: Int = 32,
        cacheTTL: TimeInterval = 300
    ) {
        self.provider = provider
        self.generation = generation
        capacity = max(1, cacheCapacity)
        ttl = max(0, cacheTTL)
    }

    public func beginGeneration(_ value: Int) throws {
        guard value >= generation else { throw ConfigurationError.invalidGeneration }
        generation = value
        latestRequestID = nil
        identitiesByPath.removeAll()
        cache.removeAll()
    }

    public func load(
        path: VaultRelativePath,
        generation requestedGeneration: Int,
        requestID: UUID,
        now: Date = Date()
    ) async throws -> FolderListing {
        guard requestedGeneration == generation else { throw ConfigurationError.staleResult }
        latestRequestID = requestID
        if let identity = identitiesByPath[path],
           let cached = cache[CacheKey(vaultID: provider.vaultID, generation: generation, identity: identity)],
           cached.expiresAt > now {
            return cached.listing
        }

        let listing = try await provider.list(path: path)
        guard requestedGeneration == generation, latestRequestID == requestID else {
            throw ConfigurationError.staleResult
        }
        identitiesByPath[path] = listing.identity
        let key = CacheKey(vaultID: provider.vaultID, generation: generation, identity: listing.identity)
        cache[key] = Cached(listing: listing, expiresAt: now.addingTimeInterval(ttl), touchedAt: now)
        trimCache()
        return listing
    }

    public func suggestions(
        typedPath: String,
        generation: Int,
        requestID: UUID,
        now: Date = Date()
    ) async throws -> FolderSuggestions {
        let components = typedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let prefix = components.last ?? ""
        let parentComponents = Array(components.dropLast())
        let parent = try VaultRelativePath(components: parentComponents, kind: .folder)
        let listing = try await load(path: parent, generation: generation, requestID: requestID, now: now)
        let options = listing.children.filter {
            prefix.isEmpty || $0.name.range(
                of: prefix,
                options: [.caseInsensitive, .diacriticInsensitive, .anchored],
                locale: .current
            ) != nil
        }
        let exact = listing.children.first {
            $0.name.compare(prefix, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == .orderedSame
        }
        return FolderSuggestions(parent: parent, prefix: prefix, exactMatch: exact, matches: options)
    }

    public func cachedListingCount() -> Int { cache.count }

    private func trimCache() {
        guard cache.count > capacity else { return }
        for key in cache.sorted(by: { $0.value.touchedAt < $1.value.touchedAt }).prefix(cache.count - capacity).map(\.key) {
            cache.removeValue(forKey: key)
        }
    }
}

private func listDirectories(rootDescriptor: Int32, path: VaultRelativePath) throws -> FolderListing {
    let descriptor = try SafeFileSystem.openDirectory(
        rootDescriptor: rootDescriptor,
        components: path.components,
        create: false
    )
    defer { Darwin.close(descriptor) }
    var directoryStatus = stat()
    guard fstat(descriptor, &directoryStatus) == 0 else { throw VaultIOError.ioFailure(errno) }
    let identity = DirectoryIdentity(device: UInt64(directoryStatus.st_dev), inode: UInt64(directoryStatus.st_ino))

    let iteratorDescriptor = dup(descriptor)
    guard iteratorDescriptor >= 0, let directory = fdopendir(iteratorDescriptor) else {
        if iteratorDescriptor >= 0 { Darwin.close(iteratorDescriptor) }
        throw VaultIOError.ioFailure(errno)
    }
    defer { closedir(directory) }

    var children: [FolderEntry] = []
    while let entry = readdir(directory) {
        let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                String(cString: $0)
            }
        }
        guard name != ".", name != "..", !name.hasPrefix("."), !isPackage(name) else { continue }
        var childStatus = stat()
        let result = name.withCString { fstatat(descriptor, $0, &childStatus, AT_SYMLINK_NOFOLLOW) }
        guard result == 0,
              (childStatus.st_mode & S_IFMT) == S_IFDIR,
              (childStatus.st_flags & UInt32(UF_HIDDEN)) == 0 else { continue }
        let childPath = try path.appending(component: name, kind: .folder)
        children.append(FolderEntry(
            name: name,
            path: childPath,
            identity: DirectoryIdentity(device: UInt64(childStatus.st_dev), inode: UInt64(childStatus.st_ino))
        ))
    }
    children.sort {
        let comparison = $0.name.localizedStandardCompare($1.name)
        return comparison == .orderedSame ? $0.path.string < $1.path.string : comparison == .orderedAscending
    }
    return FolderListing(path: path, identity: identity, children: children)
}

private func isPackage(_ name: String) -> Bool {
    let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "kext", "pkg", "playground", "rtfd",
        "xcassets", "xcodeproj", "xcworkspace"
    ]
    return packageExtensions.contains((name as NSString).pathExtension.lowercased())
}
