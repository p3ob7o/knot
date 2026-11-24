import AVFAudio
import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotAudio

/// A recording's level peaks, beside it, and the cues the recorder gives.
@Suite struct PeaksAndCuesTests {
    /// The recorder writes a recording's peaks beside it, in the format of `RecordingPeaks`: one
    /// value for each 50 ms of the file's frames, the largest absolute sample of its stretch, the
    /// last stretch's too, which ends part way. They are the audio the file holds and nothing
    /// else, and removing the working file takes them first.
    @Test func aRecordingWritesItsPeaksBesideIt() async throws {
        let folder = try ScratchFolder()
        let frames = 16_000 * 2 + 400
        let live = recorder(folder.locations, input: injected(frames: Int64(frames)))
        let request = request()
        let session = try await live.start(request)
        await durable(atLeast: Int64(frames), of: session)
        let audio = await session.stop()
        #expect(audio.frames == Int64(frames))
        let url = folder.locations.recordingPeaks(request.captureID)
        let peaks = try #require(RecordingPeaks(reading: try Data(contentsOf: url)))
        #expect(peaks.framesPerValue == 800)
        #expect(peaks.values == Self.expectedPeaks(synthetic(frames), framesPerValue: 800))
        #expect(peaks.values.count == 41, "40 whole stretches and the last one's part")
        #expect(peaks.held(toFrames: audio.frames) == peaks.values)
        try await live.removeWorkingFile(of: request.captureID)
        #expect(!exists(url))
    }

    /// The peaks file is made in place, never through a temporary beside it, which a kill could
    /// leave in `Recording/`: a file already at its name keeps its inode and holds the new peaks,
    /// where a write through a temporary would put a new file in its place. Nothing else is left
    /// in the folder but the recording's own files.
    @Test func thePeaksFileIsMadeInPlace() async throws {
        let folder = try ScratchFolder()
        let request = request()
        let url = folder.locations.recordingPeaks(request.captureID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: url)
        let before = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
        let live = recorder(folder.locations, input: injected(frames: 16_000))
        let session = try await live.start(request)
        await durable(atLeast: 16_000, of: session)
        _ = await session.stop()
        let after = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
        #expect(after == before, "The peaks file was put in place of the one at its name.")
        let peaks = try #require(RecordingPeaks(reading: try Data(contentsOf: url)))
        #expect(peaks.values == Self.expectedPeaks(synthetic(16_000), framesPerValue: 800))
        let capture = folder.locations.recordingManifest(request.captureID).deletingPathExtension().lastPathComponent
        let names = recordingFolder(folder.locations)
        #expect(names.allSatisfy { $0.hasPrefix(capture + ".") }, "Only the recording's files: \(names)")
    }

    /// The peaks go first, before the working file and the manifest, whether the working file is
    /// removed or the recording discarded: a removal that fails on the working file has taken the
    /// peaks already, and a peaks file never outlives its recording.
    @Test(arguments: [false, true])
    func thePeaksGoFirst(discarded: Bool) async throws {
        let folder = try ScratchFolder()
        let layer = RemovalLayer(refusing: "caf")
        let live = LiveRecorder(
            locations: folder.locations, layer: layer, input: injected(frames: 16_000),
            settings: LiveRecorder.Settings(syncInterval: .milliseconds(20)))
        let request = request()
        let session = try await live.start(request)
        await durable(atLeast: 16_000, of: session)
        if discarded {
            await session.discard()
        } else {
            _ = await session.stop()
            await #expect(throws: KnotError.self) { try await live.removeWorkingFile(of: request.captureID) }
        }
        #expect(layer.removed.prefix(2) == ["peaks", "caf"], "\(layer.removed)")
        #expect(!exists(folder.locations.recordingPeaks(request.captureID)))
        #expect(exists(folder.locations.recordingAudio(request.captureID, format: .caf)), "The refused file stays.")
    }

