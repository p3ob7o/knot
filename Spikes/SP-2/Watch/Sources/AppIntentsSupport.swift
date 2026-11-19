import AppIntents
import WatchKit

/// In the Watch app, an intent calls the recorder.
enum RecordIntentBridge {
    static func start(source: String, intent: String) async {
        let state = await MainActor.run { WKApplication.shared().applicationState }
        EventLog.shared.append(
            "intent.perform",
            [
                "process": "app", "intent": intent, "source": source, "app-state": "\(state.rawValue)",
                "uptime": String(format: "%.3f", ProcessClock.uptime),
            ])
        await WatchRecorder.shared.start(source: source)
    }
}

struct SP2Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordIntent(source: "siri"), phrases: ["Record with \(.applicationName)"], shortTitle: "Record",
            systemImageName: "mic")
        AppShortcut(
            intent: RecordInBackgroundIntent(source: "siri-background"),
            phrases: ["Record quietly with \(.applicationName)"], shortTitle: "Record quietly",
            systemImageName: "mic.badge.plus")
    }
}
