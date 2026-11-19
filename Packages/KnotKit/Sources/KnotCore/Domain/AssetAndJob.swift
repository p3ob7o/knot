import Foundation

/// A recording's or a drawing's file (docs/architecture.md §4). Its place on disk comes
/// from its ID, through `StoreLocations`, never from a name in a manifest or a record.
public struct Asset: Hashable, Sendable, Codable, Identifiable {
    public var id: AssetID
    public var segmentID: SegmentID
    public var kind: AssetKind
    public var byteCount: Int64
    /// Lower-case hexadecimal SHA-256 of the file.
    public var sha256: String
    /// Whether the file is on this device.
    public var availability: AssetAvailability
    /// How far the upload has gone from the device that made it (docs/architecture.md §11).
    public var upload: AssetUpload

    public init(
        id: AssetID, segmentID: SegmentID, kind: AssetKind, byteCount: Int64, sha256: String,
        availability: AssetAvailability = .local, upload: AssetUpload = .localOnly
    ) {
        self.id = id
        self.segmentID = segmentID
        self.kind = kind
        self.byteCount = byteCount
        self.sha256 = sha256
        self.availability = availability
        self.upload = upload
    }
}

/// The step a job runs. Jobs are local and never sync.
public enum JobKind: String, Hashable, Sendable, Codable, CaseIterable {
    case transcribe
    case clean
    case recognise
}

/// Where a job stands (docs/architecture.md §4).
public enum JobState: Hashable, Sendable {
    case queued
    case running
    case done
    case failed(ErrorCode)
}

extension JobState: RawRepresentable, Codable {
    public init?(rawValue: String) {
        switch rawValue {
        case "queued": self = .queued
        case "running": self = .running
        case "done": self = .done
        default:
            guard rawValue.hasPrefix("failed:") else { return nil }
            self = .failed(ErrorCode(rawValue: String(rawValue.dropFirst("failed:".count))))
        }
    }

    public var rawValue: String {
        switch self {
        case .queued: "queued"
        case .running: "running"
        case .done: "done"
        case .failed(let code): "failed:\(code)"
        }
    }
}

/// A transcribe, clean or recognise job for one segment (docs/architecture.md §4).
///
/// Attempts, deferrals and deaths are counted apart: `JobMachine` holds the rules.
public struct Job: Hashable, Sendable, Codable, Identifiable {
    public var id: JobID
    public var segmentID: SegmentID
    public var kind: JobKind
    public var state: JobState
    /// Errors the step returned. After five the job fails.
    public var attempts: Int
    /// Times the job was found running at launch. After two the job fails with its own code.
    public var deaths: Int
    /// The job does not run before this time.
    public var notBefore: Date?
    public var lastErrorCode: ErrorCode?
    /// For a transcribe job, where its next run starts in the file. The store saves it with
    /// the run's pieces, so an interrupted job goes on from its last run (docs/architecture.md §9).
    public var resumeAt: Duration?

    public init(
        id: JobID, segmentID: SegmentID, kind: JobKind, state: JobState = .queued, attempts: Int = 0,
        deaths: Int = 0, notBefore: Date? = nil, lastErrorCode: ErrorCode? = nil, resumeAt: Duration? = nil
    ) {
        self.id = id
        self.segmentID = segmentID
        self.kind = kind
        self.state = state
        self.attempts = attempts
        self.deaths = deaths
        self.notBefore = notBefore
        self.lastErrorCode = lastErrorCode
        self.resumeAt = resumeAt
    }
}
