import AVFAudio
import Foundation
import KnotCore
import KnotTestSupport
import Testing

@testable import KnotAudio

/// Recovery of the recordings that earlier launches left in `Recording/`, read by a recorder
/// that did not record them, as the next launch's is.
@Suite struct RecoveryTests {
    /// A recording that stopped and was never converted comes back as it ended, `stopped`, read
    /// to its end by a recorder of another launch; one that never ended comes back `recovered`.
    @Test func aStoppedOrphanComesBackStopped() async throws {
        let folder = try ScratchFolder()
        let earlier = recorder(folder.locations, input: injected(frames: 8_000))
        let request = request()
        let session = try await earlier.start(request)
        await durable(atLeast: 8_000, of: session)
        let stopped = await session.stop()

        let later = recorder(folder.locations, input: injected())
        let orphans = try await later.recoverOrphans(currentLaunch: LaunchID(uuid: UUID()))
        #expect(orphans == [stopped], "Exactly the stopped recording, as it ended: \(orphans)")
    }

    /// A working file that a death left open is read to its last complete frame: a frame cut in
    /// half by the kill is not counted, and every whole one is the audio written.
    @Test func aKilledFileIsReadToItsLastCompleteFrame() async throws {
        let folder = try ScratchFolder()
        let request = request()
        try writeManifest(folder.locations, request)
        let working = folder.locations.recordingAudio(request.captureID, format: .caf)
        let scratch = folder.url.appendingPathComponent("open.caf")
        // A file still open, as a killed process leaves it: its data chunk has no size yet.
        let open = try writeWorkingFile(at: scratch, frames: 12_345, close: false)
        var bytes = try Data(contentsOf: scratch)
        bytes.append(0x7F)  // Half of one more frame.
        try bytes.write(to: working)
        open.close()

        let orphans = try await recorder(folder.locations, input: injected())
            .recoverOrphans(currentLaunch: LaunchID(uuid: UUID()))
        #expect(orphans.count == 1)
        let orphan = try #require(orphans.first)
        #expect(orphan.captureID == request.captureID && orphan.ending == .recovered)
        #expect(orphan.frames == 12_345 && orphan.sampleRate == 16_000 && orphan.workingFile == working)
        #expect(WorkingFileReader.samples(of: working) == synthetic(12_345))
    }

    /// A manifest whose audio is missing, cut inside its header, or only a header is a
    /// recording with no audio: it comes back, so that its capture ends and its manifest goes.
    @Test(arguments: [AudioLeft.none, .cutInsideItsHeader, .headerOnly])
    func aRecordingWithNoAudioComesBack(left: AudioLeft) async throws {
        let folder = try ScratchFolder()
        let request = request()
        try writeManifest(folder.locations, request)
        let working = folder.locations.recordingAudio(request.captureID, format: .caf)
        switch left {
        case .none: break
        case .cutInsideItsHeader: try Data(repeating: 0x63, count: 20).write(to: working)
        case .headerOnly: _ = try writeWorkingFile(at: working, frames: 0, close: false)
        }
        let orphans = try await recorder(folder.locations, input: injected())
            .recoverOrphans(currentLaunch: LaunchID(uuid: UUID()))
        #expect(orphans.map(\.captureID) == [request.captureID])
        #expect(orphans.first?.frames == 0 && orphans.first?.ending == .recovered)
        // Only a file that reads as audio is named, even with no frame in it.
        #expect((orphans.first?.workingFile != nil) == (left == .headerOnly))
    }

    /// A manifest that cannot be read is left where it is, and the others still come back.
    @Test func anUnreadableManifestIsLeftAlone() async throws {
        let folder = try ScratchFolder()
        let readable = request()
        try writeManifest(folder.locations, readable)
        let damaged = folder.locations.recordingManifest(CaptureID(uuid: UUID()))
        try Data("{not a manifest".utf8).write(to: damaged)
        let orphans = try await recorder(folder.locations, input: injected())
            .recoverOrphans(currentLaunch: LaunchID(uuid: UUID()))
        #expect(orphans.map(\.captureID) == [readable.captureID])
        #expect(exists(damaged), "Never removed: an update may read it.")
    }

    /// The current launch's manifest is never touched, even with no session behind it.
    @Test func theCurrentLaunchsManifestIsLeftAlone() async throws {
        let folder = try ScratchFolder()
        let launch = LaunchID(uuid: UUID())
        let current = request(launch)
        try writeManifest(folder.locations, current)
        let orphans = try await recorder(folder.locations, input: injected()).recoverOrphans(currentLaunch: launch)
        #expect(orphans.isEmpty)
        #expect(exists(folder.locations.recordingManifest(current.captureID)))
    }

    /// Orphans come back in the order of their IDs, once each, with nothing in `Recording/`
    /// taken for one that is not a manifest of a recording.
    @Test func orphansComeBackOnceEachInOrder() async throws {
        let folder = try ScratchFolder()
        let requests = (0..<4).map { _ in request() }
        for request in requests { try writeManifest(folder.locations, request) }
        try Data().write(to: folder.locations.recording.appendingPathComponent("notes.json"))
        let orphans = try await recorder(folder.locations, input: injected())
            .recoverOrphans(currentLaunch: LaunchID(uuid: UUID()))
        #expect(orphans.map(\.captureID) == requests.map(\.captureID).sorted())
    }

    /// No `Recording/` folder yet: nothing to recover.
    @Test func anEmptyStoreHasNoOrphans() async throws {
        let folder = try ScratchFolder()
        #expect(
            try await recorder(folder.locations, input: injected()).recoverOrphans(
                currentLaunch: LaunchID(uuid: UUID())
            ).isEmpty)
    }

    enum AudioLeft: String, Sendable, CaseIterable {
        case none
        case cutInsideItsHeader
        case headerOnly
    }
}
