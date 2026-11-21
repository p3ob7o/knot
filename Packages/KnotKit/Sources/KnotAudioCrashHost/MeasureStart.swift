import Foundation
import KnotAudio
import KnotCore

/// `measure-start`: times the live recorder's start on injected audio, from the call to the
/// moment it returns live: the manifest written and synced, the working file made and its
/// folder synced, and the input running.
///
///     measure-start --dir <folder> [--runs 20] [--rate 16000]
///
/// The first start of the process is cold, the rest are warm. Prints one line per start,
/// `start <n> <capture> liveUs <microseconds>`, then `cold <us> warm median <us> p95 <us>`. Each recording
/// is stopped and its files removed before the next one starts.
func measureStart(_ arguments: Arguments) async throws(HostError) {
    let runs = try arguments.int("runs", default: 20)
    let recorder = LiveRecorder(
        locations: try locations(arguments), input: try injected(arguments, pace: .realTime, frames: nil))
    let launch = LaunchID(uuid: UUID())
    var times: [Int64] = []
    for run in 1...max(runs, 1) {
        let request = RecordingRequest(
            captureID: CaptureID(uuid: UUID()), launchID: launch,
            origin: CaptureOrigin(source: .device(DeviceID(uuid: UUID())), surface: .control))
        let began = ContinuousClock.now
        let session: any RecordingSession
        do {
            session = try await recorder.start(request)
        } catch {
            throw .knot(error)
        }
        let elapsed = ContinuousClock.now - began
        let micros = elapsed.components.seconds * 1_000_000 + elapsed.components.attoseconds / 1_000_000_000_000
        times.append(micros)
        print("start \(run) \(request.captureID) liveUs \(micros)")
        _ = await session.stop()
        do {
            try await recorder.removeWorkingFile(of: request.captureID)
        } catch {
            throw .knot(error)
        }
    }
    let warm = times.dropFirst().sorted()
    func percentile(_ sorted: [Int64], _ share: Double) -> Int64 {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * share).rounded()))]
    }
    print("cold \(times[0]) warm median \(percentile(Array(warm), 0.5)) p95 \(percentile(Array(warm), 0.95))")
}
