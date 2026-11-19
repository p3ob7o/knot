import AVFAudio
import AppIntents
import Foundation
import Observation
import UIKit
import WidgetKit

/// The app-process side of every press: the state machine of docs/architecture.md §8 in its
/// smallest form. A press while starting or stopping is ignored, a press while recording stops,
/// and a press while idle recovers a stale recording and starts a new one.
@MainActor
@Observable
final class RecordingController {
    static let shared = RecordingController()

    enum Phase: Equatable {
        case idle, starting, stopping
        case recording(UUID, Date)

        var label: String {
            switch self {
            case .idle: "idle"
            case .starting: "starting"
            case .stopping: "stopping"
            case .recording: "recording"
            }
        }
    }

    private(set) var phase: Phase = .idle
    private let recorder = Recorder()
    private let activity: any RecordingActivity = LiveRecordingActivity()
    private let state: any RecordingStateStore = GroupDefaultsRecordingState()
    private var heartbeat: Task<Void, Never>?

    // MARK: Presses

    func press(_ press: Press) async -> PressOutcome {
        SP1Log.record(
            "press.received",
            [
                "kind": press.kind.rawValue, "phase": phase.label,
                "shownValue": press.shownValue.map(String.init) ?? "-",
                "stateFresh": String(state.read().isFresh(at: .now)),
                "protectedData": String(UIApplication.shared.isProtectedDataAvailable),
                "appState": BackgroundContext.current().appState,
            ])
        switch phase {
        case .starting, .stopping:
            return .ignored("press while \(phase.label)")
        case .recording(let id, let startedAt):
            return await stop(press, captureID: id, startedAt: startedAt)
        case .idle:
            if press.kind == .stopActivity { return .ignored("stop while idle") }
            return await start(press, inForeground: press.kind == .inApp)
        }
    }

    func startInForeground(_ press: Press) async -> PressOutcome {
        guard phase == .idle else { return .ignored("press while \(phase.label)") }
        return await start(press, inForeground: true)
    }

    // MARK: Start

    private func start(_ press: Press, inForeground: Bool) async -> PressOutcome {
        phase = .starting
        let launch = SP1Process.startedAt
        state.write(
            RecordingStateSnapshot(
                phase: .starting, heartbeat: .now, ownerLaunch: launch, ownerPID: SP1Process.pid))
        Recovery.recoverOrphans(currentLaunch: launch)

        let permission = AVAudioApplication.shared.recordPermission
        let activitiesOn = activity.isEnabled
        let protection = ProtectionProbe.run(label: "press")
        SP1Log.record(
            "start.preflight",
            [
                "mic": Self.describe(permission), "liveActivities": String(activitiesOn),
                "foreground": String(inForeground), "protection": protection,
            ])

        if !inForeground && (permission != .granted || !activitiesOn) {
            reset()
            return .needsForeground(
                permission != .granted ? "microphone \(Self.describe(permission))" : "live activities off")
        }
        if permission == .undetermined && !SP1Process.isSimulator {
            let granted = await AVAudioApplication.requestRecordPermission()
            SP1Log.record("start.mic-requested", ["granted": String(granted)])
        }
        if AVAudioApplication.shared.recordPermission == .denied {
            reset()
            return .failed("microphone denied")
        }

        let id = UUID()
        let startedAt = Date()
        let url: URL
        do {
            url = try Manifests.begin(captureID: id, startedAt: startedAt, launch: launch)
        } catch {
            SP1Log.record("start.manifest-failed", ["capture": id.uuidString, "error": SP1Log.code(error)])
            reset()
            return .failed("manifest \(SP1Log.code(error))")
        }

        // The Live Activity starts with the recording (docs/architecture.md §14, rule 2).
        if activitiesOn {
            do {
                try activity.start(captureID: id, startedAt: startedAt)
            } catch {
                SP1Log.record("start.activity-failed", ["capture": id.uuidString, "error": "\(error)"])
                if !inForeground {
                    reset()
                    return .needsForeground("activity \(error)")
                }
            }
        }

        let receivedAt = press.receivedAt
        do {
            try recorder.start(url: url) { firstSample in
                SP1Log.record(
                    "recorder.first-buffer",
                    [
                        "capture": id.uuidString,
                        "fromPerformMs": SP1Log.ms(firstSample.timeIntervalSince(receivedAt)),
                        "fromProcessStartMs": launch.map { SP1Log.ms(firstSample.timeIntervalSince($0)) } ?? "?",
                        "firstSampleEpoch": SP1Log.epoch(firstSample),
                    ])
            }
        } catch {
            SP1Log.record("start.recorder-failed", ["capture": id.uuidString, "error": SP1Log.code(error)])
            await activity.end(
                captureID: id, .init(phase: .failed, startedAt: startedAt, reason: SP1Log.code(error)),
                dismissAfter: 4)
            Manifests.finish(captureID: id, outcome: "failed")
            reset()
            return .failed("recorder \(SP1Log.code(error))")
        }

        phase = .recording(id, startedAt)
        state.write(
            RecordingStateSnapshot(
                phase: .recording, captureID: id, startedAt: startedAt, heartbeat: .now, ownerLaunch: launch,
                ownerPID: SP1Process.pid))
        startHeartbeat(captureID: id, startedAt: startedAt)
        ControlCenter.shared.reloadAllControls()
        return .started(id)
    }

