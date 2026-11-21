import Foundation
import KnotCore
import KnotStore

/// The diagnostics file that a test build exports from About (docs/architecture.md §19;
/// docs/product-spec.md §11), and that the owner brings to the keep-gate sitting.
///
/// It holds capture rows without their content hash, job rows, the week's daily counters,
/// the store's consistency problems, the signpost timings, the launch report, the build and the
/// OS. It holds no note text, no title, no content hash and no name derived from content: every
/// field is an ID, a date, a count, a duration or a word from a closed set. A value that came
/// from outside, such as an error code a newer Knot wrote, is written only when it is one of
/// this build's codes. WP-30 and WP-33 put its entry in About.
public struct DiagnosticsFile: Hashable, Sendable, Codable {
    public static let formatVersion = 1

    public var formatVersion = Self.formatVersion
    public var generatedAt: Date
    public var build: BuildInfo
    public var os: OSInfo
    public var launch: LaunchReport?
    public var store: StoreSummary
    public var captures: [CaptureRow]
    public var jobs: [JobRow]
    /// The daily counters of the last seven UTC days, by day and then by name.
    public var weekCounts: [String: [String: Int]]
    /// The signpost timings, by moment.
    public var timings: [String: TimingSummary]

    public struct OSInfo: Hashable, Sendable, Codable {
        public var platform: String
        public var version: String
    }

    public struct StoreSummary: Hashable, Sendable, Codable {
        public var open: Bool
        /// Why the store is not open.
        public var problem: ErrorCode?
        public var schemaVersion: Int?
        /// The codes of the problems the consistency check found, none in a consistent store.
        public var consistencyProblems: [String]
    }

    /// A capture row, without its content hash.
    public struct CaptureRow: Hashable, Sendable, Codable {
        public var id: String
        public var kind: String
        /// `device`, `cli` or `mcp`.
        public var source: String
        public var surface: String
        public var startedAt: Date
        public var endedAt: Date?
        public var outcome: String
        public var launchID: String
        /// `window`, `new_note` or `named`.
        public var placement: String
        public var revision: Int64
        public var lastSavedAt: Date?
    }

    public struct JobRow: Hashable, Sendable, Codable {
        public var id: String
        public var segmentID: String
        public var kind: String
        public var state: String
        public var attempts: Int
        public var deaths: Int
        public var notBefore: Date?
        public var lastErrorCode: String?
        public var resumeAtMilliseconds: Int64?
    }

    public struct TimingSummary: Hashable, Sendable, Codable {
        public var count: Int
        public var medianMilliseconds: Double
        public var p95Milliseconds: Double
    }
}

/// Builds the diagnostics file of a live composition.
public struct DiagnosticsExporter: Sendable {
    /// The most capture rows the file lists.
    public static let captureLimit = 5000

    let composition: LiveComposition

