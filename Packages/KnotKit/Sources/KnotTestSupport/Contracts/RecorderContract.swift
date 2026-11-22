import Foundation
import KnotCore
import Testing

/// A recorder under test, with where its files go and a way to see them.
public struct RecorderSubject: Sendable {
    public let recorder: any Recorder
    public let locations: StoreLocations
    /// Whether a file exists, read without the recorder.
    public let exists: @Sendable (URL) -> Bool
    /// A file's size in bytes, or `nil` when there is none, read without the recorder.
    public let size: @Sendable (URL) -> Int?
    /// A file's bytes, or `nil` when there is none, read without the recorder.
    public let read: @Sendable (URL) -> Data?
    /// Makes a file one that the recorder cannot read, as one protected while the device is
    /// locked, or readable again, without moving it: for the real recorder, its permissions.
    public let setReadable: @Sendable (URL, Bool) -> Void
    /// Removes a file without the recorder, as a death between two writes leaves a recording.
    public let remove: @Sendable (URL) -> Void
    /// The cues the recorder has given, in order: the factory hands the recorder an emitter
    /// that records them.
    public let cues: @Sendable () -> [Cue]
    /// Makes the recorder's next start throw `error`, as a refused microphone does: for the real
    /// recorder, its input's open.
    public let failNextStart: @Sendable (KnotError) -> Void

    public init(
        recorder: any Recorder, locations: StoreLocations, exists: @escaping @Sendable (URL) -> Bool,
        size: @escaping @Sendable (URL) -> Int?, read: @escaping @Sendable (URL) -> Data?,
        setReadable: @escaping @Sendable (URL, Bool) -> Void, remove: @escaping @Sendable (URL) -> Void,
        cues: @escaping @Sendable () -> [Cue], failNextStart: @escaping @Sendable (KnotError) -> Void
    ) {
        self.recorder = recorder
        self.locations = locations
        self.exists = exists
        self.size = size
        self.read = read
        self.setReadable = setReadable
        self.remove = remove
        self.cues = cues
        self.failNextStart = failNextStart
    }
}

/// The contract suite of `Recorder` (docs/architecture.md §5 and §8). The factory makes a
/// recorder whose injected source delivers audio; the real recorder runs it in KnotAudio's
/// tests on injected audio, never on a microphone.
public enum RecorderContract {
    public static func run(_ make: @Sendable () async throws -> RecorderSubject) async throws {
        try await aRecordingStreamsStopsAndConverts(make)
        try await theFirstManifestNamesTheCaptureItFollows(make)
        try await aStopIsFinalAndCannotBeCancelled(make)
        try await twoStopsAtOnceBothWaitForTheFile(make)
        try await aDiscardRemovesTheRecording(make)
        try await recoveryNeverTouchesTheCurrentLaunch(make)
        try await aStoppedRecordingThatWasNotConvertedIsAnOrphan(make)
        try await anOrphanThatCannotBeReadIsKept(make)
        try await anOrphanWhoseManifestCannotBeReadEndsRecovered(make)
        try await aManifestWithNoWorkingFileHoldsNoAudio(make)
        try await aStopThatCannotReadTheFileBackIsAWriteFailure(make)
        try await aRecordingsPeaksGoWithIt(make)
        try await theRecorderGivesItsThreeCues(make)
    }

    static func request(
        _ launch: LaunchID = Identifier(uuid: UUID()), limit: Duration = .seconds(Limits.longestRecording)
    ) -> RecordingRequest {
        RecordingRequest(
            captureID: Identifier(uuid: UUID()), launchID: launch,
            origin: CaptureOrigin(source: .device(Identifier(uuid: UUID())), surface: .control), placement: .window,
            shownNote: Identifier(uuid: UUID()), limit: limit)
    }

