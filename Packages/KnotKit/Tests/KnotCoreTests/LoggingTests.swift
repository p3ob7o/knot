import Foundation
import KnotCore
import Synchronization
import Testing

/// A sink that keeps what is logged.
final class RecordingSink: LogSink {
    private let records = Mutex<[LogRecord]>([])

    func write(_ record: LogRecord) {
        records.withLock { $0.append(record) }
    }

    var lines: [String] { records.withLock { $0.map(\.line) } }
}

@Suite struct LoggingTests {
    @Test func aLineAboutACaptureCarriesItsIDFirst() {
        let sink = RecordingSink()
        let log = KnotLog(.capture, sink: sink)
        let capture: CaptureID = id(1)
        log.capture(
            capture, "capture.stored", .segment(id(2)), .number("pieces", 2), .duration("save", .milliseconds(12)))
        #expect(
            sink.lines == [
                "capture.stored capture=\(capture) segment=\(SegmentID(id(2) as CaptureID)) pieces=2 save_ms=12"
            ])
    }

    @Test func aFailureLogsItsCodeAndIDsOnly() {
        let sink = RecordingSink()
        let log = KnotLog(.store, sink: sink)
        let error = KnotError.cleanupDeclined.with(.init(captureID: id(1), segmentID: id(1), detail: .guardRejected))
        log.failure(error, "clean.declined", .flag("retried", false))
        let capture: CaptureID = id(1)
        #expect(
            sink.lines == [
                "clean.declined capture=\(capture) code=cleanup_declined segment=\(capture) detail=guard_rejected retried=false"
            ])
    }

    @Test func theSystemSinkAcceptsEveryLevel() {
        let log = KnotLog(.app)
        for level in [KnotLog.Level.debug, .info, .notice, .error, .fault] {
            log.log(level, "logging.self_test", .number("level", 1))
        }
    }
}

@Suite struct LoggedCodeFormTests {
    @Test(arguments: ["the note said call Anna", "disk_full\nextra", "DISK_FULL", "", "a b", "code=x"])
    func aCodeThatIsNotAWellFormedCodeNeverReachesALogLine(code: String) {
        let sink = RecordingSink()
        KnotLog(.store, sink: sink).log(.error, "store.failed", .code(ErrorCode(rawValue: code)))
        #expect(sink.lines == ["store.failed code=malformed_code"])
    }

    @Test func aWellFormedCodeIsLoggedAsItIs() {
        let sink = RecordingSink()
        KnotLog(.store, sink: sink).log(.error, "store.failed", .code("disk_full"))
        #expect(sink.lines == ["store.failed code=disk_full"])
    }
}
