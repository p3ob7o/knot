import Foundation
import KnotCore
import KnotFakes
import KnotLink
import KnotTestSupport
import Testing

@Suite struct WatchOutboxTests {
    @Test func admittingMovesTheRecordingInAndPlacesItsManifestWithTheChecksum() throws {
        let harness = LinkHarness()
        let bytes = Data("synthetic audio".utf8)
        let (manifest, url) = try harness.convertedRecording(bytes: bytes)
        let capture = manifest.captureID
        let admitted = try harness.outbox.admit(manifest, recording: url)

        #expect(!FileManager.default.fileExists(atPath: url.path), "The converted file moved, it was not copied.")
        #expect(try Data(contentsOf: harness.outbox.recordingURL(capture)) == bytes)
        #expect(admitted.payloadSHA256 == sha256(bytes))
        #expect(admitted.payloadByteCount == Int64(bytes.count))
        let entry = try #require(harness.outbox.entry(capture))
        #expect(entry.manifest == admitted && entry.hasRecording && entry.isSendable)
        #expect(try harness.outbox.entries().map(\.captureID) == [capture])
    }

    @Test func admittingAgainChangesNothing() throws {
        let harness = LinkHarness()
        let (manifest, url) = try harness.convertedRecording()
        let first = try harness.outbox.admit(manifest, recording: url)
        var later = manifest
        later.revision = 9
        #expect(try harness.outbox.admit(later, recording: url) == first)
    }

    @Test func aRecordingThatIsNowhereIsRefusedAndNothingIsPlaced() throws {
        let harness = LinkHarness()
        let (manifest, url) = try harness.convertedRecording()
        try FileManager.default.removeItem(at: url)
        let error = #expect(throws: KnotError.self) { try harness.outbox.admit(manifest, recording: url) }
        #expect(error?.code == KnotError.writeFailed.code && error?.context.posixError == ENOENT)
        #expect(harness.outbox.entry(manifest.captureID) == nil)
    }

    @Test func aKillBetweenTheTwoStepsIsFinishedByAdmittingAgain() throws {
        let harness = LinkHarness()
        let (manifest, url) = try harness.convertedRecording()
        // The recording moved in, then the manifest was never placed.
        try harness.files.move(url, to: harness.outbox.recordingURL(manifest.captureID))
        #expect(harness.outbox.entry(manifest.captureID) == nil)
        let admitted = try harness.outbox.admit(manifest, recording: url)
        #expect(admitted.payloadSHA256 != nil)
        #expect(harness.outbox.entry(manifest.captureID)?.isSendable == true)
    }

    @Test func removingTakesTheManifestFirstAndSweepClearsTheRecordingLeft() throws {
        let harness = LinkHarness()
        let (manifest, url) = try harness.convertedRecording()
        try harness.outbox.admit(manifest, recording: url)
        // A removal cut short after its first step.
        try FileManager.default.removeItem(at: harness.outbox.manifestURL(manifest.captureID))
        try harness.outbox.sweep()
        #expect(!FileManager.default.fileExists(atPath: harness.outbox.recordingURL(manifest.captureID).path))
        #expect(try harness.outbox.entries().isEmpty)
    }

    @Test func sweepLeavesARecordingWhoseCaptureIsStillInRecording() throws {
        let harness = LinkHarness()
        let (manifest, url) = try harness.convertedRecording()
        let capture = manifest.captureID
        try harness.files.place(try manifest.encoded(), at: harness.locations.recordingManifest(capture))
        try harness.files.move(url, to: harness.outbox.recordingURL(capture))
        try harness.outbox.sweep()
        #expect(FileManager.default.fileExists(atPath: harness.outbox.recordingURL(capture).path))
    }

    @Test func aMissingRecordingOrAnUnreadableManifestCannotBeSent() throws {
        let harness = LinkHarness()
        let (first, firstURL) = try harness.convertedRecording()
        let (second, secondURL) = try harness.convertedRecording()
        try harness.outbox.admit(first, recording: firstURL)
        try harness.outbox.admit(second, recording: secondURL)
        try FileManager.default.removeItem(at: harness.outbox.recordingURL(first.captureID))
        try Data("not json".utf8).write(to: harness.outbox.manifestURL(second.captureID))
        let entries = try harness.outbox.entries()
        #expect(entries.count == 2, "Both manifests stay on the watch.")
        #expect(entries.allSatisfy { !$0.isSendable })
    }

    @Test func aFileWhoseNameIsNotACaptureIDIsLeftAlone() throws {
        let harness = LinkHarness()
        try harness.files.makeFolder(harness.locations.outbox)
        let stranger = harness.locations.outbox.appending(path: "notes.json")
        try Data("{}".utf8).write(to: stranger)
        #expect(try harness.outbox.entries().isEmpty)
        try harness.outbox.sweep()
        #expect(FileManager.default.fileExists(atPath: stranger.path))
    }
}
