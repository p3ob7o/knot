import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@Suite @MainActor struct NoteAttachmentTests {
    @Test func openingANoteRequestsItsRemoteAttachment() async throws {
        let rig = StoreRig()
        let receipt = try await rig.recording(at: rig.clock.now(), availability: .remote)
        let segment = try #require(try await rig.notes.segment(SegmentID(receipt.captureID)))
        let asset = try #require(segment.assetID)
        let fetcher = ScriptedAssetFetcher()
        fetcher.scriptRemote(asset)
        rig.environment.fetcher = fetcher
        let model = rig.open(receipt.noteID)
        await model.refresh()

        #expect(model.remoteAttachmentIDs == [asset])
        await model.fetchAttachments()
        #expect(fetcher.fetchCount == 1)
    }

    @Test func sharingFindsTheFileOfTheSelectedSegment() async throws {
        let rig = StoreRig()
        let receipt = try await rig.recording(at: rig.clock.now())
        let segment = try #require(try await rig.notes.segment(SegmentID(receipt.captureID)))
        let asset = try #require(segment.assetID)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = FileAssetStore(locations: .testing(root: root), layer: PosixFileLayer())
        let file = try await assets.place(Data([1, 2, 3]), as: asset, kind: .audio)
        rig.environment.assets = assets
        let model = rig.open(receipt.noteID)
        await model.refresh()

        let share = try await model.shareFile(segment.id, timeZone: .gmt)
        #expect(share?.content == .file(file.url))
        #expect(share?.suggestedName?.hasSuffix(".m4a") == true)
    }
}
