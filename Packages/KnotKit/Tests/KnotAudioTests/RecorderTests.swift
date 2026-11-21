import AVFAudio
import Foundation
import KnotCore
import KnotTestSupport
import Testing

@testable import KnotAudio

/// The live recorder on injected audio: what goes in comes out, at every rate, and a recording
/// ends by itself the way the port says.
@Suite struct RecorderTests {
    /// File-driven input produces the expected output: every frame injected is in the working
    /// file, unchanged, at the input's rate, whatever the buffers' size, and the stop reads the
    /// length from the file.
    @Test(arguments: [(16_000.0, 1_600, 40_000), (48_000.0, 4_801, 100_003), (44_100.0, 4_410, 1)])
    func everyFrameInjectedIsInTheFileUnchanged(rate: Double, framesPerBuffer: Int, frames: Int) async throws {
        let folder = try ScratchFolder()
        let recorder = recorder(
            folder.locations, input: injected(frames: Int64(frames), rate: rate, framesPerBuffer: framesPerBuffer))
        let session = try await recorder.start(request())
        await durable(atLeast: Int64(frames), of: session)
        let audio = try #require(await SuiteWait.value("the stop") { await session.stop() })
        #expect(audio.frames == Int64(frames) && audio.sampleRate == rate && audio.ending == .stopped)
        let file = try #require(audio.workingFile)
        #expect(
            WorkingFileReader.contents(of: file) == WorkingFileReader.Contents(frames: Int64(frames), sampleRate: rate))
        #expect(WorkingFileReader.samples(of: file) == synthetic(frames), "Every frame is the one injected.")
    }

    /// The microphone's buffers are 32-bit floats: the file holds them as 16-bit integers, and
    /// a float made from an integer sample comes back as that sample.
    @Test func floatAudioIsWrittenAsSixteenBitSamples() async throws {
        let folder = try ScratchFolder()
        let recorder = recorder(folder.locations, input: FloatInput(frames: 32_000))
        let session = try await recorder.start(request())
        await durable(atLeast: 32_000, of: session)
        let audio = await session.stop()
        #expect(audio.frames == 32_000)
        #expect(WorkingFileReader.samples(of: try #require(audio.workingFile)) == synthetic(32_000))
    }

    /// At its limit a recording ends by itself: the file holds the limit exactly, even when the
    /// limit falls inside a buffer; the events end with one `.ended`; and a stop after it returns
    /// the same result.
    @Test(arguments: [Duration.milliseconds(500), .milliseconds(550)])
    func aRecordingEndsByItselfAtItsLimit(limit: Duration) async throws {
        let folder = try ScratchFolder()
        let recorder = recorder(folder.locations, input: injected())
        let session = try await recorder.start(request(limit: limit))
        let events = await allEvents(of: session)
        let expected = Int64((Double(limit.components.attoseconds) / 1e18 + Double(limit.components.seconds)) * 16_000)
        let endings = events.compactMap { event -> RecordedAudio? in
            if case .ended(let audio) = event { return audio }
            return nil
        }
        #expect(endings.count == 1 && endings.first?.ending == .limitReached && endings.first?.frames == expected)
        #expect(await session.stop() == endings.first, "A stop after the ending returns its result.")
        let file = try #require(endings.first?.workingFile)
        #expect(WorkingFileReader.samples(of: file) == synthetic(Int(expected)))
    }

    /// An input that ends by itself ends the recording with the input's reason, and everything
    /// written is kept, with the manifest marked as ended.
    @Test(arguments: [(InputEnding.lost, RecordingEnding.inputLost), (.interrupted, .interrupted)])
    func anInputThatEndsEndsTheRecording(why: InputEnding, ending: RecordingEnding) async throws {
        let folder = try ScratchFolder()
        let recorder = recorder(folder.locations, input: injected(frames: 4_800, ending: .ends(why)))
        let request = request()
        let session = try await recorder.start(request)
        let events = await allEvents(of: session)
        guard case .ended(let audio)? = events.last else {
            Issue.record("The events end with the ending: \(events.suffix(2))")
            return
        }
        #expect(audio.ending == ending && audio.ending.endedByItself && audio.frames == 4_800)
        #expect(WorkingFileReader.samples(of: try #require(audio.workingFile)) == synthetic(4_800))
        #expect(try manifest(folder.locations, request.captureID).endedAt != nil)
    }

    /// A stop writes the manifest again with the end and the length, and keeps every field the
    /// first write had.
    @Test func aStopMarksTheManifestAsEnded() async throws {
        let folder = try ScratchFolder()
        let recorder = recorder(folder.locations, input: injected(frames: 8_000))
        var request = request()
        request.followsCaptureID = CaptureID(uuid: UUID())
        let session = try await recorder.start(request)
        let first = try manifest(folder.locations, request.captureID)
        #expect(first.endedAt == nil && first.duration == nil)
        await durable(atLeast: 8_000, of: session)
        let audio = await session.stop()
        var marked = try manifest(folder.locations, request.captureID)
        #expect(marked.endedAt != nil && marked.duration == audio.duration)
        marked.endedAt = nil
        marked.duration = nil
        #expect(marked == first, "Nothing else changes.")
    }

    /// The durable count never runs ahead of the file, and never goes down.
    @Test func whatIsDurableIsInTheFile() async throws {
        let folder = try ScratchFolder()
        let recorder = recorder(folder.locations, input: injected(frames: 48_000, every: .milliseconds(5)))
        let request = request()
        let session = try await recorder.start(request)
        let working = folder.locations.recordingAudio(request.captureID, format: .caf)
        let checked: [Bool] =
            await SuiteWait.value("durable counts") {
                var checked: [Bool] = []
                var last: Int64 = 0
                for await event in session.events {
                    guard case .durable(let frames) = event else { continue }
                    let held = WorkingFileReader.contents(of: working)?.frames ?? 0
                    checked.append(held >= frames && frames > last)
                    last = frames
                    if frames >= 48_000 { break }
                }
                return checked
            } ?? []
        #expect(!checked.isEmpty && checked.allSatisfy { $0 }, "\(checked)")
        _ = await session.stop()
    }

    /// The live audio is the audio written, in chunks of at most 100 ms, from -1 to 1.
    @Test func liveAudioIsTheAudioWritten() async throws {
        let folder = try ScratchFolder()
        let recorder = recorder(folder.locations, input: injected(frames: 8_000, framesPerBuffer: 4_000))
        let session = try await recorder.start(request())
        let chunks: [AudioChunk] =
            await SuiteWait.value("the live audio") {
                var chunks: [AudioChunk] = []
                for await chunk in session.liveAudio {
                    chunks.append(chunk)
                    if chunks.reduce(0, { $0 + $1.samples.count }) >= 8_000 { break }
                }
                return chunks
            } ?? []
        #expect(chunks.allSatisfy { $0.sampleRate == 16_000 && $0.samples.count <= 1_600 })
        #expect(chunks.flatMap(\.samples) == synthetic(8_000).map { Float($0) / 32_768 })
        _ = await session.stop()
    }

    /// Levels run from 0 to 1: the peak is the largest magnitude and the average the root mean square.
    @Test func levelsArePeakAndRootMeanSquare() throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        func level(_ samples: [Int16]) throws -> (peak: Float, average: Float) {
            let buffer = try #require(
                SyntheticAudio.buffer(format: format, from: 0, count: samples.count) { samples[Int($0)] })
            return Levels.of(buffer)
        }
        #expect(try level([0, 0, 0, 0]) == (0, 0))
        #expect(try level([-32_768, 0, 0, 0]) == (1, 0.5))
        #expect(try level([16_384, -16_384, 16_384, -16_384]) == (0.5, 0.5))
    }

    /// A start that cannot open its input leaves no file: the case is the input's.
    @Test(arguments: [KnotError.microphonePermissionRefused, .noInputDevice, .audioSessionBusy])
    func aStartThatCannotOpenItsInputLeavesNothing(failure: KnotError) async throws {
        let folder = try ScratchFolder()
        let recorder = recorder(folder.locations, input: injected(openFailure: failure))
        let request = request()
        let error = await #expect(throws: KnotError.self) { try await recorder.start(request) }
        #expect(error?.code == failure.code && error?.context.captureID == request.captureID)
        #expect(recordingFolder(folder.locations).isEmpty)
    }

    /// A start whose input fails once the manifest and the file are written removes them: no
    /// recording is left for recovery to find.
    @Test func aStartThatFailsAfterItsFirstWriteRemovesIt() async throws {
        let folder = try ScratchFolder()
        let recorder = recorder(folder.locations, input: injected(startFailure: .audioSessionBusy))
        let request = request()
        let error = await #expect(throws: KnotError.self) { try await recorder.start(request) }
        #expect(error?.code == KnotError.audioSessionBusy.code)
        #expect(recordingFolder(folder.locations).isEmpty, "\(recordingFolder(folder.locations))")
        #expect(try await recorder.recoverOrphans(currentLaunch: LaunchID(uuid: UUID())).isEmpty)
    }

    /// A capture that is recording, or whose files are in `Recording/`, cannot start again:
    /// nothing is replaced, and the recording goes on.
    @Test func aCaptureCannotStartTwice() async throws {
        let folder = try ScratchFolder()
        let recorder = recorder(folder.locations, input: injected(frames: 16_000))
        let request = request()
        let session = try await recorder.start(request)
        let error = await #expect(throws: KnotError.self) { try await recorder.start(request) }
        #expect(error?.code == KnotError.writeFailed.code && error?.context.posixError == EEXIST)
        await durable(atLeast: 16_000, of: session)
        let audio = await session.stop()
        #expect(audio.frames == 16_000 && audio.ending == .stopped)

        // Its files outlive it: a later start of the same capture is refused too.
        let again = await #expect(throws: KnotError.self) { try await recorder.start(request) }
        #expect(again?.context.posixError == EEXIST)
        #expect(WorkingFileReader.samples(of: try #require(audio.workingFile)) == synthetic(16_000))
    }

    /// A final sync that fails is the result's ending, over a stop and over the limit:
    /// `disk_full` when the volume has no room, `write_failed` otherwise. The file is kept, and
    /// read back whole.
    @Test(arguments: [(false, ENOSPC), (true, ENOSPC), (false, EIO), (true, EIO)])
    func aFailedFinalSyncIsTheEnding(atTheLimit: Bool, failure: Int32) async throws {
        let folder = try ScratchFolder()
        let recorder = LiveRecorder(
            locations: folder.locations, layer: FailingFinalSync(failure: failure), input: FloatInput(frames: 16_000),
            settings: LiveRecorder.Settings(syncInterval: .seconds(3_600)))
        let session = try await recorder.start(request(limit: .seconds(atTheLimit ? 1 : 2)))
        let audio = await session.stop()
        #expect(audio.ending == (failure == ENOSPC ? .diskFull : .writeFailed), "\(audio)")
        #expect(audio.frames == 16_000 && audio.workingFile != nil)
    }

    /// A stop that cannot read its file back says the recording could not be saved further, and
    /// names the file, with the last length the session read from it: it never answers that the
    /// recording holds nothing.
    @Test func aStopThatCannotReadItsFileBackNamesIt() async throws {
        let folder = try ScratchFolder()
        let recorder = recorder(folder.locations, input: FloatInput(frames: 16_000))
        let request = request()
        let session = try await recorder.start(request)
        // The sync after the last write reads the length back; nothing is written after it.
        await durable(atLeast: 16_000, of: session)
        let working = folder.locations.recordingAudio(request.captureID, format: .caf)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: working.path)
        let audio = await session.stop()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: working.path)
        #expect(audio.ending == .writeFailed && audio.workingFile == working && audio.frames == 16_000, "\(audio)")
        #expect(WorkingFileReader.samples(of: working) == synthetic(16_000), "The file is kept whole.")
    }

    /// A discard after the recording ended, by itself or by a stop, removes its working file and
    /// its manifest all the same, and a stop after it is empty: the next launch finds nothing to
    /// store.
    @Test(arguments: [EndedFirst.inputInterrupted, .limitReached, .stopped])
    func aDiscardAfterTheEndRemovesTheFiles(first: EndedFirst) async throws {
        let folder = try ScratchFolder()
        let input = first == .inputInterrupted ? injected(frames: 3_200, ending: .ends(.interrupted)) : injected()
        let recorder = recorder(folder.locations, input: input)
        let request = request(limit: first == .limitReached ? .milliseconds(200) : .seconds(1_800))
        let session = try await recorder.start(request)
        if first == .stopped {
            await durable(atLeast: 3_200, of: session)
            #expect(await session.stop().ending == .stopped)
        } else {
            let events = await allEvents(of: session)
            guard case .ended(let audio)? = events.last, audio.ending.endedByItself else {
                Issue.record("The recording did not end by itself: \(events.suffix(1))")
                return
            }
        }
        await session.discard()
        #expect(!exists(folder.locations.recordingAudio(request.captureID, format: .caf)), "The working file stays.")
        #expect(!exists(folder.locations.recordingManifest(request.captureID)), "The manifest stays.")
        let after = await session.stop()
        #expect(after.ending == .discarded && after.frames == 0 && after.workingFile == nil, "\(after)")
        let orphans = try await recorder.recoverOrphans(currentLaunch: LaunchID(uuid: UUID()))
        #expect(!orphans.contains { $0.captureID == request.captureID }, "\(orphans)")
    }

    enum EndedFirst: String, Sendable {
        case inputInterrupted
        case limitReached
        case stopped
    }

    /// The files of a recording that is live in this process cannot be removed: the removal is
    /// refused with `illegal_transition`, the recording goes on, and its stop keeps every frame.
    @Test func theFilesOfALiveRecordingCannotBeRemoved() async throws {
        let folder = try ScratchFolder()
        let recorder = recorder(folder.locations, input: injected(frames: 16_000))
        let request = request()
        let session = try await recorder.start(request)
        await durable(atLeast: 16_000, of: session)
        let error = await #expect(throws: KnotError.self) {
            try await recorder.removeWorkingFile(of: request.captureID)
        }
        #expect(error?.code == KnotError.illegalTransition.code && error?.context.captureID == request.captureID)
        #expect(exists(folder.locations.recordingManifest(request.captureID)))
        let audio = await session.stop()
        #expect(audio.frames == 16_000 && audio.ending == .stopped, "\(audio)")
        #expect(WorkingFileReader.samples(of: try #require(audio.workingFile)) == synthetic(16_000))
        try await recorder.removeWorkingFile(of: request.captureID)
        #expect(recordingFolder(folder.locations).isEmpty, "Once it has ended, its files go.")
    }

    /// A discard removes the recording's files and ends its events with one `.ended`, discarded.
    @Test func aDiscardLeavesNoFileAndEndsTheEvents() async throws {
        let folder = try ScratchFolder()
        let recorder = recorder(folder.locations, input: injected())
        let session = try await recorder.start(request())
        await durable(atLeast: 1, of: session)
        await session.discard()
        let events = await allEvents(of: session)
        let endings = events.filter { if case .ended = $0 { true } else { false } }
        #expect(endings.count == 1)
        if case .ended(let audio)? = endings.first { #expect(audio.ending == .discarded && audio.workingFile == nil) }
        #expect(recordingFolder(folder.locations).isEmpty, "\(recordingFolder(folder.locations))")
    }
}

