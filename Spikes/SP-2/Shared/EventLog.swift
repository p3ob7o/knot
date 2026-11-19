import Foundation
import os

/// An append-only log of what happened, one JSON object per line, in the app's own
/// container. The simulator tests read it back with `simctl get_app_container`, and the
/// sitting's report quotes counts from it. It holds IDs, names, numbers and error codes,
/// never text of a recording.
final class EventLog: Sendable {
    static let shared = EventLog()

    let url: URL
    private let lock = OSAllocatedUnfairLock()
    private let logger = Logger(subsystem: "com.p3ob7o.knot.dev.sp2", category: "events")

    private init() {
        let folder = URL.applicationSupportDirectory.appending(path: "SP2", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appending(path: "events.jsonl")
    }

    func append(_ event: String, _ fields: [String: String] = [:]) {
        var line = fields
        line["event"] = event
        line["t"] = String(format: "%.3f", Date().timeIntervalSince1970)
        guard let json = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        let message = String(decoding: json, as: UTF8.self)
        let data = json + Data([0x0A])
        logger.log("\(message, privacy: .public)")
        lock.withLock {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    func clear() {
        lock.withLock { try? FileManager.default.removeItem(at: url) }
    }
}
