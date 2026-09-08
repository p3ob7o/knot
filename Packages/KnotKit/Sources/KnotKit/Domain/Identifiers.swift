import Foundation

public protocol KnotIdentifier: Codable, Hashable, Sendable, CustomStringConvertible {
    var rawValue: UUID { get }
    init(rawValue: UUID)
}

public extension KnotIdentifier {
    init() { self.init(rawValue: UUID()) }
    var description: String { rawValue.uuidString }
}

public struct VaultID: KnotIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct DraftID: KnotIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct CaptureID: KnotIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct AssetID: KnotIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct OperationID: KnotIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }
public struct OnboardingSessionID: KnotIdentifier { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }

public struct Revision: Codable, Hashable, Sendable, Comparable {
    public let rawValue: Int64

    public init(_ rawValue: Int64) throws {
        guard rawValue >= 0 else { throw DomainValidationError.negativeRevision }
        self.rawValue = rawValue
    }

    public static let zero = try! Revision(0)

    public func next() throws -> Revision {
        guard rawValue < Int64.max else { throw DomainValidationError.revisionOverflow }
        return try Revision(rawValue + 1)
    }

    public static func < (lhs: Revision, rhs: Revision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(Int64.self)
        try self.init(value)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum DomainValidationError: Error, Equatable, LocalizedError, Sendable {
    case negativeRevision
    case revisionOverflow
    case blankCapture
    case documentTooLarge
    case invalidRoutingLimit
    case invalidHeading
    case invalidLocale
    case invalidTimeZone

    public var errorDescription: String? {
        switch self {
        case .negativeRevision: "Revision cannot be negative."
        case .revisionOverflow: "Revision limit reached."
        case .blankCapture: "Type something before sending."
        case .documentTooLarge: "The capture exceeds the 8 MiB Markdown limit."
        case .invalidRoutingLimit: "Daily routing limit must be between 1 and 100000."
        case .invalidHeading: "Choose a valid Markdown heading."
        case .invalidLocale: "The stored locale is not valid."
        case .invalidTimeZone: "The stored time zone is not valid."
        }
    }
}
