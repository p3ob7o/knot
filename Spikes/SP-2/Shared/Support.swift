import Darwin
import Foundation

/// Median and 95th percentile, as the product spec reports its targets (§14).
struct Summary: Sendable {
    var count: Int
    var median: Double?
    var p95: Double?

    init(_ values: [Double]) {
        let sorted = values.sorted()
        count = sorted.count
        func quantile(_ q: Double) -> Double? {
            guard !sorted.isEmpty else { return nil }
            let rank = Int((q * Double(sorted.count - 1)).rounded(.up))
            return sorted[min(max(rank, 0), sorted.count - 1)]
        }
        median = quantile(0.5)
        p95 = quantile(0.95)
    }

    var text: String {
        guard let median, let p95 else { return "–" }
        return "\(seconds(median)) · p95 \(seconds(p95)) · n \(count)"
    }
}

func seconds(_ value: Double?) -> String {
    guard let value else { return "–" }
    if abs(value) < 10 { return String(format: "%.2f s", value) }
    return String(format: "%.0f s", value)
}

func milliseconds(_ value: Double?) -> String {
    guard let value else { return "–" }
    return String(format: "%.0f ms", value * 1000)
}

/// When this process started, from the kernel. Used to tell a cold start from a warm one,
/// and to see whether the system launched the app for a delivery.
enum ProcessClock {
    static let startedAt: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }()

    static var uptime: Double {
        guard let startedAt else { return -1 }
        return Date().timeIntervalSince(startedAt)
    }
}

/// Launch arguments of the form `-sp2-name value`, which the simulator tests pass with
/// `simctl launch`. Read by hand: the spike does not touch the standard defaults domain.
enum LaunchArguments {
    static func value(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-sp2-\(name)"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func int(_ name: String) -> Int? { value(name).flatMap { Int($0) } }
}

/// The spike's files, in the app's own container.
enum Folders {
    static func folder(_ name: String) -> URL {
        let url = URL.applicationSupportDirectory.appending(path: "SP2/\(name)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A Codable array kept as one JSON file, rewritten whole on each change. The spike keeps a
/// few hundred rows at most.
struct JSONFile<Value: Codable> {
    let url: URL

    init(_ name: String) {
        url = Folders.folder("State").appending(path: name)
    }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
