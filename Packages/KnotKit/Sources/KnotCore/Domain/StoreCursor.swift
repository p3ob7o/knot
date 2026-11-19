/// The store's generation. It rises when a kept copy is restored (docs/architecture.md §7),
/// so that a cursor or a revision kept from before the restore is refused.
public typealias StoreGeneration = Int

/// A position in the store's change counter: the store, its generation and the counter
/// (docs/architecture.md §4). `knot changes --after` takes one.
public struct StoreCursor: Hashable, Sendable, Codable {
    public var storeID: StoreID
    public var generation: StoreGeneration
    public var counter: Int64

    public init(storeID: StoreID, generation: StoreGeneration, counter: Int64) {
        self.storeID = storeID
        self.generation = generation
        self.counter = counter
    }

    /// The text form the command line prints and reads: `<store>.<generation>.<counter>`.
    public var token: String { "\(storeID).\(generation).\(counter)" }

    public init?(token: String) {
        let parts = token.split(separator: ".").map(String.init)
        guard parts.count == 3, let store = StoreID(parts[0]), let generation = Int(parts[1]),
            let counter = Int64(parts[2]), generation >= 0, counter >= 0
        else { return nil }
        self.init(storeID: store, generation: generation, counter: counter)
    }

    /// Checks a cursor that a caller gave against the store as it is now.
    ///
    /// A cursor from another store or another generation is foreign, and one ahead of the
    /// store's counter is reported, never read as current (docs/product-spec.md §10).
    public func check(storeID: StoreID, generation: StoreGeneration, counter: Int64) throws(KnotError) {
        guard self.storeID == storeID, self.generation == generation else { throw KnotError.cursorForeign }
        guard self.counter <= counter else { throw KnotError.cursorAheadOfStore }
    }
}

/// A revision as it leaves the store: the note's or segment's revision with the store and
/// its generation (docs/architecture.md §4). `--if-revision` takes one.
public struct StampedRevision: Hashable, Sendable, Codable {
    public var storeID: StoreID
    public var generation: StoreGeneration
    public var value: Int64

    public init(storeID: StoreID, generation: StoreGeneration, value: Int64) {
        self.storeID = storeID
        self.generation = generation
        self.value = value
    }

    /// The text form: `<store>.<generation>.<revision>`.
    public var token: String { "\(storeID).\(generation).\(value)" }

    public init?(token: String) {
        guard let cursor = StoreCursor(token: token) else { return nil }
        self.init(storeID: cursor.storeID, generation: cursor.generation, value: cursor.counter)
    }

    /// Checks the revision a caller read against the current one. A revision from another
    /// store, or from before a restore, is refused like a foreign cursor; any other
    /// difference is stale.
    public func check(storeID: StoreID, generation: StoreGeneration, current: Int64) throws(KnotError) {
        guard self.storeID == storeID, self.generation == generation else { throw KnotError.revisionForeign }
        guard value == current else { throw KnotError.revisionStale }
    }
}
