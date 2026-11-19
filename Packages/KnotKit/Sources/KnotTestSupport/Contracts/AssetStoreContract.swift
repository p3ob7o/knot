import CryptoKit
import Foundation
import KnotCore
import Testing

/// What an `AssetStore` under test was made with: the locations its files go to, and a
/// folder where a test may write a file to move in.
public struct AssetStoreSubject: Sendable {
    public let store: any AssetStore
    public let locations: StoreLocations
    /// Writes `data` to a scratch file outside the store, for `move`.
    public let writeScratch: @Sendable (Data) throws -> URL
    /// Whether a file exists, read without the store.
    public let exists: @Sendable (URL) -> Bool

    public init(
        store: any AssetStore, locations: StoreLocations, writeScratch: @escaping @Sendable (Data) throws -> URL,
        exists: @escaping @Sendable (URL) -> Bool
    ) {
        self.store = store
        self.locations = locations
        self.writeScratch = writeScratch
        self.exists = exists
    }
}

/// The contract suite of `AssetStore` (docs/architecture.md §5 and §7).
public enum AssetStoreContract {
    public static func run(_ make: @Sendable () async throws -> AssetStoreSubject) async throws {
        let subject = try await make()
        let store = subject.store
        let audio: AssetID = Identifier(uuid: UUID())
        let data = Data("synthetic audio".utf8)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        let placed = try await store.place(data, as: audio, kind: .audio)
        #expect(placed.url == subject.locations.asset(audio, kind: .audio), "A file's place comes from its ID.")
        #expect(placed.byteCount == Int64(data.count))
        #expect(placed.sha256 == sha)
        #expect(subject.exists(placed.url))
        #expect(try await store.find(audio, kind: .audio) == placed)
        try await store.verify(audio, kind: .audio, sha256: sha)
        await #expect(throws: KnotError.checksumMismatch.with(.init(assetID: audio))) {
            try await store.verify(audio, kind: .audio, sha256: String(repeating: "0", count: 64))
        }

        // The same content again is the stored file; other content is refused and changes nothing.
        #expect(try await store.place(data, as: audio, kind: .audio) == placed)
        await #expect(throws: KnotError.assetConflict.with(.init(assetID: audio))) {
            try await store.place(Data("other".utf8), as: audio, kind: .audio)
        }
        try await store.verify(audio, kind: .audio, sha256: sha)

        // A file written elsewhere moves in, and its source is gone.
        let drawing: AssetID = Identifier(uuid: UUID())
        let source = try subject.writeScratch(Data("synthetic strokes".utf8))
        let moved = try await store.move(source, as: drawing, kind: .ink)
        #expect(moved.url == subject.locations.asset(drawing, kind: .ink))
        #expect(!subject.exists(source), "The source of a move is gone.")
        #expect(subject.exists(moved.url))

        // Removing is final, and removing what is not there is not an error.
        try await store.remove(audio, kind: .audio)
        #expect(try await store.find(audio, kind: .audio) == nil)
        #expect(!subject.exists(placed.url))
        try await store.remove(audio, kind: .audio)
        await #expect(throws: KnotError.notFound.with(.init(assetID: audio))) {
            try await store.verify(audio, kind: .audio, sha256: sha)
        }
    }
}