    /// A peaks file that cannot be made leaves the recording whole: it records and stops as
    /// before, every frame in its file, and says once that it gave up its peaks, with its capture
    /// ID and no value.
    @Test func aRecordingWhosePeaksCannotBeWrittenGoesOn() async throws {
        let folder = try ScratchFolder()
        let kept = KeptLog()
        let live = LiveRecorder(
            locations: folder.locations, input: injected(frames: 16_000),
            settings: LiveRecorder.Settings(syncInterval: .milliseconds(20)), log: KnotLog(.audio, sink: kept))
        let request = request()
        // A folder where the peaks file would go: it cannot be made.
        let url = folder.locations.recordingPeaks(request.captureID)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let session = try await live.start(request)
        await durable(atLeast: 16_000, of: session)
        let audio = await session.stop()
        #expect(audio.ending == .stopped && audio.frames == 16_000, "\(audio)")
        #expect(WorkingFileReader.samples(of: try #require(audio.workingFile)) == synthetic(16_000))
        let lines = kept.lines("recording_peaks_given_up")
        #expect(lines.count == 1 && lines.first?.fields.contains(.capture(request.captureID)) == true, "\(lines)")
    }

    /// The audio that arrives while the live cue plays goes nowhere: not into the file, the live
    /// audio, the levels or the peaks. Here 250 ms at 16 kHz, 4,000 frames: two buffers whole and
    /// half the third. The recording holds the rest, from frame 4,000 of the injected audio, and
    /// its length is what the file says.
    @Test func theLiveCuesGapGoesNowhere() async throws {
        let folder = try ScratchFolder()
        let cues = RecordingCueEmitter()
        let live = LiveRecorder(
            locations: folder.locations, input: injected(frames: 16_000),
            settings: LiveRecorder.Settings(syncInterval: .milliseconds(20), liveCueGap: .milliseconds(250)),
            cues: cues)
        let request = request()
        let session = try await live.start(request)
        // One reader of the events: the levels, and the durable count to wait for.
        let seen = Mutex<(levels: [Float], durable: Int64)>(([], 0))
        let reading = Task {
            for await event in session.events {
                switch event {
                case .level(let peak, _): seen.withLock { $0.levels.append(peak) }
                case .durable(let frames): seen.withLock { $0.durable = frames }
                case .ended: break
                }
            }
        }
        #expect(await SuiteWait.until("12,000 durable frames") { seen.withLock { $0.durable } >= 12_000 })
        let audio = await session.stop()
        await reading.value
        let levels = seen.withLock { $0.levels }
        var heard: [Float] = []
        for await chunk in session.liveAudio { heard += chunk.samples }
        let kept = Array(synthetic(16_000)[4_000...])
        let working = try #require(audio.workingFile)
        #expect(audio.frames == 12_000 && WorkingFileReader.samples(of: working) == kept)
        #expect(heard == kept.map { Float($0) / 32_768 }, "The live audio starts after the gap.")
        let firstPeak = kept[..<800].map { abs(Float($0) / 32_768) }.max()
        #expect(levels.count == 8 && levels.first == firstPeak, "\(levels)")
        let peaks = try #require(
            RecordingPeaks(reading: try Data(contentsOf: folder.locations.recordingPeaks(request.captureID))))
        #expect(peaks.values == Self.expectedPeaks(kept, framesPerValue: 800), "The peaks start after the gap.")
        #expect(await cuesHandedOver(by: live, to: cues, refusing: request) == [.recordingLive])
    }

    /// The gap is held between nothing and half a second, so that a wrong setting never eats
    /// the start of a sentence: two seconds drop 8,000 frames at 16 kHz, no more.
    @Test func theLiveCuesGapIsHeldToHalfASecond() async throws {
        let held = [-1.0, 0, 0.3, 0.5, 2].map {
            LiveRecorder.Settings(liveCueGap: .seconds($0)).heldLiveCueGap
        }
        #expect(held == [.zero, .zero, .milliseconds(300), .milliseconds(500), .milliseconds(500)])
        let folder = try ScratchFolder()
        let live = LiveRecorder(
            locations: folder.locations, input: injected(frames: 16_000),
            settings: LiveRecorder.Settings(syncInterval: .milliseconds(20), liveCueGap: .seconds(2)))
        let session = try await live.start(request())
        await durable(atLeast: 8_000, of: session)
        let audio = await session.stop()
        #expect(audio.frames == 8_000)
        #expect(WorkingFileReader.samples(of: try #require(audio.workingFile)) == Array(synthetic(16_000)[8_000...]))
    }

    /// The cues are handed to the emitter on the recorder's own queue, never on the audio's
    /// thread or the caller's, and nothing waits for them: with an emitter that holds its first
    /// cue, the start returns live, the audio is written and the stop returns. The cues then
    /// come in order. The stopped-early cue is the last one given, so the wait is for it: a
    /// recorder that gave no live cue is told at once.
    @Test func noRecordingWaitsForItsCues() async throws {
        let folder = try ScratchFolder()
        let cues = HeldCues()
        let live = LiveRecorder(
            locations: folder.locations, input: injected(frames: 16_000, ending: .ends(.interrupted)),
            settings: LiveRecorder.Settings(syncInterval: .milliseconds(20)), cues: cues)
        let session = try await live.start(request())
        guard case .ended(let audio)? = await allEvents(of: session).last else {
            Issue.record("The recording did not end by itself.")
            return
        }
        #expect(audio.ending == .interrupted && audio.frames == 16_000, "\(audio)")
        #expect(cues.played.isEmpty, "The first cue is still held.")
        cues.release()
        #expect(await SuiteWait.until("the stopped-early cue") { cues.played.contains { $0.cue == .stoppedEarly } })
        cues.hooks.check()
        #expect(cues.played.map(\.cue) == [.recordingLive, .stoppedEarly])
        #expect(cues.played.allSatisfy { $0.queue == "knot.audio.cues" }, "\(cues.played)")
    }

    /// A start whose input fails after it opened, as the engine's start does, gives no live cue
    /// and gives the could-not-start cue: the live cue waits for the input to have started
    /// (finding 5 of the review).
    @Test func aStartWhoseInputFailsAfterItOpenedIsNotLive() async throws {
        let folder = try ScratchFolder()
        let cues = RecordingCueEmitter()
        let live = LiveRecorder(
            locations: folder.locations, input: injected(startFailure: .audioSessionBusy),
            settings: LiveRecorder.Settings(syncInterval: .milliseconds(20)), cues: cues)
        await #expect(throws: KnotError.self) { _ = try await live.start(request()) }
        // Handed to the cue queue before the start threw, after any live cue it gave.
        #expect(await SuiteWait.until("the could-not-start cue") { cues.cues.contains(.couldNotStart) })
        #expect(cues.cues == [.couldNotStart])
    }

    /// An ending that begins inside the start, here a buffer the file cannot take, handed over by
    /// the tap while the engine starts: the start gives no live cue and publishes no "recording",
    /// the phases never step back, and the stopped-early cue is the recording's one cue (finding
    /// 10 of the review). The hook hands the buffer over inside the engine's start, so the order
    /// rests on no time.
    @Test func anEndingInsideTheStartIsNeverLive() async throws {
        let suite = try TestSuite()
        defer { suite.remove() }
        let store = WatchedStateStore(DefaultsRecordingStateStore(defaults: suite.defaults))
        let cues = RecordingCueEmitter()
        let (input, engine, _) = InterruptionTests.standInMicrophone(InputShape(sampleRate: 48_000, channels: 1))
        let wrongRate = try #require(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false))
        let buffer = try #require(HardwareInputTests.silence(wrongRate))
        engine.whenAt(.starting) { engine in engine.deliver(buffer) }
        let folder = try ScratchFolder()
        let live = LiveRecorder(
            locations: folder.locations, input: input, settings: LiveRecorder.Settings(syncInterval: .milliseconds(20)),
            cues: cues, state: store)
        let session = try await live.start(request())
        guard case .ended(let audio)? = await allEvents(of: session).last else {
            Issue.record("The recording did not end by itself.")
            return
        }
        #expect(audio.ending == .inputLost, "\(audio)")
        // The recorder writes the idle state and then gives the stopped-early cue: once the cue
        // is here, the state is idle, with no time to wait out.
        #expect(await SuiteWait.until("the stopped-early cue") { cues.cues.contains(.stoppedEarly) })
        #expect(cues.cues == [.stoppedEarly])
        #expect(store.writes.last?.snapshot == .idle)
        #expect(store.phases == [.starting, .stopping, .idle], "\(store.phases)")
    }

    /// A stop whose last sync fails ends as a failed write, and the recorder gives the
    /// stopped-early cue for it: the caller gives no `saved`.
    @Test func aStopWhoseLastSyncFailsStoppedEarly() async throws {
        let folder = try ScratchFolder()
        let cues = RecordingCueEmitter()
        let live = LiveRecorder(
            locations: folder.locations, layer: FailingFinalSync(failure: EIO), input: injected(frames: 1_600),
            settings: LiveRecorder.Settings(syncInterval: .seconds(60)), cues: cues)
        let session = try await live.start(request())
        let audio = await session.stop()
        #expect(audio.ending == .writeFailed, "\(audio)")
        // The stopped-early cue is the last one given, before the stop returned.
        #expect(await SuiteWait.until("the stopped-early cue") { cues.cues.contains(.stoppedEarly) })
        #expect(cues.cues == [.recordingLive, .stoppedEarly])
    }

    /// The hook for on-screen text: a recording's live audio, handed to a `Transcriber`, gives
    /// its live text as the audio comes, and the text ends when the recording does. A
    /// transcriber that reads nothing costs the recording nothing: here it is gone before the
    /// stop, and every frame is in the file.
    @Test func theLiveAudioFeedsATranscriber() async throws {
        let folder = try ScratchFolder()
        let transcriber = ScriptedTranscriber()
        transcriber.scriptLive(words: ["one", "two", "three"])
        let live = recorder(folder.locations, input: injected(frames: 8_000))
        let session = try await live.start(request())
        var shown: [String] = []
        for await event in transcriber.live(session.liveAudio) {
            guard case .update(let text) = event else { continue }
            shown.append(text.final)
            if text.final == "one two three" { break }
        }
        #expect(shown.last == "one two three", "\(shown)")
        await durable(atLeast: 8_000, of: session)
        let audio = await session.stop()
        #expect(audio.frames == 8_000)
    }

    /// The peaks of `samples`: the largest absolute sample of each stretch, the last one's part
    /// too.
    static func expectedPeaks(_ samples: [Int16], framesPerValue: Int) -> [UInt8] {
        stride(from: 0, to: samples.count, by: framesPerValue).map { start in
            let stretch = samples[start..<min(start + framesPerValue, samples.count)]
            return RecordingPeaks.value(peak: stretch.map { abs(Float($0) / 32_768) }.max() ?? 0)
        }
    }
}

/// An emitter that holds its first cue until the test releases it, and records each cue with
/// the label of the queue it was handed over on. It holds the recorder's cue queue, never a
/// thread of the cooperative pool. Its wait is kept in `hooks`, for the test to check.
final class HeldCues: CueEmitter {
    struct Played: Sendable, CustomStringConvertible {
        let cue: Cue
        let queue: String
        var description: String { "\(cue) on \(queue)" }
    }

    private let state = Mutex<(released: Bool, played: [Played])>((false, []))
    let hooks = HookWaits()

    var played: [Played] { state.withLock { $0.played } }

    func release() { state.withLock { $0.released = true } }

    func emit(_ cue: Cue) {
        let queue = String(cString: __dispatch_queue_get_label(nil))
        hooks.wait("the test to release the cues") { state.withLock { $0.released } }
        state.withLock { $0.played.append(Played(cue: cue, queue: queue)) }
    }
}
