import Darwin
import Foundation
import KnotKit

private struct Measurement: Codable {
    let name: String
    let unit: String
    let runs: Int
    let median: Double
    let p95: Double
    let budgetP95: Double
    let passed: Bool
}

private struct Report: Codable {
    let schemaVersion: Int
    let toolchain: String
    let operatingSystem: String
    let hardwareModel: String
    let physicalMemoryBytes: UInt64
    let cache: String
    let measurements: [Measurement]
}

@main
private struct KnotBenchmark {
    static func main() async throws {
        let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
        let manifest = options.fixtures.appending(path: "fixture-manifest.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw BenchmarkError.missingFixtures
        }
        let scratch = options.fixtures.appending(path: "benchmark-scratch", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: scratch)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let folder1000 = try await folderMeasurement(
            root: options.fixtures.appending(path: "vault-1000"),
            expected: 1_000,
            runs: options.runs,
            budget: 250
        )
        let folder10000 = try await folderMeasurement(
            root: options.fixtures.appending(path: "vault-10000"),
            expected: 10_000,
            runs: options.runs,
            budget: 2_000
        )
        let enqueue = try await enqueueMeasurement(scratch: scratch, runs: options.runs)
        let daily = try await dailyMeasurement(
            fixture: options.fixtures.appending(path: "daily-1mib.md"),
            scratch: scratch,
            runs: options.runs
        )
        let report = Report(
            schemaVersion: 1,
            toolchain: swiftVersion(),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: sysctlString("hw.model") ?? "unknown",
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            cache: options.cache,
            measurements: [folder1000, folder10000, enqueue, daily]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        try data.write(to: options.output, options: .atomic)

        print("workflow\tmedian_ms\tp95_ms\tbudget_ms\tresult")
        for item in report.measurements {
            print(String(format: "%@\t%.3f\t%.3f\t%.0f\t%@", item.name, item.median, item.p95, item.budgetP95, item.passed ? "PASS" : "FAIL"))
        }
        print("report\t" + options.output.path)
    }

    private static func folderMeasurement(
        root: URL,
        expected: Int,
        runs: Int,
        budget: Double
    ) async throws -> Measurement {
        let vaultID = VaultID()
        let provider = DescriptorFolderListingProvider(
            access: DirectoryVaultAccessProvider(vaultID: vaultID, rootURL: root)
        )
        var values: [Double] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            let listing = try await provider.list(path: .root)
            let elapsed = milliseconds(ContinuousClock.now - start)
            guard listing.children.count == expected else { throw BenchmarkError.fixtureMismatch }
            values.append(elapsed)
        }
        return result(name: "folder-list-" + String(expected), values: values, budget: budget)
    }

    private static func enqueueMeasurement(scratch: URL, runs: Int) async throws -> Measurement {
        let support = scratch.appending(path: "enqueue", directoryHint: .isDirectory)
        let store = try CaptureStore(directory: support)
        let profile = try await store.createProfile(
            displayName: "Benchmark Fixture",
            bookmark: Data("fixture".utf8),
            settings: try ValidatedSettings()
        )
        let body = String(repeating: "e", count: 4 * 1_024)
        var snapshots: [CaptureSnapshot] = []
        for index in 0..<runs {
            let draft = DraftID()
            try await store.checkpointDraft(try DraftCheckpoint(
                id: draft,
                profileID: profile,
                revision: .zero,
                markdown: Data(body.utf8)
            ))
            snapshots.append(try CaptureSnapshot(
                draftID: draft,
                draftRevision: .zero,
                vaultID: profile,
                settingsRevision: .zero,
                settings: try ValidatedSettings(),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                timeZoneIdentifier: "UTC",
                localeIdentifier: "en_US",
                destination: .inbox(parent: try VaultRelativePath("Inbox"), filenameStem: "enqueue-" + String(index)),
                document: try CaptureDocument(markdown: body)
            ))
        }
        var values: [Double] = []
        for snapshot in snapshots {
            let start = ContinuousClock.now
            _ = try await store.enqueue(snapshot)
            values.append(milliseconds(ContinuousClock.now - start))
        }
        return result(name: "durable-enqueue-4kib", values: values, budget: 100)
    }

