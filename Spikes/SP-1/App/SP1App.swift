import AVFAudio
import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct SP1App: App {
    init() {
        // The registration §14 relies on. It runs at every launch, in front or in the
        // background for an intent, before the intent's `perform()`.
        AppDependencyManager.shared.add(dependency: AppIntentHost() as any IntentHost)
        let context = BackgroundContext.current()
        SP1Log.record(
            "app.launch",
            [
                "appState": context.appState, "protectedData": String(context.protectedData),
                "defaults": GroupDefaultsRecordingState.probe(),
                "processAgeMs": SP1Process.startedAt.map { SP1Log.ms(Date().timeIntervalSince($0)) } ?? "?",
                "simulator": String(SP1Process.isSimulator),
            ])
        let selfTest = ProcessInfo.processInfo.arguments.contains("-SP1SelfTest")
        Task { @MainActor in
            if selfTest { SelfTest.seedOrphan() }
            await RecordingController.shared.atLaunch()
            if selfTest { await SelfTest.run() }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct SP1Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PressRecordingIntent(), phrases: ["Record with \(.applicationName)"], shortTitle: "Record",
            systemImageName: "mic.fill")
        AppShortcut(
            intent: StopRecordingIntent(), phrases: ["Stop recording in \(.applicationName)"], shortTitle: "Stop",
            systemImageName: "stop.fill")
        AppShortcut(
            intent: ProbeIntent(), phrases: ["Probe \(.applicationName)"], shortTitle: "Probe",
            systemImageName: "stethoscope")
    }
}

// MARK: - The screen

struct ContentView: View {
    @State private var controller = RecordingController.shared
    @State private var mechanism = PostStopMechanism.current
    @State private var events: [[String: String]] = []
    @State private var status = Status.read()

    var body: some View {
        NavigationStack {
            List {
                Section("Now") {
                    LabeledContent("Phase", value: controller.phase.label)
                    LabeledContent("Microphone", value: status.microphone)
                    LabeledContent("Live Activities", value: status.liveActivities)
                    LabeledContent("Protected data", value: status.protectedData)
                    LabeledContent("Speech assets", value: status.speech)
                    LabeledContent("Cleanup model", value: status.model)
                }
                Section("Work after stop") {
                    Picker("Mechanism", selection: $mechanism) {
                        ForEach(PostStopMechanism.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .onChange(of: mechanism) { _, value in
                        PostStopMechanism.current = value
                        SP1Log.record("settings.mechanism", ["mechanism": value.rawValue])
                    }
                }
                Section("Actions") {
                    Button(controller.phase == .idle ? "Record in the app" : "Stop in the app") {
                        Task { await pressInApp() }
                    }
                    Button("Ask for the microphone") {
                        Task {
                            guard !SP1Process.isSimulator else { return }
                            let granted = await AVAudioApplication.requestRecordPermission()
                            SP1Log.record("settings.mic-requested", ["granted": String(granted)])
                            refresh()
                        }
                    }
                    .disabled(SP1Process.isSimulator)
                    Button("Install the speech model") { Task { await installSpeech() } }
                    Button("Probe file protection") {
                        ProtectionProbe.run(label: "manual")
                        refresh()
                    }
                    Button("Reload controls") { ControlCenter.shared.reloadAllControls() }
                    if let url = SP1Log.fileURL { ShareLink("Share the log", item: url) }
                    Button("Clear the log", role: .destructive) {
                        SP1Log.clear()
                        refresh()
                    }
                }
                Section("Log, newest first (\(events.count))") {
                    ForEach(Array(events.reversed().enumerated()), id: \.offset) { _, event in
                        EventRow(event: event)
                    }
                }
            }
            .navigationTitle("Knot SP-1")
            .refreshable { refresh() }
            .task {
                while !Task.isCancelled {
                    refresh()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private func refresh() {
        events = SP1Log.read()
        status = Status.read()
        Task { status.speech = await Status.speechStatus() }
    }

    private func pressInApp() async {
        let press = Press(
            kind: .inApp, intent: "in-app", shownValue: nil, receivedAt: .now, preciseTimestamp: nil,
            mode: "foreground")
        let outcome = await controller.press(press)
        SP1Log.record("inapp.result", ["outcome": String(describing: outcome).prefix(80).description])
        refresh()
    }

    private func installSpeech() async {
        let transcriber = SpeechTranscriberFactory.make()
        do {
            if let request = try await SpeechTranscriberFactory.installRequest(transcriber) {
                SP1Log.record("speech.install.begin", [:])
                try await request.downloadAndInstall()
            }
            SP1Log.record("speech.install.done", ["status": await Status.speechStatus()])
        } catch {
            SP1Log.record("speech.install.error", ["error": SP1Log.code(error)])
        }
        refresh()
    }
}

private struct EventRow: View {
    let event: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(event["event"] ?? "?").font(.caption.bold())
                Spacer()
                Text("\(event["proc"] ?? "?") · \(event["t"]?.suffix(13) ?? "")").font(.caption2.monospaced())
            }
            let rest = event.filter { !["event", "t", "epoch", "proc", "pid"].contains($0.key) }
                .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            if !rest.isEmpty { Text(rest).font(.caption2.monospaced()).foregroundStyle(.secondary) }
        }
    }
}

@MainActor
private struct Status {
    var microphone: String
    var liveActivities: String
    var protectedData: String
    var speech: String
    var model: String

    static func read() -> Status {
        Status(
            microphone: RecordingController.describe(AVAudioApplication.shared.recordPermission),
            liveActivities: ActivityAuthorizationInfo().areActivitiesEnabled ? "on" : "off",
            protectedData: UIApplication.shared.isProtectedDataAvailable ? "available" : "locked",
            speech: "…",
            model: String(describing: SystemLanguageModelStatus.availability()))
    }

    static func speechStatus() async -> String {
        await SpeechTranscriberFactory.status()
    }
}
