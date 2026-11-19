import Foundation
import os

/// The logging facade (docs/architecture.md §19).
///
/// A log line holds IDs, counts, durations, flags and error codes, and nothing else. The
/// facade has no way to take free text: an event's name is a `StaticString` written in the
/// code, and every field is typed. So note text, transcripts and content-derived names
/// cannot reach a log. Every line about a capture carries its capture ID: `capture(_:_:_:)`
/// takes it first.
public struct KnotLog: Sendable {
    public enum Category: String, Sendable, CaseIterable {
        case app, capture, store, audio, speech, cleanup, ink, sync, link, intents, export, ui, agent
    }

    public enum Level: String, Sendable {
        case debug, info, notice, error, fault
    }

    public let category: Category
    private let sink: any LogSink

    /// A log that writes to `sink`, such as a test's recording sink.
    public init(_ category: Category, sink: any LogSink) {
        self.category = category
        self.sink = sink
    }

    /// A log that writes to the unified logging system.
    public init(_ category: Category) {
        self.init(category, sink: SystemLogSink(category: category))
    }

    public func log(_ level: Level, _ event: StaticString, _ fields: LogField...) {
        sink.write(LogRecord(level: level, category: category, event: event.description, fields: fields))
    }

    /// A line about one capture. Its ID comes first, and is the same on the watch, the phone
    /// and the Mac.
    public func capture(_ id: CaptureID, _ event: StaticString, _ fields: LogField..., level: Level = .info) {
        sink.write(
            LogRecord(level: level, category: category, event: event.description, fields: [.capture(id)] + fields))
    }

    /// A line about an error: its code and the IDs of its context.
    public func failure(_ error: KnotError, _ event: StaticString, _ fields: LogField..., level: Level = .error) {
        var all: [LogField] = []
        if let id = error.context.captureID { all.append(.capture(id)) }
        all.append(.code(error.code))
        if let id = error.context.noteID { all.append(.note(id)) }
        if let id = error.context.segmentID { all.append(.segment(id)) }
        if let id = error.context.jobID { all.append(.job(id)) }
        if let number = error.context.posixError { all.append(.number("errno", Int(number))) }
        if let detail = error.context.detail { all.append(.detail(detail)) }
        if let code = error.context.engineCode { all.append(.number("engine_code", code)) }
        sink.write(LogRecord(level: level, category: category, event: event.description, fields: all + fields))
    }
}

/// One typed field of a log line. Names are `StaticString`, so a field never carries text
/// made at run time.
public enum LogField: Sendable, Hashable {
    case capture(CaptureID)
    case note(NoteID)
    case segment(SegmentID)
    case asset(AssetID)
    case job(JobID)
    case code(ErrorCode)
    case detail(ErrorDetail)
    case number(StaticString, Int)
    case duration(StaticString, Duration)
    case flag(StaticString, Bool)

    /// The field as `name=value`.
    public var rendered: String {
        switch self {
        case .capture(let id): "capture=\(id)"
        case .note(let id): "note=\(id)"
        case .segment(let id): "segment=\(id)"
        case .asset(let id): "asset=\(id)"
        case .job(let id): "job=\(id)"
        case .code(let code): "code=\(Self.catalogued.contains(code) ? code.rawValue : "unlisted_code")"
        case .detail(let detail): "detail=\(detail.rawValue)"
        case .number(let name, let value): "\(name)=\(value)"
        case .duration(let name, let value): "\(name)_ms=\(Self.milliseconds(value))"
        case .flag(let name, let value): "\(name)=\(value)"
        }
    }

    /// The codes of the catalogue. A code from elsewhere, such as a file or a newer Knot, may
    /// be any word, even one from a note, so only these are written as they are; any other is
    /// written as one fixed token, and nothing of its value reaches the line.
    private static let catalogued = Set(KnotError.catalog.map(\.code))

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }

    public static func == (lhs: LogField, rhs: LogField) -> Bool { lhs.rendered == rhs.rendered }

    public func hash(into hasher: inout Hasher) { hasher.combine(rendered) }
}

/// One log line before it is written.
public struct LogRecord: Sendable, Hashable {
    public let level: KnotLog.Level
    public let category: KnotLog.Category
    public let event: String
    public let fields: [LogField]

    /// The line as the system log holds it: the event, then each field.
    public var line: String {
        ([event] + fields.map(\.rendered)).joined(separator: " ")
    }
}

/// Where log records go. Tests use a sink that keeps them, to check that no text reaches a log.
public protocol LogSink: Sendable {
    func write(_ record: LogRecord)
}

/// The unified logging system. Every field is an ID, a number, a flag or a code, so the line
/// is public.
public struct SystemLogSink: LogSink {
    private let logger: Logger

    public init(category: KnotLog.Category) {
        self.logger = Logger(subsystem: "knot", category: category.rawValue)
    }

    public func write(_ record: LogRecord) {
        let line = record.line
        switch record.level {
        case .debug: logger.debug("\(line, privacy: .public)")
        case .info: logger.info("\(line, privacy: .public)")
        case .notice: logger.notice("\(line, privacy: .public)")
        case .error: logger.error("\(line, privacy: .public)")
        case .fault: logger.fault("\(line, privacy: .public)")
        }
    }
}