    /// A start writes the manifest and the working file and returns a live session; levels,
    /// durable counts and live audio arrive; the stop leaves the working file on the drive; the
    /// events end with exactly one `.ended`; the conversion makes the stored format beside it,
    /// and the working file goes only when asked.
    public static func aRecordingStreamsStopsAndConverts(_ make: @Sendable () async throws -> RecorderSubject)
        async throws
    {
        let subject = try await make()
        let recorder = subject.recorder
        await recorder.prepare()
        await recorder.prepare()
        let request = request()
        let session = try await recorder.start(request)
        let manifest = subject.locations.recordingManifest(request.captureID)
        let working = subject.locations.recordingAudio(request.captureID, format: .caf)
        #expect(session.captureID == request.captureID)
        #expect(subject.exists(manifest), "The manifest is written before the first sample.")
        #expect(subject.exists(working), "The working file exists once the recording is live.")

        let size = subject.size
        let (durable, levels): ([Int64], Int) =
            await SuiteWait.value("two durable counts") {
                var durable: [Int64] = []
                var levels = 0
                for await event in session.events {
                    switch event {
                    case .level(let peak, let average):
                        levels += 1
                        #expect((0...1).contains(peak) && (0...1).contains(average), "Levels run from 0 to 1.")
                    case .durable(let frames):
                        durable.append(frames)
                        // What is reported durable is in the working file (finding 72).
                        #expect(frames == 0 || (size(working) ?? 0) > 0, "The working file holds what is durable.")
                    case .ended:
                        Issue.record("The recording ended before it was stopped.")
                    }
                    if durable.count >= 2 { break }
                }
                return (durable, levels)
            } ?? ([], 0)
        #expect(levels > 0, "Levels arrive.")
        #expect(durable == durable.sorted(), "The durable count never goes down.")
        let chunks: Int =
            await SuiteWait.value("live audio") {
                var chunks = 0
                for await chunk in session.liveAudio {
                    #expect(chunk.sampleRate > 0 && !chunk.samples.isEmpty)
                    chunks += 1
                    break
                }
                return chunks
            } ?? 0
        #expect(chunks == 1, "Live audio arrives.")

        let result = try #require(await SuiteWait.value("the stop") { await session.stop() })
        #expect(result.captureID == request.captureID && result.ending == .stopped)
        #expect(result.frames >= (durable.last ?? 0), "What was durable is in the file.")
        #expect(result.workingFile == working && subject.exists(working), "The working file stays after the stop.")
        let endings: [RecordedAudio] =
            await SuiteWait.value("the events to end after the stop") {
                var endings: [RecordedAudio] = []
                for await event in session.events { if case .ended(let audio) = event { endings.append(audio) } }
                return endings
            } ?? []
        #expect(endings == [result], "The events end with exactly one ending, the stop's result.")

        let converted = try await recorder.convert(result)
        #expect(converted.file == subject.locations.convertedRecording(request.captureID))
        #expect(subject.exists(converted.file), "The converted file is on the drive.")
        #expect(converted.duration == result.duration, "Its length matches the working file's.")
        #expect(subject.exists(working), "The working file stays until it is removed.")
        try await recorder.removeWorkingFile(of: request.captureID)
        #expect(!subject.exists(working) && !subject.exists(manifest), "Removing takes the working file and manifest.")
        try await recorder.removeWorkingFile(of: request.captureID)
        #expect(subject.exists(converted.file))
    }

