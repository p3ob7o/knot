import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotAudio

extension AudioBufferTests {
    @Test func releasingPreparationLeavesTheInjectedRecordingLive() async throws {
        let folder = try ScratchFolder()
        let input = FailableInput(injected())
        let state = WatchedStateStore(UnavailableRecordingStateStore())
        let live: any Recorder = LiveRecorder(locations: folder.locations, input: input, state: state)

        await live.prepare()
        await live.releasePreparation()
        #expect(input.releasePreparationCount == 1)
        #expect(state.writes.isEmpty)

        await live.prepare()
        let session = try await live.start(request())
        await live.releasePreparation()
        #expect(input.releasePreparationCount == 2)
        #expect(state.phases == [.starting, .recording])

        await durable(atLeast: 1_600, of: session)
        let audio = await session.stop()
        #expect(audio.ending == .stopped && audio.frames >= 1_600)
    }

    /// The live recorder runs the `Recorder` contract suite unchanged, on injected audio: each
    /// subject is a recorder over a store of its own, fed without end until it is stopped, and seen
    /// through the file system, never through the recorder. A file the recorder cannot read is one
    /// whose permissions refuse every reader, as one protected while the device is locked refuses
    /// the recorder, and a file removed without the recorder is removed by the file manager.
    ///
    /// Its cues go to an emitter that records them, and its input is injected audio whose next open
    /// can be made to fail, as a refused microphone fails.
    @Test("The live recorder passes the Recorder contract", .tags(.contract))
    func liveRecorderPassesTheRecorderContract() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        try await RecorderContract.run {
            let locations = StoreLocations.testing(root: try folders.make())
            let cues = RecordingCueEmitter()
            let input = FailableInput(injected())
            let live = LiveRecorder(
                locations: locations, input: input, settings: LiveRecorder.Settings(syncInterval: .milliseconds(20)),
                cues: cues)
            return RecorderSubject(
                recorder: live, locations: locations,
                exists: { FileManager.default.fileExists(atPath: $0.path) },
                size: { url in
                    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
                },
                read: { try? Data(contentsOf: $0) },
                setReadable: { url, readable in
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: readable ? 0o644 : 0], ofItemAtPath: url.path)
                },
                remove: { try? FileManager.default.removeItem(at: $0) }, cues: { cues.cues },
                failNextStart: { input.failNextOpen(with: $0) })
        }
    }
}

/// Injected audio whose next open fails with an error a test gives, as a refused microphone's
/// does.
final class FailableInput: AudioInput {
    private let base: InjectedAudio
    private let failure = Mutex<KnotError?>(nil)
    private let releasedPreparations = Mutex(0)

    init(_ base: InjectedAudio) { self.base = base }

    func failNextOpen(with error: KnotError) { failure.withLock { $0 = error } }

    func prepare() async { await base.prepare() }

    var releasePreparationCount: Int { releasedPreparations.withLock { $0 } }

    func releasePreparation() async {
        releasedPreparations.withLock { $0 += 1 }
        await base.releasePreparation()
    }

    func open() async throws(KnotError) -> any OpenAudioInput {
        let failure = failure.withLock { failure in
            defer { failure = nil }
            return failure
        }
        if let failure { throw failure }
        return try await base.open()
    }
}
