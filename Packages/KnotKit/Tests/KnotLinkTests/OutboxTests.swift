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
    /// The checksum covers the whole recording, read in pieces: a payload one mebibyte and
    /// two bytes long.
    @Test func theChecksumCoversTheWholeRecording() throws {
        let harness = LinkHarness()
        var bytes = Data(repeating: 1, count: 1 << 20)
        bytes.append(contentsOf: [0x15, 0x27])
        let (manifest, url) = try harness.convertedRecording(bytes: bytes)
        let admitted = try harness.outbox.admit(manifest, recording: url)
        #expect(admitted.payloadSHA256 == sha256(bytes))
        #expect(admitted.payloadByteCount == Int64(bytes.count))
    }

    /// Removal takes the manifest first: when the recording cannot be removed, the manifest
    /// is already gone, as the code does it, not as a test builds it.
    @Test func removalTakesTheManifestBeforeTheRecording() throws {
        let harness = LinkHarness()
        let (manifest, url) = try harness.convertedRecording()
        try harness.outbox.admit(manifest, recording: url)
        let recording = harness.outbox.recordingURL(manifest.captureID)
        // A folder that is not empty in the recording's place makes its removal fail.
        try FileManager.default.removeItem(at: recording)
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: false)
        try Data([1]).write(to: recording.appending(path: "synthetic"))
        #expect(throws: KnotError.self) { try harness.outbox.remove(manifest.captureID) }
        #expect(!FileManager.default.fileExists(atPath: harness.outbox.manifestURL(manifest.captureID).path))
    }
    /// What a kill leaves at each point of an acknowledged capture's removal while its working
    /// files are still in Recording/, and what the sweep then does.
    @Test(arguments: ["after the marker", "after the manifest", "after the recording"])
    func anAcknowledgedCapturesRemovalCutShortIsFinishedAndNeverShownAgain(_ point: String) throws {
        let harness = LinkHarness()
        let (manifest, url) = try harness.convertedRecording()
        let capture = manifest.captureID
        try harness.outbox.admit(manifest, recording: url)
        let working = harness.locations.recordingManifest(capture)
        try harness.files.place(try manifest.encoded(), at: working)

        // The removal as remove(_:) makes it, stopped at `point`.
        try harness.files.place(Data(), at: harness.outbox.acknowledgedURL(capture))
        if point != "after the marker" { try FileManager.default.removeItem(at: harness.outbox.manifestURL(capture)) }
        if point == "after the recording" {
            try FileManager.default.removeItem(at: harness.outbox.recordingURL(capture))
        }
        #expect(harness.outbox.wasAcknowledged(capture))
        #expect(harness.outbox.entry(capture) == nil, "The marker hides what is left of the entry.")
        #expect(try harness.outbox.entries().isEmpty)

        // While the working files remain, the sweep keeps the marker.
        try harness.outbox.sweep()
        #expect(harness.outbox.wasAcknowledged(capture))
        #expect(!harness.outbox.holdsRecording(capture))
        #expect(!FileManager.default.fileExists(atPath: harness.outbox.manifestURL(capture).path))

        // Once recovery has removed them, the sweep forgets the capture.
        try FileManager.default.removeItem(at: working)
        try harness.outbox.sweep()
        #expect(!harness.outbox.wasAcknowledged(capture))
        #expect(try FileManager.default.contentsOfDirectory(atPath: harness.locations.outbox.path).isEmpty)
    }

    /// The marker is written only while something of the capture is in Recording/.
    @Test func anAcknowledgedCaptureWithNothingInRecordingLeavesNoMarker() throws {
        let harness = LinkHarness()
        let (manifest, url) = try harness.convertedRecording()
        try harness.outbox.admit(manifest, recording: url)
        try harness.outbox.remove(manifest.captureID)
        #expect(!harness.outbox.wasAcknowledged(manifest.captureID))
        #expect(try FileManager.default.contentsOfDirectory(atPath: harness.locations.outbox.path).isEmpty)
    }
    /// The fourth state a kill can leave: the marker alone, after recovery removed the
    /// leftovers or in the sweep between the entry and the marker. It hides nothing, counts
    /// nothing and is removed by the next sweep.
    @Test func aMarkerLeftAloneIsHarmlessAndTheNextSweepRemovesIt() async throws {
        let harness = LinkHarness()
        let capture: CaptureID = harness.ids.make()
        try harness.files.place(Data(), at: harness.outbox.acknowledgedURL(capture))
        #expect(try harness.outbox.entries().isEmpty)
        let (link, _) = harness.launchWatch()
        await link.resume()
        await harness.settle(link)
        #expect(await link.currentCounts() == (waiting: 0, failed: 0))
        #expect(harness.system.timesQueued(capture) == 0)
        try harness.outbox.sweep()
        #expect(!harness.outbox.wasAcknowledged(capture))
    }
}
