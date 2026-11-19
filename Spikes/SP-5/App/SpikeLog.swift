import Foundation
import QuartzCore
import Synchronization
import os

/// One clock for every measurement: seconds since the system started, on the same base as
/// Carbon's `GetEventTime` and `AVAudioTime.seconds(forHostTime:)`.
enum Clock {
    static func now() -> Double { CACurrentMediaTime() }
}

/// The spike's event log: one JSON object per line in the app's own container
/// (`Library/Application Support/SP5/events.jsonl`). It holds event names, key codes, timings,
/// counts, states and status codes. Never typed text and never audio (AGENTS.md, hard rules).
/// In the self-test every line is also printed, so that `build.sh` shows it.
enum SP5Log {
    private static let lock = Mutex(())
    private static let logger = Logger(subsystem: "com.p3ob7o.knot.dev.sp5", category: "spike")
    /// Set by the self-test, so that every line is also printed.
    static let echo = Atomic<Bool>(false)

    static var folder: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let folder = base.appending(path: "SP5", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static var fileURL: URL? { folder?.appending(path: "events.jsonl") }

    static func record(_ event: String, _ fields: [String: String] = [:]) {
        var line = fields
        line["event"] = event
        line["t"] = ms(Clock.now())
        line["pid"] = String(getpid())
        logger.log("\(event, privacy: .public) \(fields.description, privacy: .public)")
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        if echo.load(ordering: .relaxed), let text = String(data: data, encoding: .utf8) {
            print("sp5:", text)
            fflush(stdout)
        }
        guard let url = fileURL else { return }
        data.append(0x0A)
        lock.withLock { _ in
            let manager = FileManager.default
            if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// Milliseconds with one decimal, as text.
    static func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1000) }

    static func status(_ status: OSStatus) -> String { String(status) }
}
