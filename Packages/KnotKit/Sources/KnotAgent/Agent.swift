import Foundation
import KnotCore

/// Everything a command takes from its caller (docs/architecture.md §3). The `knot`
/// executable fills it in; the tests fill it with the fakes.
public struct AgentContext: Sendable {
    /// The tool's name as it was started, such as `knot-dev`, its version and its flavour.
    public var tool: ToolInfo
    public var notes: any NoteStore
    public var settings: any SettingsStore
    public var gates: any FeatureGates
    public var clock: any WallClock
    public var ids: any IDGenerator
    public var notifier: any ProcessNotifier
    /// This process's launch, which owns a capture while it is open.
    public var launchID: LaunchID
    /// The store's device ID, which tells whose work a recording waits for; `nil` when the
    /// caller opened no store.
    public var thisDevice: DeviceID?
    /// The transcriber's readiness on this device.
    public var speech: TranscriberReadiness
    /// Where the store the tool opened lives, as `knot status` prints it; `nil` for none.
    public var store: String?
    public var input: any TextInput
    public var output: any TextOutput

    public init(
        tool: ToolInfo, notes: any NoteStore, settings: any SettingsStore, gates: any FeatureGates,
        clock: any WallClock, ids: any IDGenerator, notifier: any ProcessNotifier, launchID: LaunchID,
        thisDevice: DeviceID?, speech: TranscriberReadiness, store: String?, input: any TextInput,
        output: any TextOutput
    ) {
        self.tool = tool
        self.notes = notes
        self.settings = settings
        self.gates = gates
        self.clock = clock
        self.ids = ids
        self.notifier = notifier
        self.launchID = launchID
        self.thisDevice = thisDevice
        self.speech = speech
        self.store = store
        self.input = input
        self.output = output
    }
}

public struct ToolInfo: Sendable, Hashable {
    public var name: String
    public var version: String
    public var flavour: String

    public init(name: String, version: String, flavour: String) {
        self.name = name
        self.version = version
        self.flavour = flavour
    }
}

/// Standard output and standard error. A result goes to the first and everything else to the
/// second (docs/product-spec.md §10).
public protocol TextOutput: Sendable {
    func result(_ text: String)
    func message(_ text: String)
}

/// The process's own streams.
public struct StandardOutput: TextOutput {
    public init() {}

    public func result(_ text: String) { FileHandle.standardOutput.write(Data(text.utf8)) }
    public func message(_ text: String) { FileHandle.standardError.write(Data(text.utf8)) }
}

/// The `knot` command: one run of one command line.
public enum Agent {
    /// Runs `arguments`, the words after the tool's name, and returns the exit status.
    /// Nothing is asked of a person, and no error carries note text.
    public static func run(_ arguments: [String], in context: AgentContext) async -> ExitStatus {
        let render = Render(tool: context.tool, json: Parser.wantsJSON(arguments))
        do {
            let text = try await answer(Parser.parse(arguments), in: context, render: render)
            context.output.result(text)
            return .done
        } catch {
            context.output.message(render.failure(error))
            return error.error.exitStatus
        }
    }

    private static func answer(_ invocation: Invocation, in context: AgentContext, render: Render)
        async throws(Failure) -> String
    {
        switch invocation {
        case .overview: return render.overview()
        case .version: return "\(context.tool.name) \(context.tool.version) (\(context.tool.flavour))\n"
        case .help(nil): return render.overview()
        case .help(let topic?):
            if let command = CommandTable.command(named: topic) { return render.usage(command) }
            if let error = KnotError.known(ErrorCode(rawValue: topic)) { return render.entry(error) }
            throw Failure(.usageInvalidArgument, command: CommandTable.help)
        case .commandHelp(let command): return render.usage(command)
        case .run(let command, let arguments):
            let settings = try await checkAccess(context)
            let session = Session(context: context, settings: settings, render: render)
            switch command.name {
            case CommandTable.status.name: return try await session.status()
            case CommandTable.add.name: return try await session.add(arguments)
            case CommandTable.list.name: return try await session.list(arguments)
            default: throw Failure(.usageUnknownCommand)
            }
        }
    }

    /// The access switch (docs/architecture.md §19): before a command does anything else, the
    /// gate and then the setting, each through its port. A closed gate, in a milestone build
    /// below M4, answers as the switch does.
    static func checkAccess(_ context: AgentContext) async throws(Failure) -> Settings {
        guard context.gates.isOpen(.commandLine) else { throw Failure(.accessOff) }
        let settings: Settings
        do {
            settings = try await context.settings.load()
        } catch {
            throw Failure(error)
        }
        guard settings.commandLineAccess else { throw Failure(.accessOff) }
        return settings
    }
}

/// One command that passed the access switch.
struct Session {
    let context: AgentContext
    let settings: Settings
    let render: Render

    private var notes: any NoteStore { context.notes }

    /// Whether sync is on, as far as the settings and the gate say. `nil` when the person has
    /// not chosen, and sync follows the device's iCloud sign-in, which the tool cannot read.
    var sync: Bool? {
        guard context.gates.isOpen(.sync) else { return false }
        return settings.syncEnabled
    }

