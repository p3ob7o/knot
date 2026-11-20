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

    public init(
        recorder: any Recorder, locations: StoreLocations, exists: @escaping @Sendable (URL) -> Bool,
        size: @escaping @Sendable (URL) -> Int?
    ) {
        self.recorder = recorder
        self.locations = locations
        self.exists = exists
        self.size = size
    }
}

/// The contract suite of `Recorder` (docs/architecture.md §5 and §8). The factory makes a
/// recorder whose injected source delivers audio; the real recorder runs it in KnotAudio's
/// tests on injected audio, never on a microphone.
public enum RecorderContract {
    public static func run(_ make: @Sendable () async throws -> RecorderSubject) async throws {
        try await aRecordingStreamsStopsAndConverts(make)
        try await aStopIsFinalAndCannotBeCancelled(make)
        try await twoStopsAtOnceBothWaitForTheFile(make)
        try await aDiscardRemovesTheRecording(make)
        try await recoveryNeverTouchesTheCurrentLaunch(make)
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
                #expect(frames == 0 || (subject.size(working) ?? 0) > 0, "The working file holds what is durable.")
            case .ended:
                Issue.record("The recording ended before it was stopped.")
            }
            if durable.count >= 2 { break }
        }
        #expect(levels > 0, "Levels arrive.")
        #expect(durable == durable.sorted(), "The durable count never goes down.")
        var chunks = 0
        for await chunk in session.liveAudio {
            #expect(chunk.sampleRate > 0 && !chunk.samples.isEmpty)
            chunks += 1
            break
        }
        #expect(chunks == 1, "Live audio arrives.")

        let result = await session.stop()
        #expect(result.captureID == request.captureID && result.ending == .stopped)
        #expect(result.frames >= (durable.last ?? 0), "What was durable is in the file.")
        #expect(result.workingFile == working && subject.exists(working), "The working file stays after the stop.")
        var endings: [RecordedAudio] = []
        for await event in session.events { if case .ended(let audio) = event { endings.append(audio) } }
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

    /// A stop called again returns the same result, and a stop whose caller is cancelled
    /// still finishes.
    public static func aStopIsFinalAndCannotBeCancelled(_ make: @Sendable () async throws -> RecorderSubject)
        async throws
    {
        let subject = try await make()
        let session = try await subject.recorder.start(request())
        let stopping = Task { await session.stop() }
        stopping.cancel()
        let first = await stopping.value
        #expect(first.ending == .stopped, "A cancelled caller does not cancel the stop.")
        #expect(await session.stop() == first, "A second stop returns the same result.")
    }

    /// Two stops at once return the same result, and neither returns before the file is on the
    /// drive: a later caller waits for the first one's write (finding 72).
    public static func twoStopsAtOnceBothWaitForTheFile(_ make: @Sendable () async throws -> RecorderSubject)
        async throws
    {
        let subject = try await make()
        let request = request()
        let session = try await subject.recorder.start(request)
        for await event in session.events {
            if case .durable(let frames) = event, frames > 0 { break }
        }
        let working = subject.locations.recordingAudio(request.captureID, format: .caf)
        let size = subject.size
        let seen = await withTaskGroup(of: (RecordedAudio, Int?).self) { group in
            for _ in 0..<2 { group.addTask { (await session.stop(), size(working)) } }
            var seen: [(RecordedAudio, Int?)] = []
            for await each in group { seen.append(each) }
            return seen
        }
        let final = subject.size(working)
        #expect(seen.count == 2 && seen.allSatisfy { $0.0 == seen[0].0 }, "Both stops return the same result.")
        #expect((final ?? 0) > 0, "The stopped recording is on the drive.")
        #expect(seen.allSatisfy { $0.1 == final }, "Neither stop returns before the file is written: \(seen.map(\.1)).")
    }

    /// A discard ends the recording and keeps nothing.
    public static func aDiscardRemovesTheRecording(_ make: @Sendable () async throws -> RecorderSubject) async throws {
        let subject = try await make()
        let request = request()
        let session = try await subject.recorder.start(request)
        await session.discard()
        let after = await session.stop()
        #expect(after.ending == .discarded && after.frames == 0 && after.workingFile == nil, "Nothing is kept.")
        #expect(!subject.exists(subject.locations.recordingAudio(request.captureID, format: .caf)))
        #expect(!subject.exists(subject.locations.recordingManifest(request.captureID)))
    }

    /// Recovery finishes recordings of earlier launches and never one of the current launch.
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
        #expect(await session.stop().ending == .stopped, "It records on.")
    }
}