    /// The manifest's first write records the request, read as the start returns and before any
    /// sample is taken: the link to the capture the recording follows among it, and no link
    /// when it follows nothing. A recorder that ignores the link fails here: a death just after
    /// the start would leave a recording that ingest cannot place after the capture it follows.
    public static func theFirstManifestNamesTheCaptureItFollows(_ make: @Sendable () async throws -> RecorderSubject)
        async throws
    {
        let subject = try await make()
        let recorder = subject.recorder
        var following = request()
        let followed: CaptureID = Identifier(uuid: UUID())
        following.followsCaptureID = followed
        let session = try await recorder.start(following)
        let bytes = subject.read(subject.locations.recordingManifest(following.captureID))
        let written = try #require(bytes, "The manifest is written before the start returns.")
        let manifest = try CaptureManifest.decode(written)
        #expect(manifest.captureID == following.captureID && manifest.kind == .voice)
        #expect(manifest.launchID == following.launchID && manifest.origin == following.origin)
        #expect(manifest.placement == following.placement && manifest.shownNoteID == following.shownNote)
        #expect(manifest.followsCaptureID == followed, "The manifest's first write names the capture it follows.")
        _ = await SuiteWait.value("the discard") { await session.discard() }

        let alone = request()
        let other = try await recorder.start(alone)
        let first = subject.read(subject.locations.recordingManifest(alone.captureID))
        let plain = try CaptureManifest.decode(try #require(first, "The manifest is written before the start returns."))
        #expect(plain.followsCaptureID == nil, "A recording that follows nothing names nothing.")
        _ = await SuiteWait.value("the discard") { await other.discard() }
    }

    /// A stop called again returns the same result, and a stop whose caller is cancelled
    /// still finishes.
    public static func aStopIsFinalAndCannotBeCancelled(_ make: @Sendable () async throws -> RecorderSubject)
        async throws
    {
        let subject = try await make()
        let session = try await subject.recorder.start(request())
        let stopping = Task { await session.stop() }
        stopping.cancel()
        let first = try #require(await SuiteWait.value("a cancelled caller's stop") { await stopping.value })
        #expect(first.ending == .stopped, "A cancelled caller does not cancel the stop.")
        #expect(
            await SuiteWait.value("a second stop") { await session.stop() } == first,
            "A second stop returns the same result.")
    }