    private static func dailyMeasurement(
        fixture: URL,
        scratch: URL,
        runs: Int
    ) async throws -> Measurement {
        let original = try Data(contentsOf: fixture, options: [.mappedIfSafe])
        let vault = scratch.appending(path: "daily-vault", directoryHint: .isDirectory)
        let support = scratch.appending(path: "daily-support", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: vault.appending(path: "Daily"), withIntermediateDirectories: true)
        let noteURL = vault.appending(path: "Daily/benchmark.md")
        let store = try CaptureStore(directory: support)
        let profile = VaultID()
        let settings = try ValidatedSettings()
        _ = try await store.createProfile(
            id: profile,
            displayName: "Benchmark Fixture",
            bookmark: Data("fixture".utf8),
            settings: settings
        )
        let gateway = VaultGateway(
            store: store,
            access: DirectoryVaultAccessProvider(vaultID: profile, rootURL: vault),
            privateRoot: support
        )
        var captures: [CaptureID] = []
        for index in 0..<runs {
            let body = "benchmark-" + String(index)
            let draft = DraftID()
            try await store.checkpointDraft(try DraftCheckpoint(
                id: draft,
                profileID: profile,
                revision: .zero,
                markdown: Data(body.utf8)
            ))
            let snapshot = try CaptureSnapshot(
                draftID: draft,
                draftRevision: .zero,
                vaultID: profile,
                settingsRevision: .zero,
                settings: settings,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                timeZoneIdentifier: "UTC",
                localeIdentifier: "en_US",
                destination: .today(
                    notePath: try VaultRelativePath("Daily/benchmark.md", kind: .file),
                    target: .endOfNote
                ),
                document: try CaptureDocument(markdown: body)
            )
            _ = try await store.enqueue(snapshot)
            captures.append(snapshot.id)
        }
        var values: [Double] = []
        for capture in captures {
            try original.write(to: noteURL, options: .atomic)
            let start = ContinuousClock.now
            _ = try await gateway.commit(captureID: capture)
            values.append(milliseconds(ContinuousClock.now - start))
        }
        return result(name: "daily-append-1mib", values: values, budget: 200)
    }

    private static func result(name: String, values: [Double], budget: Double) -> Measurement {
        let sorted = values.sorted()
        let median = percentile(sorted, 0.5)
        let p95 = percentile(sorted, 0.95)
        return Measurement(
            name: name,
            unit: "milliseconds",
            runs: values.count,
            median: median,
            p95: p95,
            budgetP95: budget,
            passed: p95 <= budget
        )
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))
        return sorted[index]
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let values = duration.components
        return Double(values.seconds) * 1_000 + Double(values.attoseconds) / 1_000_000_000_000_000
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        let value = bytes.prefix { element in element != 0 }.map { element in UInt8(bitPattern: element) }
        return String(decoding: value, as: UTF8.self)
    }

    private static func swiftVersion() -> String {
        #if swift(>=6.0)
        return "Swift 6"
        #else
        return "Swift"
        #endif
    }
}

private struct Options {
    let fixtures: URL
    let output: URL
    let runs: Int
    let cache: String

    init(arguments: [String]) throws {
        var fixtures: URL?
        var output: URL?
        var runs = 30
        var cache = "warm"
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard index + 1 < arguments.count else { throw BenchmarkError.invalidArguments }
            let value = arguments[index + 1]
            switch argument {
            case "--fixtures": fixtures = URL(fileURLWithPath: value, isDirectory: true)
            case "--output": output = URL(fileURLWithPath: value)
            case "--runs": runs = Int(value) ?? 0
            case "--cache": cache = value
            default: throw BenchmarkError.invalidArguments
            }
            index += 2
        }
        guard let fixtures, runs >= 30, ["cold", "warm"].contains(cache) else {
            throw BenchmarkError.invalidArguments
        }
        self.fixtures = fixtures
        self.output = output ?? fixtures.appending(path: "benchmark-results.json")
        self.runs = runs
        self.cache = cache
    }
}

private enum BenchmarkError: Error, LocalizedError {
    case invalidArguments, missingFixtures, fixtureMismatch

    var errorDescription: String? {
        switch self {
        case .invalidArguments: "usage: KnotBenchmark --fixtures PATH [--output PATH] [--runs N>=30] [--cache warm|cold]"
        case .missingFixtures: "Generate fixtures with scripts/perf-fixtures.sh first."
        case .fixtureMismatch: "A deterministic fixture did not contain its expected entries."
        }
    }
}
