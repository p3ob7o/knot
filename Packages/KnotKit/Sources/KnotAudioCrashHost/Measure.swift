import AVFAudio
import Foundation
import KnotAudio

/// `measure-start`: starts `--runs` recordings one after another in this process, each with
/// one buffer and one sync, and prints how long each step took. The first run is the first
/// recording of a fresh process; the later ones are warm.
///
///     measure-start --format caf|fmp4 --source <audio> --dir <folder> [--runs 20]
///                   [--rate <Hz>] [--chunk-ms 100] [--manifest]
@MainActor
func measureStart(_ arguments: Arguments) async throws(HostError) {
    let format = try arguments.format()
    let clip = try loadClip(arguments)
    let folder = try arguments.url("dir")
    let runs = try arguments.int("runs", default: 20)
    let chunkFrames = Int(clip.sampleRate * (try arguments.double("chunk-ms", default: 100)) / 1000)
    for run in 1...runs {
        let name = "start-\(getpid())-\(run)"
        let url = folder.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
        let manifest = arguments.flag("manifest") ? folder.appendingPathComponent(name + ".json") : nil
        let (writer, timings) = try startRecording(
            clip: clip, format: format, url: url, manifest: manifest, chunkFrames: chunkFrames)
        do {
            try await writer.finish()
        } catch {
            throw .audio(error)
        }
        print("run \(run) \(timings.line)")
        try? FileManager.default.removeItem(at: url)
        if let manifest { try? FileManager.default.removeItem(at: manifest) }
    }
}

/// `measure-size`: records `--seconds` of audio as fast as it can, syncing once a second of
/// audio, and prints the working file's size per minute and what the syncs cost. With
/// `--convert` it also makes the stored copy, AAC mono in `.m4a`, and prints its size.
///
///     measure-size --format caf|fmp4 --source <audio> --dir <folder> [--rate <Hz>]
///                  [--seconds 60] [--convert] [--bit-rate <bit/s>]
@MainActor
func measureSize(_ arguments: Arguments) async throws(HostError) {
    let format = try arguments.format()
    let clip = try loadClip(arguments)
    let folder = try arguments.url("dir")
    let seconds = try arguments.double("seconds", default: 60)
    let chunkFrames = Int(clip.sampleRate / 10)
    let syncFrames = Int64(clip.sampleRate)
    let totalFrames = Int64(clip.sampleRate * seconds)
    let name = "size-\(getpid())-\(format.rawValue)-\(Int(clip.sampleRate))"
    let url = folder.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
    var syncs: [Int64] = []
    do {
        let writer = try WorkingFile.makeWriter(format: format, url: url, sampleRate: clip.sampleRate)
        var appended: Int64 = 0
        var nextSync = syncFrames
        while appended < totalFrames {
            let count = Int(min(Int64(chunkFrames), totalFrames - appended))
            try writer.append(clip.buffer(from: appended, count: count))
            appended += Int64(count)
            if appended >= nextSync {
                let start = ContinuousClock.now
                try writer.syncToDrive()
                syncs.append(nanoseconds(since: start))
                nextSync += syncFrames
            }
        }
        try await writer.finish()
    } catch {
        throw .audio(error)
    }
    let bytes = fileSize(url)
    print(
        "size format \(format.rawValue) rate \(Int(clip.sampleRate)) seconds \(seconds) bytes \(bytes) "
            + "bytesPerMinute \(Int(Double(bytes) * 60 / seconds))")
    let sorted = syncs.sorted()
    if !sorted.isEmpty {
        print(
            "sync count \(sorted.count) medianUs \(percentile(sorted, 0.5) / 1000) "
                + "p95Us \(percentile(sorted, 0.95) / 1000) maxUs \(sorted.last! / 1000)")
    }
    if arguments.flag("convert") {
        let copy = folder.appendingPathComponent(name + "-copy.m4a")
        let start = ContinuousClock.now
        let bitRate = try arguments.int("bit-rate", default: StoredCopy.bitRate(forSampleRate: clip.sampleRate))
        try convertToAAC(from: url, to: copy, bitRate: bitRate)
        let elapsed = nanoseconds(since: start)
        let copyBytes = fileSize(copy)
        print(
            "converted bitRate \(bitRate) bytes \(copyBytes) bytesPerMinute \(Int(Double(copyBytes) * 60 / seconds)) "
                + "ms \(elapsed / 1_000_000)")
        try? FileManager.default.removeItem(at: copy)
    }
    try? FileManager.default.removeItem(at: url)
}

/// Converts a working file to AAC mono in `.m4a`, the stored copy (docs/architecture.md §8),
/// through `AVAudioFile`, which is available on all four platforms.
func convertToAAC(from source: URL, to destination: URL, bitRate: Int) throws(HostError) {
    do {
        let input = try AVAudioFile(forReading: source)
        let output = try AVAudioFile(
            forWriting: destination,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: input.fileFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate,
            ],
            commonFormat: input.processingFormat.commonFormat,
            interleaved: input.processingFormat.isInterleaved)
        while input.framePosition < input.length {
            let count = AVAudioFrameCount(min(Int64(32_768), input.length - input.framePosition))
            let buffer = try input.read(frameCount: count)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
        output.close()
    } catch {
        throw .system("convert", Int32(truncatingIfNeeded: (error as NSError).code))
    }
}

func fileSize(_ url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
}

/// The value at `fraction` of a sorted array, by the nearest-rank method.
func percentile(_ sorted: [Int64], _ fraction: Double) -> Int64 {
    let rank = Int((fraction * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank, 1), sorted.count) - 1]
}
