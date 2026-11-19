import Foundation
import KnotCore
import Testing

/// The contract suite of `Recorder` (docs/architecture.md §5 and §8). The factory makes a
/// recorder whose injected source delivers audio; the real recorder runs it in KnotAudio's
/// tests on injected audio, never on a microphone.
public enum RecorderContract {
    public static func run(_ make: @Sendable () async -> any Recorder) async throws {
        try await aRecordingStreamsAndStops(make)
        try await aStopIsFinalAndCannotBeCancelled(make)
        try await aDiscardRemovesTheRecording(make)
        try await recoveryNeverTouchesTheCurrentLaunch(make)
    }

    /// A start returns a live session; levels, durable counts and live audio arrive; the stop
    /// returns once the file is on the drive; the events end with exactly one `.ended`.
    public static func aRecordingStreamsAndStops(_ make: @Sendable () async -> any Recorder) async throws {
        let recorder = await make()
        await recorder.prepare()
        await recorder.prepare()
        let request = RecordingRequest(captureID: Identifier(uuid: UUID()), launchID: Identifier(uuid: UUID()))
        let session = try await recorder.start(request)
        #expect(session.captureID == request.captureID)

        var durable: [Int64] = []
        var levels = 0
        for await event in session.events {
            switch event {
            case .level(let peak, let average):
                levels += 1
                #expect((0...1).contains(peak) && (0...1).contains(average), "Levels run from 0 to 1.")
            case .durable(let frames):
                durable.append(frames)
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
        #expect(result.captureID == request.captureID)
        #expect(result.ending == .stopped)
        #expect(result.frames >= (durable.last ?? 0), "What was durable is in the file.")
        #expect(result.sampleRate > 0)
        var endings: [RecordedAudio] = []
        for await event in session.events { if case .ended(let audio) = event { endings.append(audio) } }
        #expect(endings == [result], "The events end with exactly one ending, the stop's result.")
    }

    /// A stop called again returns the same result, and a stop whose caller is cancelled
    /// still finishes.
    public static func aStopIsFinalAndCannotBeCancelled(_ make: @Sendable () async -> any Recorder) async throws {
        let recorder = await make()
        let session = try await recorder.start(
            RecordingRequest(captureID: Identifier(uuid: UUID()), launchID: Identifier(uuid: UUID())))
        let stopping = Task { await session.stop() }
        stopping.cancel()
        let first = await stopping.value
        #expect(first.ending == .stopped, "A cancelled caller does not cancel the stop.")
        #expect(await session.stop() == first, "A second stop returns the same result.")
    }

    /// A discard ends the recording and keeps nothing.
    public static func aDiscardRemovesTheRecording(_ make: @Sendable () async -> any Recorder) async throws {
        let recorder = await make()
        let session = try await recorder.start(
            RecordingRequest(captureID: Identifier(uuid: UUID()), launchID: Identifier(uuid: UUID())))
        await session.discard()
        let after = await session.stop()
        #expect(after.ending == .discarded && after.frames == 0, "After a discard nothing is kept.")
    }

    /// Recovery finishes recordings of earlier launches and never one of the current launch.
    public static func recoveryNeverTouchesTheCurrentLaunch(_ make: @Sendable () async -> any Recorder) async throws {
        let recorder = await make()
        let launch: LaunchID = Identifier(uuid: UUID())
        let session = try await recorder.start(
            RecordingRequest(captureID: Identifier(uuid: UUID()), launchID: launch))
        let recovered = try await recorder.recoverOrphans(currentLaunch: launch)
        #expect(
            !recovered.contains { $0.captureID == session.captureID }, "The current launch's recording is left alone.")
        #expect(recovered.allSatisfy { $0.ending == .recovered })
        #expect(await session.stop().ending == .stopped, "It records on.")
    }
}
