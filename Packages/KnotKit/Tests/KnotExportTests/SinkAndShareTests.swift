import Foundation
import KnotCore
import KnotExport
import KnotFakes
import KnotTestSupport
import Testing

@Suite struct FolderExportSinkTests {
    @Test func anExportLandsInTheFolderItWasGiven() async throws {
        let world = try await GoldenWorld.make()
        let root = try freshFolder().appending(path: "made/for/it", directoryHint: .isDirectory)
        let report = try await world.exporter().export(to: FolderExportSink(root: root))

        let manager = FileManager.default
        let found = try manager.subpathsOfDirectory(atPath: root.path(percentEncoded: false)).sorted()
        #expect(found == (["attachments"] + report.written.map(\.relativePath)).sorted())
        let n1 = try String(contentsOf: root.appending(path: Golden.n1File), encoding: .utf8)
        #expect(n1 == Golden.n1Exported)
        let recording = try Data(
            contentsOf: root.appending(
                path: ExportNames.attachment(GoldenWorld.recordingAsset, kind: .audio).relativePath))
        #expect(recording == (try FixtureBytes.recording()))
    }

    @Test func anExportAgainReplacesItsFilesAndLeavesOthersAlone() async throws {
        let world = try await GoldenWorld.make()
        let root = try freshFolder()
        let other = root.appending(path: "kept.txt")
        try Data("not the export's".utf8).write(to: other)
        let stale = root.appending(path: Golden.n1File)
        try Data("an earlier export".utf8).write(to: stale)

        _ = try await world.exporter().export(to: FolderExportSink(root: root))
        _ = try await world.exporter().export(to: FolderExportSink(root: root))
        #expect(try String(contentsOf: stale, encoding: .utf8) == Golden.n1Exported)
        #expect(try String(contentsOf: other, encoding: .utf8) == "not the export's")
    }

    /// Finding 5: a file of an earlier export is replaced through a new file, never written
    /// over in place, so another name for the old file keeps the old content.
    @Test func aReplacedFileIsANewFile() async throws {
        let world = try await GoldenWorld.make()
        let root = try freshFolder()
        let stale = root.appending(path: Golden.n1File)
        try Data("an earlier export".utf8).write(to: stale)
        let otherName = root.appending(path: "another name.txt")
        try FileManager.default.linkItem(at: stale, to: otherName)

        _ = try await world.exporter().export(to: FolderExportSink(root: root))
        #expect(try String(contentsOf: stale, encoding: .utf8) == Golden.n1Exported)
        #expect(try String(contentsOf: otherName, encoding: .utf8) == "an earlier export")
    }

