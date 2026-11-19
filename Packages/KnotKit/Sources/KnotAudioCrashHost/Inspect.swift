import Foundation
import KnotAudio

/// `inspect`: reads a working file back, as recovery would after a crash, and prints what it
/// holds. With `--source`, it also counts how many frames from the start equal the injected
/// clip, looped as `record` loops it.
///
///     inspect --path <file> [--source <audio> [--rate <Hz>]]
///
/// Prints one line of keys and values:
/// `result missing|readable|unreadable frames <n> announced <n> rate <Hz> bytes <n> match <n>
/// error <domain>:<code> assetFrames <n>`. `frames` is what `AVAudioFile` reads, `match` how
/// many of those equal the injected audio, and `assetFrames` what `AVAssetReader` reads, for
/// an `.m4a` file on a platform that has it. A value that does not apply is -1.
func inspect(_ arguments: Arguments) async throws(HostError) {
    let url = try arguments.url("path")
    guard FileManager.default.fileExists(atPath: url.path) else {
        print("result missing frames -1 announced -1 rate 0 bytes 0 match -1 error - assetFrames -1")
        return
    }
    var line = InspectionLine(bytes: fileSize(url))
    do {
        let contents = try WorkingFileReader.read(url, keepingSamples: arguments.string("source") != nil)
        line.result = "readable"
        line.frames = contents.frames
        line.announced = contents.announcedFrames
        line.rate = Int(contents.sampleRate)
        if let samples = contents.samples, arguments.string("source") != nil {
            let clip = try loadClip(arguments)
            line.match = 0
            if clip.sampleRate == contents.sampleRate {
                for (position, sample) in samples.enumerated() {
                    guard sample == clip.sample(at: Int64(position)) else { break }
                    line.match += 1
                }
            }
        }
    } catch let error as WorkingFileError {
        line.result = "unreadable"
        line.error = describe(error)
    } catch {
        throw error as? HostError ?? .usage("\(error)")
    }
    #if !os(watchOS)
        if url.pathExtension == "m4a" {
            do {
                let contents = try await WorkingFileReader.readWithAssetReader(url)
                line.assetFrames = contents.frames
                if line.rate == 0 { line.rate = Int(contents.sampleRate) }
            } catch {
                line.assetError = describe(error)
            }
        }
    #endif
    print(line.text)
}

private struct InspectionLine {
    var result = "readable"
    var frames: Int64 = -1
    var announced: Int64 = -1
    var rate = 0
    let bytes: Int
    var match: Int64 = -1
    var error = "-"
    var assetFrames: Int64 = -1
    var assetError = "-"

    var text: String {
        "result \(result) frames \(frames) announced \(announced) rate \(rate) bytes \(bytes) match \(match) "
            + "error \(error) assetFrames \(assetFrames) assetError \(assetError)"
    }
}

/// A short form of an error for the crash host's output: the system's code if there is one,
/// else the case.
private func describe(_ error: WorkingFileError) -> String {
    switch error {
    case .unreadable(let code), .writeFailed(let code), .cannotCreate(let code):
        "\(code.domain.rawValue):\(code.code)"
    case .syncFailed(let errno): "errno:\(errno)"
    default: "\(error)"
    }
}

/// `render`: writes the injected clip, resampled to `--rate`, into a finished CAF file, so that
/// a recording and the reading of it use the very same samples.
///
///     render --source <audio> --rate <Hz> --out <file.caf>
@MainActor
func render(_ arguments: Arguments) async throws(HostError) {
    let clip = try loadClip(arguments)
    do {
        let writer = try WorkingFile.makeWriter(
            format: .caf, url: try arguments.url("out"), sampleRate: clip.sampleRate)
        try writer.append(clip.buffer(from: 0, count: clip.frameCount))
        try await writer.finish()
    } catch let error as WorkingFileError {
        throw .audio(error)
    } catch {
        throw .usage("\(error)")
    }
    print("rendered \(clip.frameCount) rate \(Int(clip.sampleRate))")
}
