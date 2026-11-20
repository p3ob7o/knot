import Foundation
import KnotCapture
import KnotCore
import KnotFakes
import Synchronization

/// The scripted recorder, with a record of the calls it was given, in order, and a conversion
/// that can take real time, as a long recording's does.
final class WatchedRecorder: Recorder, Sendable {
    let base: ScriptedRecorder
    /// How long each conversion takes before it answers.
    let conversionDelay = Mutex<Duration>(.zero)
    private let log = Mutex<[String]>([])

    init(_ base: ScriptedRecorder) { self.base = base }

    /// The calls so far: "start", "convert", in the order they began.
    var calls: [String] { log.withLock { $0 } }
    var conversions: Int { calls.filter { $0 == "convert" }.count }

    func prepare() async { await base.prepare() }

    func start(_ request: RecordingRequest) async throws(KnotError) -> any RecordingSession {
        log.withLock { $0.append("start") }
        return try await base.start(request)
    }

    func recoverOrphans(currentLaunch: LaunchID) async throws(KnotError) -> [RecordedAudio] {
        try await base.recoverOrphans(currentLaunch: currentLaunch)
    }

    func convert(_ recording: RecordedAudio) async throws(KnotError) -> ConvertedRecording {
        log.withLock { $0.append("convert") }
        let delay = conversionDelay.withLock { $0 }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return try await base.convert(recording)
    }

    func removeWorkingFile(of capture: CaptureID) async throws(KnotError) {
        try await base.removeWorkingFile(of: capture)
    }
}

extension Rig {
    /// An engine over this rig's parts with `recorder` in place of the scripted one.
    func engine(recorder: any Recorder) -> BoundedEngine {
        BoundedEngine(
            StandardCaptureEngine(
                notes: notes, assets: assets, recorder: recorder, queue: queue, clock: clock, ids: ids,
                deviceID: deviceID, launchID: launchID, locations: locations, layer: layer, deadline: .patient,
                ingest: ingest, log: KnotLog(.capture, sink: logs)))
    }
}