    /// Finding 2: a symbolic link named `attachments` inside the folder would send the
    /// recordings and drawings to wherever it points. It is refused before anything is written
    /// through it.
    @Test func aLinkWhereTheExportWouldMakeAFolderIsRefused() async throws {
        let world = try await GoldenWorld.make()
        let parent = try freshFolder()
        let root = parent.appending(path: "export", directoryHint: .isDirectory)
        let outside = parent.appending(path: "outside", directoryHint: .isDirectory)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        try manager.createSymbolicLink(
            at: root.appending(path: ExportNames.attachmentsFolder), withDestinationURL: outside)

        let error = await #expect(throws: KnotError.self) {
            try await world.exporter().export(to: FolderExportSink(root: root))
        }
        #expect(error?.code == KnotError.writeFailed.code)
        #expect(try manager.contentsOfDirectory(atPath: outside.path(percentEncoded: false)).isEmpty)
        let link = root.appending(path: ExportNames.attachmentsFolder).path(percentEncoded: false)
        #expect((try? manager.destinationOfSymbolicLink(atPath: link)) != nil)
    }

    /// The folder the caller gives, and the path that leads to it, are the caller's: a root that
    /// is itself a link is written through.
    @Test func aRootThatIsALinkIsTheCallersChoice() async throws {
        let world = try await GoldenWorld.make()
        let parent = try freshFolder()
        let real = parent.appending(path: "real", directoryHint: .isDirectory)
        let link = parent.appending(path: "link", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let report = try await world.exporter().export(to: FolderExportSink(root: link))
        let found = try FileManager.default.subpathsOfDirectory(atPath: real.path(percentEncoded: false)).sorted()
        #expect(found == (["attachments"] + report.written.map(\.relativePath)).sorted())
    }

    /// A link where a file is about to be written is replaced, never followed: the file it
    /// points to stays as it was.
    @Test func aLinkWhereAFileGoesIsReplacedNotFollowed() async throws {
        let world = try await GoldenWorld.make()
        let parent = try freshFolder()
        let root = parent.appending(path: "export", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let victim = parent.appending(path: "victim.txt")
        try Data("keep me".utf8).write(to: victim)
        let placed = root.appending(path: Golden.n1File)
        try FileManager.default.createSymbolicLink(at: placed, withDestinationURL: victim)

        _ = try await world.exporter().export(to: FolderExportSink(root: root))
        #expect(try String(contentsOf: victim, encoding: .utf8) == "keep me")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: placed.path(percentEncoded: false))) == nil)
        #expect(try String(contentsOf: placed, encoding: .utf8) == Golden.n1Exported)
    }

    /// A folder where a file is about to be written stops the export with `write_failed`, and
    /// what the folder holds stays.
    @Test func aFolderWhereAFileGoesFailsAndKeepsItsContents() async throws {
        let world = try await GoldenWorld.make()
        let root = try freshFolder()
        let blocker = root.appending(path: Golden.n1File, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data("inner".utf8).write(to: blocker.appending(path: "inner.txt"))

        let error = await #expect(throws: KnotError.self) {
            try await world.exporter().export(to: FolderExportSink(root: root))
        }
        #expect(error?.code == KnotError.writeFailed.code)
        #expect(try String(contentsOf: blocker.appending(path: "inner.txt"), encoding: .utf8) == "inner")
    }
}

@Suite struct ShareItemTests {
    @Test func aNoteSharesAsTextAndAsMarkdown() throws {
        let n1 = try GoldenWorld.seed()[0]
        let text = ShareItems.text(of: n1)
        #expect(
            text
                == ShareItem(
                    content: .text(Golden.n1Text), typeIdentifier: "public.utf8-plain-text", suggestedName: nil))

        let markdown = ShareItems.markdown(of: n1, timeZone: .gmt)
        #expect(markdown.content == .data(Data(Golden.n1Shared.utf8)))
        #expect(markdown.typeIdentifier == "net.daringfireball.markdown")
        #expect(markdown.suggestedName == Golden.n1File)
    }

    @Test func aRecordingSharesAsItsFileWhenItIsHere() async throws {
        let world = try await GoldenWorld.make()
        let segments = try GoldenWorld.seed()[0].segments
        let voice = try #require(segments.first { $0.id == GoldenWorld.voice })
        let stored = try #require(try await world.assets.find(GoldenWorld.recordingAsset, kind: .audio))

        let item = try #require(try await ShareItems.recording(of: voice, assets: world.assets, timeZone: .gmt))
        #expect(item.content == .file(stored.url))
        #expect(item.typeIdentifier == "public.mpeg-4-audio")
        #expect(item.suggestedName == "2026-11-18 Recording 000000b2.m4a")

        let elsewhere = try #require(segments.first { $0.id == GoldenWorld.voiceElsewhere })
        #expect(try await ShareItems.recording(of: elsewhere, assets: world.assets, timeZone: .gmt) == nil)
        let typed = try #require(segments.first { $0.id == GoldenWorld.typed })
        #expect(try await ShareItems.recording(of: typed, assets: world.assets, timeZone: .gmt) == nil)
    }

    @Test func aDrawingSharesAsItsImageOrElseAsItsData() async throws {
        let world = try await GoldenWorld.make()
        let ink = try #require(try GoldenWorld.seed()[0].segments.first { $0.id == GoldenWorld.ink })
        let stored = try #require(try await world.assets.find(GoldenWorld.drawingAsset, kind: .ink))

        let data = try #require(try await ShareItems.drawing(of: ink, assets: world.assets, timeZone: .gmt))
        #expect(
            data
                == ShareItem(
                    content: .file(stored.url), typeIdentifier: "public.data",
                    suggestedName: "2026-11-18 Drawing 000000b3.drawing"))

        let png = try FixtureBytes.png()
        let images = SetImages([GoldenWorld.drawingAsset: DrawingImage(png: png)])
        let image = try #require(
            try await ShareItems.drawing(of: ink, assets: world.assets, drawings: images, timeZone: .gmt))
        #expect(
            image
                == ShareItem(
                    content: .data(png), typeIdentifier: "public.png", suggestedName: "2026-11-18 Drawing 000000b3.png")
        )
    }
}