    func status() async throws(Failure) -> String {
        let cursor = try await store { () async throws(KnotError) in try await notes.cursor() }
        let now = context.clock.now()
        let request = AppendRequest(startedAt: now, placement: .window, source: .cli)
        let decision = try await store { () async throws(KnotError) in
            try await notes.predictPlacement(request, kind: .typed, surface: .commandLine)
        }
        var closesAt: Date?
        if let joined = decision.joinedNote,
            let record = try await store({ () async throws(KnotError) in try await notes.note(joined) })
        {
            closesAt = record.note.lastCaptureEndedAt.addingTimeInterval(settings.appendWindow.length)
        }
        return render.status(
            store: context.store, cursor: cursor, window: settings.appendWindow, decision: decision,
            closesAt: closesAt, sync: sync)
    }

    func add(_ arguments: Arguments) async throws(Failure) -> String {
        let command = CommandTable.add
        guard let given = arguments.text else { throw Failure(.usageMissingText, command: command) }
        let text: String
        if given == "-" {
            text = try readInput(for: command)
        } else {
            guard given.utf8.count <= CommandTable.pipedTextBytes else { throw Failure(.textTooLong, command: command) }
            text = given
        }
        guard !CaptureText.isEmpty(text) else { throw Failure(.usageMissingText, command: command) }
        let now = context.clock.now()
        let id = arguments.captureID ?? context.ids.make()
        let capture = NewCapture(
            id: id, kind: .typed, origin: CaptureOrigin(source: .cli, surface: .commandLine),
            launchID: context.launchID, placement: arguments.flags.contains("--new") ? .newNote : .window,
            startedAt: now, endedAt: now, body: .text(text))
        let receipt: CaptureReceipt
        do {
            receipt = try await notes.record(capture)
        } catch {
            throw Failure(error.about(capture: id))
        }
        context.notifier.postStoreChanged()
        return render.receipt(receipt, sync: sync)
    }

    /// Reads `-`: at most the bound, and never more of it into memory.
    private func readInput(for command: Command) throws(Failure) -> String {
        let data: Data?
        do {
            data = try context.input.read(atMost: CommandTable.pipedTextBytes)
        } catch {
            throw Failure(error)
        }
        guard let data, !data.isEmpty else { throw Failure(.usageMissingText, command: command) }
        guard data.count <= CommandTable.pipedTextBytes else { throw Failure(.textTooLong, command: command) }
        guard let text = String(validating: data, as: UTF8.self) else {
            throw Failure(.usageInvalidArgument, command: command)
        }
        return text
    }

    func list(_ arguments: Arguments) async throws(Failure) -> String {
        guard let thisDevice = context.thisDevice else { throw Failure(.portUnavailable) }
        let limit = arguments.integers["--limit"] ?? 10
        let since = arguments.times["--since"]
        let cursor = try await store { () async throws(KnotError) in try await notes.cursor() }
        var shown: [NoteRecord] = []
        var position: StreamPosition?
        var more = false
        paging: while true {
            let after = position
            let page = try await store { () async throws(KnotError) in
                try await notes.stream(after: after, limit: limit + 1)
            }
            for record in page.notes {
                if let since, record.note.lastCaptureEndedAt < since { break paging }
                if shown.count == limit {
                    more = true
                    break paging
                }
                shown.append(record)
            }
            guard let next = page.next else { break }
            position = next
        }
        let now = context.clock.now()
        var listed: [ListedNote] = []
        for record in shown {
            var downloading: Set<AssetID> = []
            for segment in record.liveSegments {
                guard let assetID = segment.assetID,
                    let asset = try await store({ () async throws(KnotError) in try await notes.asset(assetID) })
                else { continue }
                if asset.availability == .downloading { downloading.insert(assetID) }
            }
            let settled = SettledRule.evaluate(
                note: record.note, segments: record.segments, downloadingAssets: downloading,
                window: settings.appendWindow, now: now, thisDevice: thisDevice, speech: context.speech)
            let segments = record.liveSegments.compactMap { segment -> ListedSegment? in
                guard let state = VisibleState.of(segment, thisDevice: thisDevice, speech: context.speech) else {
                    return nil
                }
                return ListedSegment(segment: segment, state: state, revision: record.revision(of: segment.id))
            }
            listed.append(ListedNote(record: record, settled: settled, segments: segments))
        }
        return render.list(listed, more: more, cursor: cursor, sync: sync)
    }

    /// Runs one call of the store, and turns its error into a failure of the command.
    private func store<Value>(_ call: () async throws(KnotError) -> Value) async throws(Failure) -> Value {
        do {
            return try await call()
        } catch {
            throw Failure(error)
        }
    }
}

struct ListedNote {
    let record: NoteRecord
    let settled: Settledness
    let segments: [ListedSegment]
}

struct ListedSegment {
    let segment: Segment
    let state: VisibleState
    let revision: StampedRevision?
}

extension Agent {
    /// Refuses the whole run with `error`, before any command is read: the milestone tool
    /// started with `KNOT_AGENT` set (docs/architecture.md §7).
    public static func refuse(_ error: KnotError, arguments: [String], tool: ToolInfo, output: any TextOutput)
        -> ExitStatus
    {
        output.message(Render(tool: tool, json: Parser.wantsJSON(arguments)).failure(Failure(error)))
        return error.exitStatus
    }
}
