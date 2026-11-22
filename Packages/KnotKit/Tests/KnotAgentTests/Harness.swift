import Foundation
import KnotAgent
import KnotCore
import KnotFakes
import Synchronization
import Testing

/// What a run printed, kept apart by stream.
final class CapturedOutput: TextOutput {
    private let streams = Mutex<(output: String, errors: String)>(("", ""))

    func result(_ text: String) { streams.withLock { $0.output += text } }
    func message(_ text: String) { streams.withLock { $0.errors += text } }

    /// What was printed since the last call, and clears it.
    func take() -> (output: String, errors: String) {
        streams.withLock { streams in
            defer { streams = ("", "") }
            return streams
        }
    }
}

/// Standard input that counts how much a command asked of it.
final class CountingInput: TextInput {
    let data: Data?
    private let asked = Mutex<[Int]>([])

    init(_ data: Data?) { self.data = data }

    var requests: [Int] { asked.withLock { $0 } }

    func read(atMost limit: Int) throws(KnotError) -> Data? {
        asked.withLock { $0.append(limit) }
        return data.map { $0.prefix(limit + 1) }
    }
}

/// A `ProcessNotifier` that counts the notices posted.
final class CountingNotifier: ProcessNotifier {
    private let count = Mutex(0)

    var posts: Int { count.withLock { $0 } }

    func postStoreChanged() { count.withLock { $0 += 1 } }
    func storeChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

/// A `SettingsStore` whose load fails with one error, to drive any error of the catalog
/// through a command.
struct FailingSettings: SettingsStore {
    let error: KnotError
    func load() async throws(KnotError) -> Settings { throw error }
    func save(_ settings: Settings) async throws(KnotError) { throw error }
    func changes() -> AsyncStream<Settings> { AsyncStream { $0.finish() } }
}

/// One store, its settings and its gates, on the fakes, and the runs of `knot` against them.
/// Each run moves the clock on by 30 seconds, so that the times in the output differ.
struct TestSession {
    static let tool = ToolInfo(name: "knot", version: "1.0", flavour: "dev")

    let clock = FakeClock()
    let ids: SeededIDGenerator
    let device: DeviceID
    let launch: LaunchID
    let notes: InMemoryNoteStore
    let settings: InMemorySettingsStore
    let gates = ScriptedFeatureGates()
    let channel = FakeProcessChannel()
    let output = CapturedOutput()

    init(access: Bool = true, window: AppendWindow = .default) {
        ids = SeededIDGenerator(seed: 34, clock: clock)
        device = ids.make()
        launch = ids.make()
        notes = InMemoryNoteStore(clock: clock, ids: ids, deviceID: device, window: window)
        settings = InMemorySettingsStore(Settings(appendWindow: window, syncEnabled: false, commandLineAccess: access))
    }

    func context(
        input: any TextInput = GivenInput(nil), settings: (any SettingsStore)? = nil,
        notifier: (any ProcessNotifier)? = nil
    ) -> AgentContext {
        AgentContext(
            tool: Self.tool, notes: notes, settings: settings ?? self.settings, gates: gates, clock: clock, ids: ids,
            notifier: notifier ?? channel.process(), launchID: launch, thisDevice: device, speech: .ready,
            store: "in memory", input: input, output: output)
    }

    /// Runs one command line, with standard input closed unless `input` is given.
    @discardableResult
    func run(_ arguments: [String], input: String? = nil) async -> ExampleRun {
        await run(arguments, in: context(input: GivenInput(input)))
    }

    func run(_ arguments: [String], in context: AgentContext) async -> ExampleRun {
        clock.advance(by: 30)
        let status = await Agent.run(arguments, in: context)
        let printed = output.take()
        return ExampleRun(output: printed.output, errors: printed.errors, status: status)
    }

    /// The examples of docs/cli.md, run in order on one fresh session.
    static func runExamples(_ examples: [Example] = CommandTable.allExamples) async -> [(Example, ExampleRun)] {
        let session = TestSession()
        var runs: [(Example, ExampleRun)] = []
        for example in examples {
            runs.append((example, await session.run(example.arguments, input: example.input)))
        }
        return runs
    }
}

/// The repository's root, found from this file.
func repositoryRoot(file: StaticString = #filePath) -> URL {
    var url = URL(fileURLWithPath: "\(file)")
    while url.pathComponents.count > 1 {
        url.deleteLastPathComponent()
        if FileManager.default.fileExists(atPath: url.appending(path: "PLAN.md").path) { return url }
    }
    fatalError("No repository root above \(file).")
}

/// The golden files of these tests, read by their path.
enum Golden {
    static let folder = URL(fileURLWithPath: "\(#filePath)").deletingLastPathComponent().appending(path: "Golden")

    /// True when the run should write the golden files and docs/cli.md instead of comparing.
    static var writing: Bool { ProcessInfo.processInfo.environment["KNOT_WRITE_GOLDEN"] == "1" }

    /// Compares `text` with the committed file, or writes it when `writing` is set, which
    /// fails the run so that a written file is never taken for a passing check.
    static func check(_ text: String, against url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        if writing {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            Issue.record(
                "Wrote \(url.lastPathComponent). Run again without KNOT_WRITE_GOLDEN.", sourceLocation: sourceLocation)
            return
        }
        let committed = try String(contentsOf: url, encoding: .utf8)
        #expect(
            committed == text, "\(url.lastPathComponent) differs from what the code gives.",
            sourceLocation: sourceLocation)
    }
}
