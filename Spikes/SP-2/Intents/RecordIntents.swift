import AppIntents

// Compiled into the Watch app and into the Watch widget extension, as docs/architecture.md
// §14 asks of intents that a control runs. `allowedExecutionTargets` (OS 27, which SP-1's
// note found) pins both to the app process, where the recorder is. Each target still
// supplies its own `RecordIntentBridge`, so if the system ever runs one in the extension,
// the extension's event log says so.

/// Starts a recording and brings the app forward: `supportedModes` is foreground.
struct RecordIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Record (SP-2)"
    static let description = IntentDescription("Opens the SP-2 spike already recording.")
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: "Source", default: "intent-foreground")
    var source: String

    init() {}

    init(source: String) {
        self.source = source
    }

    func perform() async throws -> some IntentResult {
        await RecordIntentBridge.start(source: source, intent: "RecordIntent")
        return .result()
    }
}

/// Asks to start a recording without bringing the app forward: `supportedModes` is
/// background. Whether watchOS allows that for an `AudioRecordingIntent` is SP-2's question.
struct RecordInBackgroundIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Record in the background (SP-2)"
    static let description = IntentDescription("Asks the SP-2 spike to record without opening it.")
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: "Source", default: "intent-background")
    var source: String

    init() {}

    init(source: String) {
        self.source = source
    }

    func perform() async throws -> some IntentResult {
        await RecordIntentBridge.start(source: source, intent: "RecordInBackgroundIntent")
        return .result()
    }
}
