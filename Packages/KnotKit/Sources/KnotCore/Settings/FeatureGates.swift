/// A feature that a gate can switch off.
public enum Feature: String, Hashable, Sendable, Codable, CaseIterable {
    /// iCloud sync. Its gate also lets sync become a paid feature later; in v1 it is open.
    case sync
    /// The `knot` command and the MCP server.
    case commandLine = "command_line"
    /// Writing by hand.
    case ink

    /// The milestone whose sitting opens the feature in a milestone build
    /// (docs/architecture.md §18): sync and the command line at M4, ink at M5.
    public var opensAt: MilestoneLevel {
        switch self {
        case .sync, .commandLine: .m4
        case .ink: .m5
        }
    }
}

/// The level a milestone build is made at, M1 to M7.
public enum MilestoneLevel: Int, Hashable, Sendable, Codable, CaseIterable, Comparable {
    case m1 = 1
    case m2
    case m3
    case m4
    case m5
    case m6
    case m7

    /// Reads the `KnotMilestoneLevel` value of an Info.plist: `M1` to `M7`, or `none` for a
    /// development build, which has no level. Anything else is no level either.
    public init?(infoValue: String) {
        guard infoValue.count == 2, infoValue.first == "M", let number = Int(infoValue.dropFirst()),
            let level = MilestoneLevel(rawValue: number)
        else { return nil }
        self = level
    }

    public var infoValue: String { "M\(rawValue)" }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The feature gates port (docs/architecture.md §5).
public protocol FeatureGates: Sendable {
    func isOpen(_ feature: Feature) -> Bool
}

/// The gates of a build, from its milestone level.
///
/// A milestone build switches off each feature whose milestone has not passed. A development
/// build has no level and every gate open, and a fix built for an earlier milestone carries
/// that milestone's level, so it has no feature that has not had its sitting.
public struct MilestoneGates: FeatureGates, Hashable {
    public let level: MilestoneLevel?

    public init(level: MilestoneLevel?) {
        self.level = level
    }

    /// The gates for an Info.plist's `KnotMilestoneLevel` value.
    public init(infoValue: String?) {
        self.level = infoValue.flatMap(MilestoneLevel.init(infoValue:))
    }

    public func isOpen(_ feature: Feature) -> Bool {
        guard let level else { return true }
        return level >= feature.opensAt
    }
}