/// The file layer of the drive, except that syncing a working file fails with `failure`: as a
/// full volume, or a failing drive, answers the last sync of a recording.
struct FailingFinalSync: FileLayer {
    let failure: Int32
    private let disk = PosixFileLayer()

    init(failure: Int32) { self.failure = failure }

    func syncFile(_ url: URL) throws(KnotError) {
        guard url.pathExtension != "caf" else {
            throw (failure == ENOSPC ? KnotError.diskFull : KnotError.writeFailed).with(.init(posixError: failure))
        }
        try disk.syncFile(url)
    }
    func createFolder(_ url: URL) throws(KnotError) { try disk.createFolder(url) }
    func write(_ data: Data, to url: URL) throws(KnotError) { try disk.write(data, to: url) }
    func rename(_ source: URL, to destination: URL) throws(KnotError) { try disk.rename(source, to: destination) }
    func syncFolder(_ url: URL) throws(KnotError) { try disk.syncFolder(url) }
    func remove(_ url: URL) throws(KnotError) { try disk.remove(url) }
    func read(_ url: URL) throws(KnotError) -> Data { try disk.read(url) }
    func exists(_ url: URL) -> Bool { disk.exists(url) }
    func entryKind(_ url: URL) -> FileEntryKind? { disk.entryKind(url) }
    func contents(of folder: URL) throws(KnotError) -> [String] { try disk.contents(of: folder) }
}

/// An input that delivers 32-bit floats, as the microphone does: the synthetic signal, scaled.
struct FloatInput: AudioInput {
    let frames: Int64

    func prepare() async {}

    func open() async throws(KnotError) -> any OpenAudioInput { Opened(frames: frames) }

    final class Opened: OpenAudioInput {
        let frames: Int64
        let sampleRate = 16_000.0
        let commonFormat = AVAudioCommonFormat.pcmFormatFloat32

        init(frames: Int64) { self.frames = frames }

        /// Delivers every frame before it returns, as one burst.
        func start(format: AVAudioFormat, deliver: @escaping @Sendable (AudioDelivery) -> Void) throws(KnotError) {
            var position: Int64 = 0
            while position < frames {
                let count = Int(min(1_600, frames - position))
                if let buffer = SyntheticAudio.buffer(
                    format: format, from: position, count: count, SyntheticAudio.sample(at:))
                {
                    deliver(.audio(buffer))
                }
                position += Int64(count)
            }
        }

        func stop() async {}
    }
}
