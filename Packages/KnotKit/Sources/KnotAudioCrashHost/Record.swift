import AVFAudio
import Foundation
import KnotAudio

/// The injected clip a command records: `--source`, resampled to `--rate` when given.
func loadClip(_ arguments: Arguments) throws(HostError) -> InjectedAudioClip {
    do {
        let clip = try InjectedAudioClip.load(contentsOf: try arguments.url("source"))
        guard let rate = arguments.string("rate") else { return clip }
        guard let rate = Double(rate) else { throw HostError.usage("--rate takes a number") }
        return try clip.resampled(to: rate)
    } catch let error as WorkingFileError {
        throw .audio(error)
    } catch let error as HostError {
        throw error
    } catch {
        throw .usage("\(error)")
    }
}

/// How long each step of starting a recording took, in nanoseconds from the start.
struct StartTimings {
    /// The stand-in manifest is durably on disk. Zero when there was none.
    var manifest: Int64 = 0
    /// The working file exists, with its header, and its folder is synced.
    var created: Int64 = 0
    /// The first injected buffer is in the file. On injected audio this is the "live" moment.
    var live: Int64 = 0
    /// The first buffer has been synced to the drive.
    var firstSync: Int64 = 0

    var line: String {
        "start manifestNs \(manifest) createdNs \(created) liveNs \(live) firstSyncNs \(firstSync)"
    }
}

/// Starts a recording of `clip` into a new working file: an optional stand-in manifest first,
/// then the file, then the first buffer, then the first sync.
@MainActor
func startRecording(
    clip: InjectedAudioClip,
    format: WorkingFileFormat,
    url: URL,
    manifest: URL?,
    chunkFrames: Int
) throws(HostError) -> (writer: any WorkingFileWriter, timings: StartTimings) {
    var timings = StartTimings()
    let start = ContinuousClock.now
    if let manifest {
        try StandInManifest.write(to: manifest)
        timings.manifest = nanoseconds(since: start)
    }
    do {
        let writer = try WorkingFile.makeWriter(format: format, url: url, sampleRate: clip.sampleRate)
        timings.created = nanoseconds(since: start)
        try writer.append(clip.buffer(from: 0, count: chunkFrames))
        timings.live = nanoseconds(since: start)
        try writer.syncToDrive()
        timings.firstSync = nanoseconds(since: start)
        return (writer, timings)
    } catch {
        throw .audio(error)
    }
}

/// `record`: records injected audio into a working file at the pace of real time, reporting
/// each step on standard output and in a witness file, until `--seconds` of audio or a kill.
///
///     record --format caf|fmp4 --source <audio> --out <file> --witness <file>
///            [--rate <Hz>] [--seconds 30] [--chunk-ms 100] [--sync-ms 1000] [--unpaced]
///            [--manifest <file>]
@MainActor
func record(_ arguments: Arguments) async throws(HostError) {
    let format = try arguments.format()
    let clip = try loadClip(arguments)
    let out = try arguments.url("out")
    let witness = try Witness(url: try arguments.url("witness"))
    // The pid comes after the clip is loaded, so that an early kill lands while the file and
    // its header are being made.
    print("pid \(getpid())")
    let seconds = try arguments.double("seconds", default: 30)
    let chunkFrames = Int(clip.sampleRate * (try arguments.double("chunk-ms", default: 100)) / 1000)
    let syncFrames = Int64(clip.sampleRate * (try arguments.double("sync-ms", default: 1000)) / 1000)
    let paced = !arguments.flag("unpaced")
    let totalFrames = Int64(clip.sampleRate * seconds)

    let (writer, timings) = try startRecording(
        clip: clip, format: format, url: out, manifest: arguments.string("manifest").map(URL.init(fileURLWithPath:)),
        chunkFrames: chunkFrames)
    let live = ContinuousClock.now
    var appended = Int64(chunkFrames)
    var durable = appended
    witness.record(appended: appended, durable: durable)
    print(timings.line)
    print("live")

    let chunk = Duration.seconds(Double(chunkFrames) / clip.sampleRate)
    var nextSync = syncFrames
    var chunks = 1
    do {
        while appended < totalFrames {
            if paced {
                // A tap delivers one buffer per buffer's length of audio.
                try? await Task.sleep(until: live + chunk * chunks, clock: .continuous)
            }
            let count = Int(min(Int64(chunkFrames), totalFrames - appended))
            try writer.append(clip.buffer(from: appended, count: count))
            appended += Int64(count)
            chunks += 1
            witness.record(appended: appended, durable: durable)
            print("appended \(appended)")
            if appended >= nextSync {
                let syncStart = ContinuousClock.now
                try writer.syncToDrive()
                durable = appended
                witness.record(appended: appended, durable: durable)
                print("durable \(durable) syncNs \(nanoseconds(since: syncStart))")
                nextSync += syncFrames
            }
        }
        try await writer.finish()
    } catch {
        throw .audio(error)
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
    print("finished \(appended) bytes \(size)")
}
