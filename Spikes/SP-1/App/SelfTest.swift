import AVFAudio
import Foundation
import FoundationModels
import Speech

enum SpeechTranscriberFactory {
    static func make() -> SpeechTranscriber {
        SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .transcription)
    }

    static func installRequest(_ transcriber: SpeechTranscriber) async throws -> AssetInstallationRequest? {
        try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
    }

    static func status() async -> String {
        guard SpeechTranscriber.isAvailable else { return "unavailable" }
        return String(describing: await AssetInventory.status(forModules: [make()]))
    }
}

enum SystemLanguageModelStatus {
    static func availability() -> SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }
}

/// What the Simulator can run without a microphone, started by the launch argument
/// `-SP1SelfTest` from Spikes/SP-1/build.sh. It seeds a recording left open by a dead launch,
/// presses twice at once, and runs each background mechanism once over a synthetic silent file.
/// The recorder refuses the hardware input in the Simulator, so no microphone opens.
@MainActor
enum SelfTest {
    static func seedOrphan() {
        let id = UUID()
        let dead = Manifests.Manifest(
            captureID: id, startedAt: .now.addingTimeInterval(-60), launch: Date(timeIntervalSince1970: 1),
            pid: 1, outcome: "open")
        try? Manifests.write(dead)
        GroupDefaultsRecordingState().write(
            RecordingStateSnapshot(
                phase: .recording, captureID: id, startedAt: dead.startedAt, heartbeat: .now.addingTimeInterval(-30),
                ownerLaunch: dead.launch, ownerPID: 1))
        SP1Log.record("selftest.seeded-orphan", ["capture": id.uuidString])
    }

    static func run() async {
        SP1Log.record("selftest.begin", ["simulator": String(SP1Process.isSimulator)])
        guard SP1Process.isSimulator else {
            SP1Log.record("selftest.refused", ["reason": "runs in the Simulator only"])
            return
        }
        let controller = RecordingController.shared

        // Two presses at once on an idle recorder: the second meets "starting" and is ignored.
        func press() -> Press {
            Press(
                kind: .inApp, intent: "selftest", shownValue: nil, receivedAt: .now, preciseTimestamp: nil,
                mode: "foreground")
        }
        async let first = controller.press(press())
        async let second = controller.press(press())
        let outcomes = await [first, second]
        SP1Log.record(
            "selftest.double-press",
            ["first": String(describing: outcomes[0]), "second": String(describing: outcomes[1])])

        // A stop from the Live Activity while idle does nothing.
        let stop = await controller.press(
            Press(
                kind: .stopActivity, intent: "selftest", shownValue: nil, receivedAt: .now, preciseTimestamp: nil,
                mode: "background"))
        SP1Log.record("selftest.stop-idle", ["outcome": String(describing: stop)])

        // Each mechanism once, over one second of synthetic silence.
        for mechanism in [PostStopMechanism.none, .backgroundTask, .continuedProcessing] {
            let id = UUID()
            let url = Manifests.audioURL(id)
            do {
                try writeSilence(to: url)
            } catch {
                SP1Log.record("selftest.silence-failed", ["error": SP1Log.code(error)])
                continue
            }
            BackgroundRunners.run(PostStop.work(captureID: id, url: url), with: mechanism)
            try? await Task.sleep(for: .seconds(3))
        }
        SP1Log.record(
            "selftest.end",
            ["phase": controller.phase.label, "statePhase": GroupDefaultsRecordingState().read().phase.rawValue])
    }

    private static func writeSilence(to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)
        else { return }
        buffer.frameLength = 16_000
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
