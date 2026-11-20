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

    public init(
        recorder: any Recorder, locations: StoreLocations, exists: @escaping @Sendable (URL) -> Bool,
        size: @escaping @Sendable (URL) -> Int?, read: @escaping @Sendable (URL) -> Data?
    ) {
        self.recorder = recorder
        self.locations = locations
        self.exists = exists
        self.size = size
        self.read = read
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
    }

    static func request(_ launch: LaunchID = Identifier(uuid: UUID())) -> RecordingRequest {
        RecordingRequest(
            captureID: Identifier(uuid: UUID()), launchID: launch,
            origin: CaptureOrigin(source: .device(Identifier(uuid: UUID())), surface: .control), placement: .window,
            shownNote: Identifier(uuid: UUID()))
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
        let manifest = try CaptureManifest.decode(try #require(bytes, "The manifest is written before the start returns."))
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
        #expect(
            try await recorder.recoverOrphans(currentLaunch: later).contains { $0.captureID == earlier.captureID },
            "It stays an orphan until its working file is removed.")
        try await recorder.removeWorkingFile(of: earlier.captureID)
        #expect(
            try await !recorder.recoverOrphans(currentLaunch: later).contains { $0.captureID == earlier.captureID },
            "Once its working file is removed, it is not.")
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
