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
}

@Suite struct ShareItemTests {
    @Test func aNoteSharesAsTextAndAsMarkdown() throws {
        let n1 = try GoldenWorld.seed()[0]
        let text = ShareItems.text(of: n1)
        #expect(
            text
                == ShareItem(
                    content: .text(Golden.n1Text), typeIdentifier: "public.utf8-plain-text", suggestedName: nil))

        let markdown = ShareItems.markdown(of: n1)
        #expect(markdown.content == .data(Data(Golden.n1Shared.utf8)))
        #expect(markdown.typeIdentifier == "net.daringfireball.markdown")
        #expect(markdown.suggestedName == Golden.n1File)
    }

    @Test func aRecordingSharesAsItsFileWhenItIsHere() async throws {
        let world = try await GoldenWorld.make()
        let segments = try GoldenWorld.seed()[0].segments
        let voice = try #require(segments.first { $0.id == GoldenWorld.voice })
        let stored = try #require(try await world.assets.find(GoldenWorld.recordingAsset, kind: .audio))

        let item = try #require(try await ShareItems.recording(of: voice, assets: world.assets))
        #expect(item.content == .file(stored.url))
        #expect(item.typeIdentifier == "public.mpeg-4-audio")
        #expect(item.suggestedName == "2026-11-18 Recording 000000b2.m4a")

        let elsewhere = try #require(segments.first { $0.id == GoldenWorld.voiceElsewhere })
        #expect(try await ShareItems.recording(of: elsewhere, assets: world.assets) == nil)
        let typed = try #require(segments.first { $0.id == GoldenWorld.typed })
        #expect(try await ShareItems.recording(of: typed, assets: world.assets) == nil)
    }

    @Test func aDrawingSharesAsItsImageOrElseAsItsData() async throws {
        let world = try await GoldenWorld.make()
        let ink = try #require(try GoldenWorld.seed()[0].segments.first { $0.id == GoldenWorld.ink })
        let stored = try #require(try await world.assets.find(GoldenWorld.drawingAsset, kind: .ink))

        let data = try #require(try await ShareItems.drawing(of: ink, assets: world.assets))
        #expect(
            data
                == ShareItem(
                    content: .file(stored.url), typeIdentifier: "public.data",
                    suggestedName: "2026-11-18 Drawing 000000b3.drawing"))

        let png = try FixtureBytes.png()
        let images = SetImages([GoldenWorld.drawingAsset: DrawingImage(png: png)])
        let image = try #require(try await ShareItems.drawing(of: ink, assets: world.assets, drawings: images))
        #expect(
            image
                == ShareItem(
                    content: .data(png), typeIdentifier: "public.png", suggestedName: "2026-11-18 Drawing 000000b3.png")
        )
    }
}
