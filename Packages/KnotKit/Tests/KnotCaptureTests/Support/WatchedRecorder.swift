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
    /// While closed, every conversion waits at it.
    let conversionGate = Gate()
    /// While set, every removal of a working file fails with `write_failed`, as a death just
    /// before it would leave the file.
    let failRemovals = Mutex(false)
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
        await conversionGate.pass()
        return try await base.convert(recording)
    }

    func removeWorkingFile(of capture: CaptureID) async throws(KnotError) {
        if failRemovals.withLock({ $0 }) { throw KnotError.writeFailed.about(capture: capture) }
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

/// A gate that holds whoever passes it while closed. It starts open.
final class Gate: Sendable {
    private let state = Mutex<(closed: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

    func close() { state.withLock { $0.closed = true } }

    func open() {
        let waiting = state.withLock { state in
            state.closed = false
            defer { state.waiting = [] }
            return state.waiting
        }
        for waiter in waiting { waiter.resume() }
    }

    /// True while someone waits at the gate.
    var isHolding: Bool { state.withLock { !$0.waiting.isEmpty } }

    func pass() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let closed = state.withLock { state in
                if state.closed { state.waiting.append(waiter) }
                return state.closed
            }
            if !closed { waiter.resume() }
        }
    }
}
