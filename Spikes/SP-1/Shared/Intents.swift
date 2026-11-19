import AppIntents
import Foundation

// The recording intents of docs/architecture.md §14, compiled into both the app and the widget
// extension. The app registers an `IntentHost` with the App Intents dependency manager at
// launch. The widget extension registers none, so an intent the system runs there finds the
// unavailable host and fails with a typed error instead of recording in the wrong process.

// MARK: - The host the intents call

enum PressKind: String, Sendable {
    case toggleControl, pressControl, stopActivity, shortcut, inApp
}

struct Press: Sendable {
    let kind: PressKind
    let intent: String
    /// The value a toggle control showed when it was pressed, as the intent received it.
    let shownValue: Bool?
    let receivedAt: Date
    let preciseTimestamp: Date?
    let mode: String
}

enum PressOutcome: Sendable {
    case started(UUID)
    /// Stopped. The work after stop is handed back when the intent itself must run it.
    case stopped(PostStopWork?)
    case ignored(String)
    case needsForeground(String)
    case failed(String)
}

protocol IntentHost: Sendable {
    var isLive: Bool { get }
    func press(_ press: Press) async -> PressOutcome
    /// Called after the intent has brought the app forward because a background start was
    /// not possible: Live Activities off, or no microphone permission.
    func startInForeground(_ press: Press) async -> PressOutcome
}

/// What `@Dependency` answers in a process where nothing was registered.
struct UnavailableHost: IntentHost {
    var isLive: Bool { false }
    func press(_ press: Press) async -> PressOutcome { .failed("no host in \(SP1Process.role)") }
    func startInForeground(_ press: Press) async -> PressOutcome { .failed("no host in \(SP1Process.role)") }
}

enum SP1IntentError: Error, CustomLocalizedStringResourceConvertible {
    case wrongProcess(String)
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .wrongProcess(let role): "Knot SP-1 ran this in the \(role) process, where it cannot record."
        case .failed(let reason): "Knot SP-1 could not record: \(reason)"
        }
    }
}

// MARK: - The shared body of every recording intent

/// Runs one press: logs where and when it arrived, asks the host, opens the app when the host
/// says it must, and runs the work after stop inside `performBackgroundTask` when that is the
/// mechanism under test.
func performPress<I: LongRunningIntent & CancellableIntent>(
    _ intent: I, host: any IntentHost, kind: PressKind, shownValue: Bool?
) async throws {
    let receivedAt = Date()
    let context = intent.systemContext
    let mode = context.currentMode
    var fields: [String: String] = [
        "intent": String(describing: I.self),
        "kind": kind.rawValue,
        "mode": mode.debugDescription,
        "canContinueInForeground": String(mode.canContinueInForeground),
        "processAgeMs": SP1Process.startedAt.map { SP1Log.ms(receivedAt.timeIntervalSince($0)) } ?? "?",
        "hostLive": String(host.isLive),
    ]
    if let shownValue { fields["shownValue"] = String(shownValue) }
    if let precise = context.preciseTimestamp { fields["preciseTimestamp"] = SP1Log.epoch(precise) }
    SP1Log.record("intent.perform", fields)

    guard host.isLive else {
        SP1Log.record("intent.wrong-process", ["intent": String(describing: I.self)])
        throw SP1IntentError.wrongProcess(SP1Process.role)
    }
    let press = Press(
        kind: kind, intent: String(describing: I.self), shownValue: shownValue, receivedAt: receivedAt,
        preciseTimestamp: context.preciseTimestamp, mode: mode.debugDescription)
    var outcome = await host.press(press)

    if case .needsForeground(let reason) = outcome {
        SP1Log.record("intent.foreground.asked", ["reason": reason])
        do {
            try await intent.continueInForeground("Open Knot SP-1 to record.", alwaysConfirm: false)
            SP1Log.record("intent.foreground.granted", [:])
        } catch {
            SP1Log.record("intent.foreground.refused", ["error": SP1Log.code(error)])
            throw error
        }
        outcome = await host.startInForeground(press)
    }

    switch outcome {
    case .started(let id):
        SP1Log.record("intent.result", ["outcome": "started", "capture": id.uuidString])
    case .stopped(let work?):
        SP1Log.record("intent.result", ["outcome": "stopped", "capture": work.captureID.uuidString])
        try await IntentBackgroundRunner(intent: intent).run(work)
    case .stopped(nil):
        SP1Log.record("intent.result", ["outcome": "stopped"])
    case .ignored(let reason):
        SP1Log.record("intent.result", ["outcome": "ignored", "reason": reason])
    case .needsForeground(let reason):
        SP1Log.record("intent.result", ["outcome": "needs-foreground-again", "reason": reason])
    case .failed(let reason):
        SP1Log.record("intent.result", ["outcome": "failed", "reason": reason])
        throw SP1IntentError.failed(reason)
    }
}