    /// The file, as JSON with sorted keys and dates in ISO 8601.
    public func exportData() async -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(await export())) ?? Data()
    }

    /// A file name made of the time alone, in UTC: no name derived from content.
    public func suggestedFileName(at date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(
            format: "%04d%02d%02dT%02d%02d%02dZ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
            parts.minute ?? 0, parts.second ?? 0)
        return "knot-diagnostics-\(stamp).json"
    }

    public func export() async -> DiagnosticsFile {
        let now = composition.clock.now()
        let report = await composition.launch.reportIfRun()
        var file = DiagnosticsFile(
            generatedAt: now, build: composition.configuration.build, os: Self.os(), launch: report,
            store: .init(open: false, problem: nil, schemaVersion: nil, consistencyProblems: []), captures: [],
            jobs: [], weekCounts: [:], timings: Self.summaries(composition.timings.snapshot()))
        let ports: StoreGate.Ports
        do throws(KnotError) {
            ports = try composition.gate.ports()
        } catch {
            file.store.problem = Self.listed(error.code) == nil ? nil : error.code
            return file
        }
        file.store.open = true
        file.store.schemaVersion = StoreSchema.currentVersion
        let database = ports.opened.database
        file.store.consistencyProblems = ((try? database.consistencyProblems()) ?? []).map(\.code)
        file.weekCounts = Self.lastWeek(of: (try? database.dailyCounts()) ?? [:], now: now)
        file.captures = await Self.captureRows(ports.notes).map(Self.row)
        file.jobs = ((try? await ports.notes.jobs(for: nil)) ?? []).map(Self.row)
        return file
    }

    // MARK: Rows

    /// The capture rows the store can name: the open ones, and the capture of every first piece
    /// of a segment in the stream.
    private static func captureRows(_ notes: any NoteStore) async -> [Capture] {
        var ids: [CaptureID] = []
        var seen: Set<CaptureID> = []
        func add(_ id: CaptureID) {
            if seen.insert(id).inserted { ids.append(id) }
        }
        for capture in (try? await notes.openCaptures()) ?? [] { add(capture.id) }
        var position: StreamPosition?
        repeat {
            guard let page = try? await notes.stream(after: position, limit: 200) else { break }
            for record in page.notes {
                for segment in record.segments where segment.pieceOf == nil { add(CaptureID(segment.id)) }
            }
            position = page.next
        } while position != nil && ids.count < captureLimit
        var rows: [Capture] = []
        for id in ids.prefix(captureLimit) {
            if let capture = try? await notes.capture(id) { rows.append(capture) }
        }
        return rows.sorted { $0.startedAt < $1.startedAt }
    }

    private static func row(_ capture: Capture) -> DiagnosticsFile.CaptureRow {
        let source: String =
            switch capture.origin.source {
            case .device: "device"
            case .cli: "cli"
            case .mcp: "mcp"
            default: "unknown"
            }
        let placement: String =
            switch capture.placement {
            case .window: "window"
            case .newNote: "new_note"
            case .named: "named"
            }
        let outcome: String =
            switch capture.outcome {
            case .open: "open"
            case .stored: "stored"
            case .discardedEmpty: "discarded_empty"
            case .failed(let code): "failed:\(listed(code) ?? "unlisted_code")"
            }
        return DiagnosticsFile.CaptureRow(
            id: capture.id.description, kind: known(capture.kind), source: source,
            surface: known(capture.origin.surface),
            startedAt: capture.startedAt, endedAt: capture.endedAt, outcome: outcome,
            launchID: capture.launchID.description, placement: placement, revision: capture.revision,
            lastSavedAt: capture.lastSavedAt)
    }

    private static func row(_ job: Job) -> DiagnosticsFile.JobRow {
        let state: String =
            switch job.state {
            case .queued: "queued"
            case .running: "running"
            case .done: "done"
            case .failed(let code): "failed:\(listed(code) ?? "unlisted_code")"
            }
        return DiagnosticsFile.JobRow(
            id: job.id.description, segmentID: job.segmentID.description, kind: job.kind.rawValue, state: state,
            attempts: job.attempts, deaths: job.deaths, notBefore: job.notBefore,
            lastErrorCode: job.lastErrorCode.map { listed($0) ?? "unlisted_code" },
            resumeAtMilliseconds: job.resumeAt.map(milliseconds))
    }

    // MARK: Closed sets

    private static let catalogued = Set(KnotError.catalog.map(\.code))

    /// The code when it is one of this build's, so that no word from elsewhere reaches the file.
    static func listed(_ code: ErrorCode) -> String? {
        catalogued.contains(code) ? code.rawValue : nil
    }

    /// A value this build knows, or `unknown`: a newer Knot's word is not written.
    private static func known<Value: OpenEnum>(_ value: Value) -> String {
        value.isUnknown ? "unknown" : value.rawValue
    }

    // MARK: Counts and timings

    /// The daily counters this build writes (docs/architecture.md §7 and §19). A name the
    /// store's table holds that is not one of them, as a newer Knot may write, is not written.
    static let knownCounters: Set<String> = [
        "captures_typed", "captures_voice", "captures_ink", "captures_unknown", "captures_failed", "jobs_failed",
        "new_note", "moves",
        "returns",
    ]

    static func lastWeek(of counts: [String: [String: Int]], now: Date) -> [String: [String: Int]] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let days = (0..<7).compactMap { offset -> String? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let date = parts.day else { return nil }
            return String(format: "%04d-%02d-%02d", year, month, date)
        }
        var week: [String: [String: Int]] = [:]
        for (day, named) in counts where days.contains(day) {
            week[day] = named.filter { knownCounters.contains($0.key) }
        }
        return week
    }

    static func summaries(_ durations: [MeasuredMoment: [Duration]]) -> [String: DiagnosticsFile.TimingSummary] {
        var result: [String: DiagnosticsFile.TimingSummary] = [:]
        for (moment, list) in durations where !list.isEmpty {
            let sorted = list.map { Double(milliseconds($0)) + fraction($0) }.sorted()
            result[moment.rawValue] = DiagnosticsFile.TimingSummary(
                count: sorted.count, medianMilliseconds: percentile(sorted, 0.5),
                p95Milliseconds: percentile(sorted, 0.95))
        }
        return result
    }

    private static func percentile(_ sorted: [Double], _ share: Double) -> Double {
        let index = Int((Double(sorted.count - 1) * share).rounded(.up))
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }

    private static func fraction(_ duration: Duration) -> Double {
        Double(duration.components.attoseconds % 1_000_000_000_000_000) / 1e15
    }

    private static func os() -> DiagnosticsFile.OSInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let platform: String
        #if os(macOS)
            platform = "macOS"
        #elseif os(watchOS)
            platform = "watchOS"
        #else
            platform = "iOS"
        #endif
        return DiagnosticsFile.OSInfo(
            platform: platform,
            version: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
    }
}
