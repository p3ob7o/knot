import Foundation
import KnotAudio
import KnotCore
import Synchronization

/// The store a command works in: `StoreLocations` for the folder `--dir` names, which it holds
/// whole, as package tests do.
func locations(_ arguments: Arguments) throws(HostError) -> StoreLocations {
    let folder = try arguments.url("dir")
    // The store's root goes inside it, and its parent must exist, as an app's container does.
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return StoreLocations.testing(root: folder)
}

/// The injected audio a command records: the synthetic signal, in 100 ms buffers, at `--rate`.
/// With `ends`, the input ends by itself, as lost, once its frames are delivered.
func injected(
    _ arguments: Arguments, pace: InjectedAudio.Pace, frames: Int64?, ends: Bool = false,
    delivered: (@Sendable (Int64) -> Void)? = nil
) throws(HostError) -> InjectedAudio {
    let rate = try arguments.double("rate", default: 16_000)
    return InjectedAudio(
        sampleRate: rate, framesPerBuffer: Int(rate / 10), pace: pace, frames: frames,
        ending: ends ? .ends(.lost) : .runsDry, delivered: delivered)
}

/// The status of `record` when the recording ended before it was stopped.
let endedEarlyStatus: Int32 = 3

/// `record`: records injected audio with the live recorder, at the pace of real time, until
/// `--seconds` of audio or a kill, reporting each step on standard output and in a witness file.
///
///     record --dir <folder> --witness <file> [--rate 16000] [--seconds 60] [--sync-ms 1000]
///            [--ends-after <frames>]
///
/// Prints `pid <n>`, then `capture <id>`, and every later line names the capture after its first
/// word: `live <id>` once the start has returned, `durable <id> <frames>` after each sync, and at
/// the end `stopped <id> frames <n> ending <ending>`. A recording that ends before it is stopped,
/// by itself or because its input ends after `--ends-after` frames, ends the command at once with
/// `ended-early <id> frames <n> ending <ending>`, and status 3. The gate reads these lines.
func record(_ arguments: Arguments) async throws(HostError) {
    let witness = try Witness(url: try arguments.url("witness"))
    let rate = try arguments.double("rate", default: 16_000)
    let endsAfter = arguments.string("ends-after").flatMap { Int64($0) }
    let seconds = try arguments.double("seconds", default: 60)
    let total = endsAfter ?? Int64(rate * seconds)
    let interval = Duration.milliseconds(try arguments.int("sync-ms", default: 1000))
    let taken = Counter()
    let ended = Counter()
    let input = try injected(arguments, pace: .realTime, frames: total, ends: endsAfter != nil) { frames in
        witness.taken(frames)
        taken.set(frames)
    }
    let recorder = LiveRecorder(
        locations: try locations(arguments), input: input, settings: LiveRecorder.Settings(syncInterval: interval))
    let capture = CaptureID(uuid: UUID())
    // The pid first, so that an early kill lands while the manifest and the file are made.
    print("pid \(getpid())")
    print("capture \(capture)")
    let request = RecordingRequest(
        captureID: capture, launchID: LaunchID(uuid: UUID()),
        origin: CaptureOrigin(source: .device(DeviceID(uuid: UUID())), surface: .control))
    let session: any RecordingSession
    do {
        session = try await recorder.start(request)
    } catch {
        throw .knot(error)
    }
    print("live \(capture)")
    // Stops once the injected audio has all been taken, unless a kill comes first, or the
    // recording ends before that by itself.
    let stopping = Task {
        while taken.value < total, ended.value == 0 { try? await Task.sleep(for: .milliseconds(20)) }
        return await session.stop()
    }
    for await event in session.events {
        switch event {
        case .durable(let frames):
            witness.durable(frames)
            print("durable \(capture) \(frames)")
        case .ended(let audio):
            if audio.ending.endedByItself { ended.set(1) }
        case .level:
            break
        }
    }
    let audio = await stopping.value
    guard !audio.ending.endedByItself else {
        print("ended-early \(capture) frames \(audio.frames) ending \(audio.ending.rawValue)")
        exit(endedEarlyStatus)
    }
    print("stopped \(capture) frames \(audio.frames) ending \(audio.ending.rawValue)")
}

/// A count that one task sets and another reads.
final class Counter: Sendable {
    private let state = Mutex<Int64>(0)
    var value: Int64 { state.withLock { $0 } }
    func set(_ value: Int64) { state.withLock { $0 = value } }
}

/// `recover`: what recovery finds in `--dir` after a death, from a launch of its own, with every
/// frame of each working file checked against the synthetic signal.
///
///     recover --dir <folder>
///
/// Prints one line for each orphan, `orphan <id> frames <n> rate <Hz> ending <ending>
/// match <n> manifest <readable|unreadable> file <yes|no>`, where `match` counts the frames from
/// the start that equal the injected audio, then `orphans <count>`.
func recover(_ arguments: Arguments) async throws(HostError) {
    let locations = try locations(arguments)
    let recorder = LiveRecorder(locations: locations, input: try injected(arguments, pace: .unpaced, frames: 0))
    let orphans: [RecordedAudio]
    do {
        orphans = try await recorder.recoverOrphans(currentLaunch: LaunchID(uuid: UUID()))
    } catch {
        throw .knot(error)
    }
    for orphan in orphans {
        var match = -1
        if let file = orphan.workingFile, let samples = WorkingFileReader.samples(of: file) {
            match = 0
            for (frame, sample) in samples.enumerated() {
                guard sample == SyntheticAudio.sample(at: Int64(frame)) else { break }
                match += 1
            }
        }
        let manifest = (try? Data(contentsOf: locations.recordingManifest(orphan.captureID)))
            .flatMap { try? CaptureManifest.decode($0) }
        let readable = manifest?.captureID == orphan.captureID ? "readable" : "unreadable"
        print(
            "orphan \(orphan.captureID) frames \(orphan.frames) rate \(Int(orphan.sampleRate)) "
                + "ending \(orphan.ending.rawValue) match \(match) manifest \(readable) "
                + "file \(orphan.workingFile == nil ? "no" : "yes")")
    }
    print("orphans \(orphans.count)")
}
