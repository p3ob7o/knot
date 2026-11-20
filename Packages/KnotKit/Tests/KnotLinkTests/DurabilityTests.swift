import Foundation
import KnotCore
import KnotFakes
import KnotLink
import KnotTestSupport
import Testing

/// The working pair in Recording/ is the durable copy of a recording until the outbox's pair
/// is known to be durable (docs/architecture.md §6, rule 7).
@Suite struct DurabilityTests {
    /// The outbox manifest's rename succeeds and the sync of its folder fails, with a full
    /// disk: that admission has not happened. At the next launch, recovery finds the manifest
    /// and its recording in the outbox, and a power cut then drops every name that was never
    /// synced. A complete pair must survive it, and no iPhone acknowledged the capture.
    @Test func aRenameWhoseFolderSyncFailedIsMadeDurableBeforeTheWorkingPairGoes() async throws {
        let harness = LinkHarness()
        let capture: CaptureID = harness.ids.make()
        let fault = UnsyncedNameLayer(harness.outbox.manifestURL(capture))
        let outbox = WatchOutbox(locations: harness.locations, layer: fault)
        harness.system.activatesByItself = false
        let link = OutboxLink(outbox: outbox, transport: harness.system.launch(.watch), clock: harness.clock)
        let recorder = ScriptedRecorder(locations: harness.locations, layer: PosixFileLayer(), clock: harness.clock)
        try recorder.leaveOrphan(capture, launch: harness.ids.make(), frames: 16_000)
        let written = try CaptureManifest.decode(Data(contentsOf: harness.locations.recordingManifest(capture)))
        let converted = try await recorder.convert(
            RecordedAudio(
                captureID: capture, frames: 16_000, sampleRate: 16_000, ending: .recovered,
                workingFile: harness.locations.recordingAudio(capture, format: .caf)))
        // A stop's admission: the rename succeeds and the folder's sync fails.
        let error = await #expect(throws: KnotError.self) { try await link.send(written, file: converted.file) }
        try #require(error?.context.posixError == ENOSPC && fault.unsynced.value)

        // The next launch recovers; the power fails just after it removed the working pair.
        let next = OutboxLink(outbox: outbox, transport: harness.system.launch(.watch), clock: harness.clock)
        let coordinator = WatchCoordinator(
            recorder: recorder, link: next, ids: harness.ids, clock: harness.clock, launchID: harness.ids.make(),
            device: harness.ids.make(),
            killPoint: { point in if point == .workingFileRemoved { fault.cutPower() } })
        await coordinator.launch()

        #expect(!harness.phone.acknowledged(capture))
        let workingPair =
            FileManager.default.fileExists(atPath: harness.locations.recordingManifest(capture).path)
            && FileManager.default.fileExists(atPath: harness.locations.recordingAudio(capture, format: .caf).path)
        let outboxPair = harness.outbox.entry(capture)?.isSendable == true
        #expect(workingPair || outboxPair, "A complete pair survives until an iPhone acknowledges the capture.")
    }
}

/// The POSIX disk, except for one name: its first folder sync after the rename that made it
/// fails with a full disk, and until a sync succeeds, a power cut takes the name away.
final class UnsyncedNameLayer: FileLayer {
    let real = PosixFileLayer()
    let url: URL
    let unsynced = Box(false)
    private let failedOnce = Box(false)

    init(_ url: URL) { self.url = url }

    func createFolder(_ url: URL) throws(KnotError) { try real.createFolder(url) }
    func write(_ data: Data, to url: URL) throws(KnotError) { try real.write(data, to: url) }
    func syncFile(_ url: URL) throws(KnotError) { try real.syncFile(url) }

    func rename(_ source: URL, to destination: URL) throws(KnotError) {
        try real.rename(source, to: destination)
        if destination.path == url.path { unsynced.update { $0 = true } }
    }

    func syncFolder(_ folder: URL) throws(KnotError) {
        guard folder.path == url.deletingLastPathComponent().path, unsynced.value else {
            return try real.syncFolder(folder)
        }
        if !failedOnce.value {
            failedOnce.update { $0 = true }
            throw KnotError.writeFailed.with(ErrorContext(posixError: ENOSPC))
        }
        try real.syncFolder(folder)
        unsynced.update { $0 = false }
    }

    func remove(_ url: URL) throws(KnotError) { try real.remove(url) }
    func read(_ url: URL) throws(KnotError) -> Data { try real.read(url) }
    func exists(_ url: URL) -> Bool { real.exists(url) }
    func entryKind(_ url: URL) -> FileEntryKind? { real.entryKind(url) }
    func contents(of folder: URL) throws(KnotError) -> [String] { try real.contents(of: folder) }

    /// The power fails: a name never synced is gone.
    func cutPower() {
        guard unsynced.value else { return }
        try? FileManager.default.removeItem(at: url)
        unsynced.update { $0 = false }
    }
}
