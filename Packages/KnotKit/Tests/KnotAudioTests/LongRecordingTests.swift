import AVFAudio
import Foundation
import KnotCore
import KnotTestSupport
import Testing

@testable import KnotAudio

/// A recording as long as v1 allows.
@Suite struct LongRecordingTests {
    /// Thirty minutes of injected audio in, the same frames out: the recording ends by itself at
    /// its limit with every frame it was fed, each one the audio injected, and its converted copy
    /// holds as many. The audio is fed as fast as the recorder takes it, in buffers of 300 ms.
    @Test("recorder-thirty-minutes-frames-in-and-out", .tags(.named))
    func thirtyMinutesInAreThirtyMinutesOut() async throws {
        let folder = try ScratchFolder()
        let rate = 16_000.0
        let frames = Int64(rate * Limits.longestRecording)
        let recorder = LiveRecorder(
            locations: folder.locations,
            input: InjectedAudio(sampleRate: rate, framesPerBuffer: 4_800, pace: .unpaced, frames: frames),
            settings: LiveRecorder.Settings(syncInterval: .milliseconds(200)))
        let request = request()
        #expect(request.limit == .seconds(Limits.longestRecording))
        let session = try await recorder.start(request)
        guard case .ended(let audio)? = await allEvents(of: session).last else {
            Issue.record("The recording did not end by itself at its limit.")
            return
        }
        let working = folder.locations.recordingAudio(request.captureID, format: .caf)
        #expect(audio.ending == .limitReached && audio.frames == frames && audio.workingFile == working, "\(audio)")
        let samples = try #require(WorkingFileReader.samples(of: working))
        #expect(Int64(samples.count) == frames)
        let first = samples.indices.first { samples[$0] != SyntheticAudio.sample(at: Int64($0)) }
        #expect(first == nil, "The first frame that differs from the audio injected: \(first ?? -1).")
        let converted = try await recorder.convert(audio)
        #expect(try AVAudioFile(forReading: converted.file).length == frames)
        #expect(converted.duration == .seconds(Limits.longestRecording))
    }
}
