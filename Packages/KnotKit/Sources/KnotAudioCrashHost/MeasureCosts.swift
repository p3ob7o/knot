import Foundation
import KnotAudio
import KnotCore
import Synchronization

/// `measure-costs`: what the sync every second and the heartbeat cost, on a recording of
/// injected audio at the pace of real time (docs/plan/WP-12.md, "report what that costs").
///
///     measure-costs --dir <folder> [--seconds 30] [--rate 16000] [--suite <defaults suite>]
///
/// The recording syncs its working file every second, as the app's does, through the drive's
/// file layer, and each sync of the working file is timed. With `--suite`, a test's own defaults
/// suite, which is removed at the end, the recorder writes its state there with a heartbeat every
/// second, and each write is timed. Prints `sync <n> us <microseconds>` and `heartbeat <n> us
/// <microseconds>` for each, then `syncs <count> median <us> p95 <us> max <us>`, and the same
/// for `heartbeats`, and last the CPU time of the whole process, `cpu user <ms> system <ms>
/// seconds <s>`.
func measureCosts(_ arguments: Arguments) async throws(HostError) {
    let seconds = try arguments.double("seconds", default: 30)
    let rate = try arguments.double("rate", default: 16_000)
    let syncs = Timings(name: "sync")
    let beats = Timings(name: "heartbeat")
    let suite = arguments.string("suite")
    let state: any RecordingStateStore
    if let suite {
        guard let defaults = UserDefaults(suiteName: suite) else { throw .usage("--suite cannot be used: \(suite)") }
        state = TimedStateStore(DefaultsRecordingStateStore(defaults: defaults), beats)
    } else {
        state = UnavailableRecordingStateStore()
    }
    defer { if let suite { removeSuite(named: suite) } }
    let recorder = LiveRecorder(
        locations: try locations(arguments), layer: TimedSyncLayer(PosixFileLayer(), syncs),
        input: try injected(arguments, pace: .realTime, frames: Int64(rate * seconds)), state: state)
    let request = RecordingRequest(
        captureID: CaptureID(uuid: UUID()), launchID: LaunchID(uuid: UUID()),
        origin: CaptureOrigin(source: .device(DeviceID(uuid: UUID())), surface: .control))
    let session: any RecordingSession
    do {
        session = try await recorder.start(request)
    } catch {
        throw .knot(error)
    }
    for await event in session.events {
        if case .durable(let frames) = event, frames >= Int64(rate * seconds) { break }
    }
    _ = await session.stop()
    do {
        try await recorder.removeWorkingFile(of: request.captureID)
    } catch {
        throw .knot(error)
    }
    syncs.report()
    beats.report()
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func milliseconds(_ time: timeval) -> Int { Int(time.tv_sec) * 1_000 + Int(time.tv_usec) / 1_000 }
    print("cpu user \(milliseconds(usage.ru_utime)) system \(milliseconds(usage.ru_stime)) seconds \(Int(seconds))")
}

/// Durations of one kind of call, in microseconds, printed as they come.
final class Timings: Sendable {
    let name: String
    private let values = Mutex<[Int64]>([])

    init(name: String) { self.name = name }

    func time<T>(_ body: () throws -> T) rethrows -> T {
        let began = ContinuousClock.now
        defer {
            let micros = nanoseconds(since: began) / 1_000
            let count = values.withLock { values in
                values.append(micros)
                return values.count
            }
            print("\(name) \(count) us \(micros)")
        }
        return try body()
    }

    func report() {
        let sorted = values.withLock { $0 }.sorted()
        guard !sorted.isEmpty else { return }
        func percentile(_ share: Double) -> Int64 {
            sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * share).rounded()))]
        }
        print("\(name)s \(sorted.count) median \(percentile(0.5)) p95 \(percentile(0.95)) max \(sorted.last ?? 0)")
    }
}

/// The drive's file layer, with each sync of a working file timed.
struct TimedSyncLayer: FileLayer {
    let base: any FileLayer
    let timings: Timings

    init(_ base: any FileLayer, _ timings: Timings) {
        self.base = base
        self.timings = timings
    }

    func syncFile(_ url: URL) throws(KnotError) {
        guard url.pathExtension == "caf" else { return try base.syncFile(url) }
        let result: Result<Void, KnotError> = timings.time {
            do throws(KnotError) {
                try base.syncFile(url)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }
    func createFolder(_ url: URL) throws(KnotError) { try base.createFolder(url) }
    func write(_ data: Data, to url: URL) throws(KnotError) { try base.write(data, to: url) }
    func rename(_ source: URL, to destination: URL) throws(KnotError) { try base.rename(source, to: destination) }
    func syncFolder(_ url: URL) throws(KnotError) { try base.syncFolder(url) }
    func remove(_ url: URL) throws(KnotError) { try base.remove(url) }
    func read(_ url: URL) throws(KnotError) -> Data { try base.read(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
    func entryKind(_ url: URL) -> FileEntryKind? { base.entryKind(url) }
    func contents(of folder: URL) throws(KnotError) -> [String] { try base.contents(of: folder) }
}

/// A recording state store with each write timed.
struct TimedStateStore: RecordingStateStore {
    let base: any RecordingStateStore
    let timings: Timings

    init(_ base: any RecordingStateStore, _ timings: Timings) {
        self.base = base
        self.timings = timings
    }

    func read() -> RecordingStateSnapshot { base.read() }
    func write(_ snapshot: RecordingStateSnapshot) { timings.time { base.write(snapshot) } }
}
