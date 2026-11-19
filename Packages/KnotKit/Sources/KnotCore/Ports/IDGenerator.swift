import Foundation

/// Makes fresh IDs (docs/architecture.md §4 and §5).
///
/// A fresh ID is a version 7 UUID: its first 48 bits are the clock's time in milliseconds and
/// the rest are random, so IDs sort roughly by creation and never collide across devices. No
/// rule reads that order as time. A derived ID, version 5, is never made here: it comes from
/// the `Identifier` extensions that compute it from other IDs.
public protocol IDGenerator: Sendable {
    /// A fresh ID of any kind. Its 74 random bits make a repeat, on this device or another,
    /// a chance too small to plan for.
    func make<Tag: IdentifierTag>(_ kind: Tag.Type) -> Identifier<Tag>
}

extension IDGenerator {
    /// A fresh ID whose kind the context gives.
    public func make<Tag: IdentifierTag>() -> Identifier<Tag> { make(Tag.self) }
}

/// The live generator: the time from a wall clock, the random bits from the system's
/// cryptographic generator.
public struct SystemIDGenerator: IDGenerator {
    private let clock: any WallClock

    public init(clock: any WallClock = SystemWallClock()) {
        self.clock = clock
    }

    public func make<Tag: IdentifierTag>(_ kind: Tag.Type) -> Identifier<Tag> {
        var random = SystemRandomNumberGenerator()
        return Identifier(uuid: UUIDv7.make(at: clock.now(), using: &random))
    }
}