    /// Two stops at once return the same result, and neither returns before the file is on the
    /// drive: a later caller waits for the first one's write (finding 72).
    public static func twoStopsAtOnceBothWaitForTheFile(_ make: @Sendable () async throws -> RecorderSubject)
        async throws
    {
        let subject = try await make()
        let request = request()
        let session = try await subject.recorder.start(request)
        _ = await SuiteWait.value("a durable count above zero") {
            for await event in session.events {
                if case .durable(let frames) = event, frames > 0 { break }
            }
        }
        let working = subject.locations.recordingAudio(request.captureID, format: .caf)
        let size = subject.size
        let seen: [StopSeen] =
            await SuiteWait.value("two stops at once") {
                await withTaskGroup(of: StopSeen.self) { group in
                    for _ in 0..<2 { group.addTask { StopSeen(audio: await session.stop(), size: size(working)) } }
                    var seen: [StopSeen] = []
                    for await each in group { seen.append(each) }
                    return seen
                }
            } ?? []
        let final = subject.size(working)
        #expect(seen.count == 2 && seen.allSatisfy { $0.audio == seen[0].audio }, "Both stops return the same result.")
        #expect((final ?? 0) > 0, "The stopped recording is on the drive.")
        #expect(
            seen.allSatisfy { $0.size == final },
            "Neither stop returns before the file is written: \(seen.map(\.size)).")
    }

    /// A discard ends the recording and keeps nothing.
    public static func aDiscardRemovesTheRecording(_ make: @Sendable () async throws -> RecorderSubject) async throws {
        let subject = try await make()
        let request = request()
        let session = try await subject.recorder.start(request)
        _ = await SuiteWait.value("the discard") { await session.discard() }
        let after = try #require(await SuiteWait.value("a stop after the discard") { await session.stop() })
        #expect(after.ending == .discarded && after.frames == 0 && after.workingFile == nil, "Nothing is kept.")
        #expect(!subject.exists(subject.locations.recordingAudio(request.captureID, format: .caf)))
        #expect(!subject.exists(subject.locations.recordingManifest(request.captureID)))
    }

    /// A recorder may leave a recording's level peaks at `StoreLocations.recordingPeaks(_:)`. A
    /// peaks file that is there reads back as `RecordingPeaks`, and none is left after
    /// `removeWorkingFile(of:)` or after a discard: a peaks file never outlives its recording. A
    /// recorder that writes none meets this too.
    public static func aRecordingsPeaksGoWithIt(_ make: @Sendable () async throws -> RecorderSubject) async throws {
        let subject = try await make()
        let recorder = subject.recorder
        let kept = request()
        let session = try await recorder.start(kept)
        _ = await SuiteWait.value("a durable count above zero") {
            for await event in session.events {
                if case .durable(let frames) = event, frames > 0 { break }
            }
        }
        _ = try #require(await SuiteWait.value("the stop") { await session.stop() })
        let peaks = subject.locations.recordingPeaks(kept.captureID)
        if subject.exists(peaks) {
            #expect(subject.read(peaks).flatMap(RecordingPeaks.init(reading:)) != nil, "Peaks read back as the format.")
        }
        try await recorder.removeWorkingFile(of: kept.captureID)
        #expect(!subject.exists(peaks), "Removing the working file takes the peaks.")

        let dropped = request()
        let discarded = try await recorder.start(dropped)
        _ = await SuiteWait.value("a durable count above zero") {
            for await event in discarded.events {
                if case .durable(let frames) = event, frames > 0 { break }
            }
        }
        _ = await SuiteWait.value("the discard") { await discarded.discard() }
        #expect(!subject.exists(subject.locations.recordingPeaks(dropped.captureID)), "A discard takes the peaks.")
    }

    /// The recorder gives the three cues that only it can time, each once, as the port says:
    /// `recordingLive` as a start returns live, `couldNotStart` for a start that throws, and
    /// `stoppedEarly` for a recording that ended by itself, here at its limit, with nobody
    /// reading its events. A stop, a discard and recovery give none: the caller gives `saved`
    /// or `discarded`, and a recovered recording has no cue. A start that throws follows each
    /// step, so that a cue given late would show before its `couldNotStart`.
    public static func theRecorderGivesItsThreeCues(_ make: @Sendable () async throws -> RecorderSubject)
        async throws
    {
        let subject = try await make()
        let recorder = subject.recorder
        var expected: [Cue] = []
        /// A start that throws, and every cue so far, in order, then that start's.
        func refusedStart(after step: String) async {
            subject.failNextStart(.noInputDevice)
            await #expect(throws: KnotError.self, "The start after \(step) throws.") {
                _ = try await recorder.start(request())
            }
            expected.append(.couldNotStart)
            let count = expected.count
            #expect(
                await SuiteWait.until("the cue after \(step)", limit: .seconds(10)) { subject.cues().count >= count })
            #expect(subject.cues() == expected, "The cues after \(step).")
        }

        let stopped = try await recorder.start(request())
        expected.append(.recordingLive)
        _ = try #require(await SuiteWait.value("the stop") { await stopped.stop() })
        await refusedStart(after: "a stop")

        // At its limit, with nobody reading its events: the recording ends by itself.
        let limited = try await recorder.start(request(limit: .milliseconds(250)))
        expected += [.recordingLive, .stoppedEarly]
        let count = expected.count
        #expect(await SuiteWait.until("the stopped-early cue", limit: .seconds(10)) { subject.cues().count >= count })
        #expect(subject.cues() == expected, "A recording that ended at its limit stopped early.")
        let ended = try #require(await SuiteWait.value("the stop after the ending") { await limited.stop() })
        #expect(ended.ending == .limitReached)
        await refusedStart(after: "a recording that ended by itself")

        let discarded = try await recorder.start(request())
        expected.append(.recordingLive)
        _ = await SuiteWait.value("the discard") { await discarded.discard() }
        await refusedStart(after: "a discard")

        let launch: LaunchID = Identifier(uuid: UUID())
        _ = try await recorder.start(request(launch))
        expected.append(.recordingLive)
        let orphans = try await recorder.recoverOrphans(currentLaunch: Identifier(uuid: UUID()))
        #expect(orphans.contains { $0.ending == .recovered }, "\(orphans.map(\.ending))")
        await refusedStart(after: "a recovery")
    }

    /// Recovery finishes recordings of earlier launches and never one of the current launch.
    /// A recording of an earlier launch that stopped and was never converted, or whose
    /// conversion failed, leaves a working file, and it is among that launch's orphans: a later
    /// launch's recovery returns it, read to its last complete frame, until `removeWorkingFile`
    /// takes it, in the same call as a recording of that launch that never ended. So a failed
    /// conversion is tried again at the next launch (finding 23), and a recording that stopped
    /// is never left uncounted in `Recording/`.
    public static func aStoppedRecordingThatWasNotConvertedIsAnOrphan(
        _ make: @Sendable () async throws -> RecorderSubject
    ) async throws {
        let subject = try await make()
        let recorder = subject.recorder
        let launch: LaunchID = Identifier(uuid: UUID())
        let earlier = request(launch)
        let session = try await recorder.start(earlier)
        let stopped = try #require(await SuiteWait.value("the stop") { await session.stop() })
        // Beside it, a recording of the same launch that never ended: the launch died with it.
        let unended = request(launch)
        _ = try await recorder.start(unended)
        let later: LaunchID = Identifier(uuid: UUID())
        let orphans = try await recorder.recoverOrphans(currentLaunch: later)
        let found = orphans.first { $0.captureID == earlier.captureID }
        #expect(found != nil, "A stopped recording that was never converted is an orphan of its launch.")
        #expect(found?.workingFile == stopped.workingFile && found?.frames == stopped.frames, "Read to its end.")
        let died = orphans.first { $0.captureID == unended.captureID }
        #expect(died != nil, "A recording that never ended is an orphan of its launch, beside the stopped one.")
        #expect(died?.ending == .recovered, "It is finished as recovered.")
        for capture in [earlier.captureID, unended.captureID] {
            #expect(orphans.filter { $0.captureID == capture }.count == 1, "Each orphan comes back once in a call.")
        }
        #expect(
            try await recorder.recoverOrphans(currentLaunch: later).filter { $0.captureID == earlier.captureID }.count
                == 1, "It stays an orphan until its working file is removed, once in each call.")
        try await recorder.removeWorkingFile(of: earlier.captureID)
        #expect(
            try await !recorder.recoverOrphans(currentLaunch: later).contains { $0.captureID == earlier.captureID },
            "Once its working file is removed, it is not.")
    }

    /// An orphan whose working file is on the drive and cannot be read is not returned and not
    /// removed, and it is returned whole once it can be read again: it is never taken for a
    /// recording with no audio (the review of the recorder's pull request 57).
    public static func anOrphanThatCannotBeReadIsKept(_ make: @Sendable () async throws -> RecorderSubject)
        async throws
    {
        let subject = try await make()
        let recorder = subject.recorder
        let earlier = request()
        let session = try await recorder.start(earlier)
        let stopped = try #require(await SuiteWait.value("the stop") { await session.stop() })
        let working = try #require(stopped.workingFile, "The stopped recording names its working file.")
        let manifest = subject.locations.recordingManifest(earlier.captureID)
        let later: LaunchID = Identifier(uuid: UUID())
        subject.setReadable(working, false)
        let whileLocked = try await recorder.recoverOrphans(currentLaunch: later)
        #expect(
            !whileLocked.contains { $0.captureID == earlier.captureID },
            "A recording that cannot be read is not returned, and never as one with no audio.")
        #expect(subject.exists(working) && subject.exists(manifest), "Nothing of it is removed.")
        subject.setReadable(working, true)
        let found = try await recorder.recoverOrphans(currentLaunch: later).first {
            $0.captureID == earlier.captureID
        }
        #expect(found?.workingFile == working && found?.frames == stopped.frames, "Whole, once it can be read.")
        try await recorder.removeWorkingFile(of: earlier.captureID)
    }

    /// The orphan is the working file: one that can be read is returned with its frames, and
    /// its ending is `recovered` when its manifest cannot be read. The manifest is left where it
    /// is, and once it can be read the ending is the manifest's again.
    public static func anOrphanWhoseManifestCannotBeReadEndsRecovered(
        _ make: @Sendable () async throws -> RecorderSubject
    ) async throws {
        let subject = try await make()
        let recorder = subject.recorder
        let earlier = request()
        let session = try await recorder.start(earlier)
        let stopped = try #require(await SuiteWait.value("the stop") { await session.stop() })
        #expect(stopped.ending == .stopped)
        let manifest = subject.locations.recordingManifest(earlier.captureID)
        let later: LaunchID = Identifier(uuid: UUID())
        subject.setReadable(manifest, false)
        let found = try await recorder.recoverOrphans(currentLaunch: later).first {
            $0.captureID == earlier.captureID
        }
        #expect(found != nil, "A manifest that cannot be read does not hide its recording.")
        #expect(found?.ending == .recovered, "Its ending is recovered.")
        #expect(found?.workingFile == stopped.workingFile && found?.frames == stopped.frames, "With its frames.")
        #expect(subject.exists(manifest), "The manifest is left where it is.")
        subject.setReadable(manifest, true)
        let again = try await recorder.recoverOrphans(currentLaunch: later).first {
            $0.captureID == earlier.captureID
        }
        #expect(again?.ending == .stopped, "Once the manifest can be read, the ending is its own.")
        try await recorder.removeWorkingFile(of: earlier.captureID)
    }

    /// A manifest with no working file is a recording with no audio: no frame, or no working
    /// file. Removing it then takes the manifest.
    public static func aManifestWithNoWorkingFileHoldsNoAudio(_ make: @Sendable () async throws -> RecorderSubject)
        async throws
    {
        let subject = try await make()
        let recorder = subject.recorder
        let earlier = request()
        let session = try await recorder.start(earlier)
        _ = await SuiteWait.value("a durable count above zero") {
            for await event in session.events {
                if case .durable(let frames) = event, frames > 0 { break }
            }
        }
        let stopped = try #require(await SuiteWait.value("the stop") { await session.stop() })
        #expect(stopped.frames > 0, "The recording held audio before its working file went.")
        let working = try #require(stopped.workingFile, "The stopped recording names its working file.")
        let manifest = subject.locations.recordingManifest(earlier.captureID)
        subject.remove(working)
        #expect(!subject.exists(working) && subject.exists(manifest))
        let later: LaunchID = Identifier(uuid: UUID())
        let found = try #require(
            try await recorder.recoverOrphans(currentLaunch: later).first { $0.captureID == earlier.captureID },
            "The manifest's recording is returned.")
        #expect(found.frames == 0 || found.workingFile == nil, "A manifest with no working file is no audio.")
        #expect(found.workingFile.map(subject.exists) != false, "No working file is named that is not there.")
        try await recorder.removeWorkingFile(of: earlier.captureID)
        #expect(!subject.exists(manifest), "Removing takes the manifest.")
    }

    /// A stop whose working file is there and whose length cannot be read back answers
    /// `write_failed`, names the working file, and gives the last length read: a recording on the
    /// drive is never answered as one with no audio.
    public static func aStopThatCannotReadTheFileBackIsAWriteFailure(
        _ make: @Sendable () async throws -> RecorderSubject
    ) async throws {
        let subject = try await make()
        let recorder = subject.recorder
        let request = request()
        let session = try await recorder.start(request)
        let durable: Int64 =
            await SuiteWait.value("a durable count above zero") {
                for await event in session.events {
                    if case .durable(let frames) = event, frames > 0 { return frames }
                }
                return 0
            } ?? 0
        #expect(durable > 0)
        let working = subject.locations.recordingAudio(request.captureID, format: .caf)
        subject.setReadable(working, false)
        let result = try #require(await SuiteWait.value("the stop") { await session.stop() })
        #expect(result.ending == .writeFailed, "A length that cannot be read back is a write failure.")
        #expect(result.workingFile == working, "The working file is named.")
        #expect(result.frames >= durable, "The last length read, never no audio: \(result.frames).")
        #expect(subject.exists(working), "The working file stays.")
        subject.setReadable(working, true)
        try await recorder.removeWorkingFile(of: request.captureID)
    }

    public static func recoveryNeverTouchesTheCurrentLaunch(_ make: @Sendable () async throws -> RecorderSubject)
        async throws
    {
        let subject = try await make()
        let launch: LaunchID = Identifier(uuid: UUID())
        let session = try await subject.recorder.start(request(launch))
        let recovered = try await subject.recorder.recoverOrphans(currentLaunch: launch)
        #expect(
            !recovered.contains { $0.captureID == session.captureID }, "The current launch's recording is left alone.")
        #expect(recovered.allSatisfy { $0.ending == .recovered })
        #expect(await SuiteWait.value("the stop") { await session.stop() }?.ending == .stopped, "It records on.")
    }
}

/// What one of two stops at once saw: its result, and the working file's size as it returned.
struct StopSeen: Sendable {
    let audio: RecordedAudio
    let size: Int?
}
