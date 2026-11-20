import Foundation

/// The time of day, as the domain reads it (docs/architecture.md §5, `Clock`).
///
/// It is named `WallClock` and not `Clock`, so that it does not shadow Swift's own `Clock`
/// protocol in every module that imports KnotCore. A wall clock can move backwards, and every
/// rule that reads two of its times keeps its promise when it does (docs/architecture.md §17).
/// Durations inside one process, such as the 250 ms of a hold, use `ContinuousClock`.
public protocol WallClock: Sendable {
    func now() -> Date
}

/// The system's clock.
public struct SystemWallClock: WallClock {
    public init() {}

    public func now() -> Date { Date() }
}
