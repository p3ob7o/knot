import Foundation
import Synchronization
import os

/// Where the spike's shared files live: the development app group, read from the Info.plist
/// (docs/architecture.md §7). Never a milestone identifier.
enum SP1Paths {
    static let appGroup: String? = Bundle.main.object(forInfoDictionaryKey: "KnotAppGroup") as? String

    static var group: URL? {
        appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    /// The spike's own folder in the group container, created with no file protection so
    /// that the content-free log can be written before the first unlock.
    static var spikeFolder: URL? {
        guard let group else { return nil }
        let folder = group.appending(path: "SP1", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.none])
        return folder
    }
}

/// Which process this is, and since when it runs. The answer to "in which process does each
/// intent run" is read from this.
enum SP1Process {
    static let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
    static let role: String = bundleID.hasSuffix(".widgets") ? "widgets" : "app"
    static let pid = getpid()

    static let isSimulator: Bool = {
        #if targetEnvironment(simulator)
            true
        #else
            false
        #endif
    }()

    /// The kernel's start time of this process, so that a press can be told cold or warm.
    static let startedAt: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }()
}

/// The spike's event log: one JSON object per line in the app group, read by the app and
/// shared from it after the sitting. It holds names, IDs, timings, states and error codes,
/// never text, a transcript or audio (AGENTS.md, hard rules).
enum SP1Log {
    private static let lock = Mutex(())
    private static let logger = Logger(subsystem: "com.p3ob7o.knot.dev.sp1", category: "spike")

    static var fileURL: URL? { SP1Paths.spikeFolder?.appending(path: "events.jsonl") }

    static func record(_ event: String, _ fields: [String: String] = [:]) {
        let now = Date()
        var line = fields
        line["event"] = event
        line["t"] = now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        line["epoch"] = epoch(now)
        line["proc"] = SP1Process.role
        line["pid"] = String(SP1Process.pid)
        logger.log("\(event, privacy: .public) \(fields.description, privacy: .public)")
        guard let url = fileURL,
            var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
        else { return }
        data.append(0x0A)
        lock.withLock { _ in
            let manager = FileManager.default
            if !manager.fileExists(atPath: url.path) {
                manager.createFile(
                    atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.none])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    static func read(last count: Int = 300) -> [[String: String]] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        let lines = data.split(separator: 0x0A).suffix(count)
        return lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: String] }
    }

    static func clear() {
        guard let url = fileURL else { return }
        lock.withLock { _ in try? Data().write(to: url, options: .noFileProtection) }
    }

    static func epoch(_ date: Date) -> String { String(format: "%.3f", date.timeIntervalSince1970) }

    /// Milliseconds, or "unlimited" for the effectively infinite values the system reports, such
    /// as `backgroundTimeRemaining` while the app is in front.
    static func ms(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, abs(seconds) < 1e7 else { return "unlimited" }
        return String(Int((seconds * 1000).rounded()))
    }

    static func code(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code)"
    }
}