    // MARK: Stop

    private func stop(_ press: Press, captureID id: UUID, startedAt: Date) async -> PressOutcome {
        phase = .stopping
        heartbeat?.cancel()
        let summary = recorder.stop()
        let seconds = summary.sampleRate > 0 ? Double(summary.frames) / summary.sampleRate : 0
        SP1Log.record(
            "stop.recorded",
            [
                "capture": id.uuidString, "kind": press.kind.rawValue, "seconds": String(format: "%.1f", seconds),
                "bytes": String(summary.bytes),
                "pressToPressMs": SP1Log.ms(press.receivedAt.timeIntervalSince(startedAt)),
            ])
        Manifests.finish(captureID: id, outcome: "stored")
        await activity.end(captureID: id, .init(phase: .saved, startedAt: startedAt, reason: nil), dismissAfter: 3)
        reset()
        ControlCenter.shared.reloadAllControls()

        let work = PostStop.work(captureID: id, url: Manifests.audioURL(id))
        let mechanism = PostStopMechanism.current
        SP1Log.record("stop.post-mechanism", ["capture": id.uuidString, "mechanism": mechanism.rawValue])
        if mechanism == .longRunningIntent && press.kind != .inApp {
            return .stopped(work)
        }
        BackgroundRunners.run(work, with: mechanism)
        return .stopped(nil)
    }

    // MARK: Heartbeat and state

    private func startHeartbeat(captureID id: UUID, startedAt: Date) {
        heartbeat?.cancel()
        heartbeat = Task { [state, activity] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                var snapshot = state.read()
                snapshot.heartbeat = .now
                state.write(snapshot)
                tick += 1
                if tick % 5 == 0 {
                    await activity.update(captureID: id, .init(phase: .recording, startedAt: startedAt, reason: nil))
                }
            }
        }
    }

    private func reset() {
        phase = .idle
        state.write(.idle)
    }

    static func describe(_ permission: AVAudioApplication.recordPermission) -> String {
        switch permission {
        case .granted: "granted"
        case .denied: "denied"
        case .undetermined: "undetermined"
        @unknown default: "unknown"
        }
    }

    // MARK: Launch

    /// Runs at every launch, in front or not, before any intent: recovery and stray activities.
    func atLaunch() async {
        // `isProtectedDataAvailable` reads false inside `App.init`, even unlocked, so the seed
        // files are written here.
        ProtectionProbe.seedIfPossible()
        Recovery.recoverOrphans(currentLaunch: SP1Process.startedAt)
        let ended = await activity.endAll(except: nil)
        if ended > 0 { SP1Log.record("launch.activities-ended", ["count": String(ended)]) }
        let snapshot = state.read()
        if snapshot.phase != .idle && snapshot.ownerPID != SP1Process.pid {
            SP1Log.record(
                "launch.stale-state",
                ["phase": snapshot.phase.rawValue, "fresh": String(snapshot.isFresh(at: .now))])
            state.write(.idle)
        }
        ControlCenter.shared.reloadAllControls()
    }
}

/// The app's `IntentHost`, registered with the App Intents dependency manager at launch.
struct AppIntentHost: IntentHost {
    var isLive: Bool { true }

    func press(_ press: Press) async -> PressOutcome {
        await RecordingController.shared.press(press)
    }

    func startInForeground(_ press: Press) async -> PressOutcome {
        await RecordingController.shared.startInForeground(press)
    }
}
