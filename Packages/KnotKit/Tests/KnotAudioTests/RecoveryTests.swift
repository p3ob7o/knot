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

    /// A working file closed whole and then cut short, as a power cut between its close and its
    /// final sync can leave it, is read to the last complete frame on the drive, whatever its
    /// header says: every reader answers the frames the file holds, every one of them the audio
    /// written, and recovery returns those. After finding 19.
    @Test func aClosedFileCutShortIsReadToWhatTheDriveHolds() async throws {
        let folder = try ScratchFolder()
        let request = request()
        try writeManifest(folder.locations, request)
        let working = folder.locations.recordingAudio(request.captureID, format: .caf)
        _ = try writeWorkingFile(at: working, frames: 12_345)
        try cut(working, insideFrame: 10_001)
        #expect(WorkingFileReader.inspect(working) == .read(.init(frames: 10_000, sampleRate: 16_000)))
        #expect(WorkingFileReader.contents(of: working)?.frames == 10_000)
        #expect(WorkingFileReader.samples(of: working) == synthetic(10_000))
        let recorder = recorder(folder.locations, input: injected())
        for _ in 1...2 {
            let orphans = try await recorder.recoverOrphans(currentLaunch: LaunchID(uuid: UUID()))
            #expect(orphans.map(\.frames) == [10_000] && orphans.first?.workingFile == working, "\(orphans)")
        }
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
        case .cutInsideItsHeader:
            // The first 20 bytes of a real working file: its file header and part of a chunk's.
            let whole = folder.url.appendingPathComponent("whole.caf")
            _ = try writeWorkingFile(at: whole, frames: 1_600)
            try Data(try Data(contentsOf: whole).prefix(20)).write(to: working)
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

    /// A working file that is there and cannot be read now is no verdict on its audio: it is not
    /// returned, it and its manifest stay, and it comes back whole once it can be read.
    @Test func aWorkingFileThatCannotBeReadIsLeftAlone() async throws {
        let folder = try ScratchFolder()
        let earlier = recorder(folder.locations, input: FloatInput(frames: 16_000))
        let request = request()
        let stopped = await (try await earlier.start(request)).stop()
        let working = try #require(stopped.workingFile)
        let later = recorder(folder.locations, input: injected())
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: working.path)
        let whileLocked = try await later.recoverOrphans(currentLaunch: LaunchID(uuid: UUID()))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: working.path)
        #expect(!whileLocked.contains { $0.captureID == request.captureID }, "\(whileLocked)")
        #expect(exists(working) && exists(folder.locations.recordingManifest(request.captureID)))
        let afterwards = try await later.recoverOrphans(currentLaunch: LaunchID(uuid: UUID()))
        #expect(afterwards == [stopped], "Once it can be read, it comes back as it ended: \(afterwards)")
    }

    /// A working file that opens and is not audio is left alone too, and the others come back.
    @Test func aWorkingFileThatIsNotAudioIsLeftAlone() async throws {
        let folder = try ScratchFolder()
        let damaged = request()
        let readable = request()
        try writeManifest(folder.locations, damaged)
        try writeManifest(folder.locations, readable)
        let working = folder.locations.recordingAudio(damaged.captureID, format: .caf)
        try Data(repeating: 0x2A, count: 8_192).write(to: working)
        let orphans = try await recorder(folder.locations, input: injected())
            .recoverOrphans(currentLaunch: LaunchID(uuid: UUID()))
        #expect(orphans.map(\.captureID) == [readable.captureID])
        #expect(exists(working) && exists(folder.locations.recordingManifest(damaged.captureID)))
    }

    /// A manifest's partial file, which a death inside its placement leaves, is removed by
    /// recovery: nothing is left in `Recording/` once the recording's files are removed.
    @Test func aPartialManifestIsRemoved() async throws {
        let folder = try ScratchFolder()
        let request = request()
        try writeManifest(folder.locations, request)
        _ = try writeWorkingFile(at: folder.locations.recordingAudio(request.captureID, format: .caf), frames: 1_600)
        let partial = folder.locations.recording.appendingPathComponent(
            ".\(request.captureID).json.\(UUID().uuidString.lowercased())\(DurableFile.partialSuffix)")
        try Data("{\"half".utf8).write(to: partial)
        let recorder = recorder(folder.locations, input: injected())
        let orphans = try await recorder.recoverOrphans(currentLaunch: LaunchID(uuid: UUID()))
        #expect(orphans.map(\.captureID) == [request.captureID])
        #expect(!exists(partial))
        try await recorder.removeWorkingFile(of: request.captureID)
        #expect(recordingFolder(folder.locations).isEmpty, "\(recordingFolder(folder.locations))")
    }

    /// A partial file of a recording that is live in this process may be its manifest being
    /// placed, and stays.
    @Test func aPartialOfALiveRecordingStays() async throws {
        let folder = try ScratchFolder()
        let launch = LaunchID(uuid: UUID())
        let recorder = recorder(folder.locations, input: injected())
        let request = request(launch)
        let session = try await recorder.start(request)
        let partial = folder.locations.recording.appendingPathComponent(
            ".\(request.captureID).json.\(UUID().uuidString.lowercased())\(DurableFile.partialSuffix)")
        try Data("{\"half".utf8).write(to: partial)
        _ = try await recorder.recoverOrphans(currentLaunch: launch)
        #expect(exists(partial))
        _ = await session.stop()
    }

    /// A recording live in this process for another launch, which only a test makes, is ended
    /// by recovery as that launch's death would end it: its input stops, its frames no longer
    /// change, and its stop answers with the recovery's ending and the frames recovery returned.
    @Test func recoveryEndsALiveRecordingOfAnotherLaunch() async throws {
        let folder = try ScratchFolder()
        let delivered = Tally()
        let input = InjectedAudio(
            sampleRate: 16_000, framesPerBuffer: 1_600, pace: .every(.milliseconds(2)), delivered: { delivered.set($0) }
        )
        let recorder = recorder(folder.locations, input: input)
        let earlier = request()
        let session = try await recorder.start(earlier)
        await durable(atLeast: 1_600, of: session)
        let orphans = try await recorder.recoverOrphans(currentLaunch: LaunchID(uuid: UUID()))
        let orphan = try #require(orphans.first { $0.captureID == earlier.captureID })
        let afterRecovery = delivered.value
        let audio = await session.stop()
        #expect(audio.ending == .recovered, "Recovery did not end it: \(audio)")
        #expect(audio.frames == orphan.frames && orphan.frames > 0, "\(audio.frames) after \(orphan.frames)")
        #expect(delivered.value == afterRecovery, "Its input went on after recovery.")
    }

    /// The orphan is the working file: one whose manifest is gone comes back, as `recovered` and
    /// read to its end, and its removal takes it.
    @Test func aWorkingFileWithNoManifestComesBack() async throws {
        let folder = try ScratchFolder()
        let capture = CaptureID(uuid: UUID())
        let working = folder.locations.recordingAudio(capture, format: .caf)
        _ = try writeWorkingFile(at: working, frames: 12_000, close: false)
        let recorder = recorder(folder.locations, input: injected())
        let orphans = try await recorder.recoverOrphans(currentLaunch: LaunchID(uuid: UUID()))
        #expect(
            orphans == [
                RecordedAudio(
                    captureID: capture, frames: 12_000, sampleRate: 16_000, ending: .recovered, workingFile: working)
            ], "\(orphans)")
        try await recorder.removeWorkingFile(of: capture)
        #expect(recordingFolder(folder.locations).isEmpty)
    }

    /// A manifest that cannot be read no longer hides its recording: the working file comes back
    /// as `recovered`, and the manifest is left where it is.
    @Test func aWorkingFileWithAnUnreadableManifestComesBack() async throws {
        let folder = try ScratchFolder()
        let capture = CaptureID(uuid: UUID())
        let working = folder.locations.recordingAudio(capture, format: .caf)
        _ = try writeWorkingFile(at: working, frames: 8_000)
        let manifest = folder.locations.recordingManifest(capture)
        try Data("{not a manifest".utf8).write(to: manifest)
        let orphans = try await recorder(folder.locations, input: injected())
            .recoverOrphans(currentLaunch: LaunchID(uuid: UUID()))
        #expect(orphans.map(\.captureID) == [capture] && orphans.first?.ending == .recovered)
        #expect(orphans.first?.frames == 8_000 && orphans.first?.workingFile == working)
        #expect(exists(manifest))
    }

    /// A working file of a recording live in this process is the current launch's, even with its
    /// manifest gone: it is never returned.
    @Test func aLiveRecordingWithNoManifestIsLeftAlone() async throws {
        let folder = try ScratchFolder()
        let launch = LaunchID(uuid: UUID())
        let recorder = recorder(folder.locations, input: injected())
        let request = request(launch)
        let session = try await recorder.start(request)
        try FileManager.default.removeItem(at: folder.locations.recordingManifest(request.captureID))
        let orphans = try await recorder.recoverOrphans(currentLaunch: launch)
        #expect(!orphans.contains { $0.captureID == request.captureID }, "\(orphans)")
        #expect(await session.stop().ending == .stopped, "It records on.")
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