/// The intent-backed `BackgroundRunner`: valid only inside its intent's `perform()`.
struct IntentBackgroundRunner<I: LongRunningIntent & CancellableIntent>: BackgroundRunner {
    let intent: I
    var name: String { "longRunningIntent" }

    func run(_ work: PostStopWork) async throws {
        let progress = intent.progress
        progress.totalUnitCount = 100
        progress.localizedDescription = "Knot SP-1"
        let started = Date()
        SP1Log.record("background.long-running.begin", ["capture": work.captureID.uuidString])
        do {
            try await intent.performBackgroundTask(
                operation: {
                    try await work.body { fraction, label in
                        progress.completedUnitCount = Int64(fraction * 100)
                        progress.localizedAdditionalDescription = label
                    }
                },
                onCancel: { reason in
                    SP1Log.record("background.long-running.cancel", ["reason": reason.debugDescription])
                })
            SP1Log.record(
                "background.long-running.end",
                ["capture": work.captureID.uuidString, "ms": SP1Log.ms(Date().timeIntervalSince(started))])
        } catch {
            SP1Log.record(
                "background.long-running.error",
                ["capture": work.captureID.uuidString, "error": SP1Log.code(error)])
            throw error
        }
    }
}

// MARK: - The intents

/// The toggle control's intent, which is also the one to put on the Action Button. It is
/// pinned to the app process with the OS 27 `allowedExecutionTargets`.
struct ToggleRecordingIntent: SetValueIntent, AudioRecordingIntent, LiveActivityIntent, LongRunningIntent,
    CancellableIntent
{
    static let title: LocalizedStringResource = "Toggle Recording (SP-1)"
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    static var allowedExecutionTargets: IntentExecutionTargets { [.main] }

    @Parameter(title: "Recording")
    var value: Bool

    @Dependency(default: UnavailableHost())
    private var host: any IntentHost

    init() {}

    func perform() async throws -> some IntentResult {
        try await performPress(self, host: host, kind: .toggleControl, shownValue: value)
        return .result()
    }
}

/// The same press from a button control, with no value and no pinned process, to learn where
/// the system runs an unpinned recording intent that is compiled into both targets.
struct PressRecordingIntent: AudioRecordingIntent, LiveActivityIntent, LongRunningIntent, CancellableIntent {
    static let title: LocalizedStringResource = "Press Record (SP-1)"
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Dependency(default: UnavailableHost())
    private var host: any IntentHost

    init() {}

    func perform() async throws -> some IntentResult {
        try await performPress(self, host: host, kind: .pressControl, shownValue: nil)
        return .result()
    }
}

/// The Live Activity's stop button. Safe to repeat: it only stops.
struct StopRecordingIntent: LiveActivityIntent, LongRunningIntent, CancellableIntent {
    static let title: LocalizedStringResource = "Stop Recording (SP-1)"
    static let supportedModes: IntentModes = [.background]
    static var allowedExecutionTargets: IntentExecutionTargets { [.main] }

    @Dependency(default: UnavailableHost())
    private var host: any IntentHost

    init() {}

    func perform() async throws -> some IntentResult {
        try await performPress(self, host: host, kind: .stopActivity, shownValue: nil)
        return .result()
    }
}

/// Records nothing. Logs where it runs, whether files and defaults can be read, and the
/// recording state, from whichever process the system picks for an unpinned plain intent.
struct ProbeIntent: AppIntent {
    static let title: LocalizedStringResource = "Probe (SP-1)"
    static let supportedModes: IntentModes = [.background]

    func perform() async throws -> some IntentResult {
        let state = GroupDefaultsRecordingState().read()
        SP1Log.record(
            "probe.intent",
            [
                "mode": systemContext.currentMode.debugDescription,
                "defaults": GroupDefaultsRecordingState.probe(),
                "statePhase": state.phase.rawValue,
                "stateFresh": String(state.isFresh(at: .now)),
                "processAgeMs": SP1Process.startedAt.map { SP1Log.ms(Date().timeIntervalSince($0)) } ?? "?",
            ])
        return .result()
    }
}
