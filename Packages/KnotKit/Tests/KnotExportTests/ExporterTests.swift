import Foundation
import KnotCore
import KnotExport
import KnotFakes
import KnotTestSupport
import Testing

@Suite struct ExporterTests {
    @Test func anExportMatchesItsGoldenFiles() async throws {
        let world = try await GoldenWorld.make()
        let sink = MemoryExportSink()
        let report = try await world.exporter().export(to: sink)

        #expect(sink.text(Golden.n1File) == Golden.n1Exported)
        #expect(sink.text(Golden.n2File) == Golden.n2Exported)
        #expect(
            sink.order.map(\.relativePath) == [
                "attachments/019a9b3c-7e00-7000-8000-0000000000a2.m4a",
                "attachments/019a9b3c-7e00-7000-8000-0000000000a3.drawing",
                Golden.n1File,
                Golden.n2File,
            ])
        #expect(report.written == sink.order)
        #expect(report.notes == 2)
        #expect(sink.files.values.contains(try FixtureBytes.recording()))
        #expect(sink.files.values.contains(try FixtureBytes.drawing()))
    }

    @Test func theListNamesWhatIsNotHereAndTheDrawingWrittenAsData() async throws {
        let world = try await GoldenWorld.make()
        let report = try await world.exporter().export(to: MemoryExportSink())
        #expect(
            report.leftOut == [
                LeftOut(
                    note: GoldenWorld.n1, segment: GoldenWorld.ink, asset: GoldenWorld.drawingAsset, kind: .ink,
                    reason: .drawingWithoutImage(ExportNames.attachment(GoldenWorld.drawingAsset, kind: .ink))),
                LeftOut(
                    note: GoldenWorld.n1, segment: GoldenWorld.voiceElsewhere, asset: GoldenWorld.elsewhereAsset,
                    kind: .audio, reason: .notOnThisDevice),
            ])
        #expect(report.leftOut.map(\.isMissing) == [false, true])
    }

    @Test func aDrawingWithItsImageLeavesAsTheImage() async throws {
        let world = try await GoldenWorld.make()
        let png = try FixtureBytes.png()
        let images = SetImages([GoldenWorld.drawingAsset: DrawingImage(png: png)])
        let sink = MemoryExportSink()
        let report = try await world.exporter(drawings: images).export(to: sink)

        #expect(sink.text(Golden.n1File) == Golden.n1ExportedWithImage)
        #expect(sink.files[ExportNames.drawingImage(GoldenWorld.drawingAsset)] == png)
        #expect(sink.files[ExportNames.attachment(GoldenWorld.drawingAsset, kind: .ink)] == nil)
        #expect(report.leftOut.map(\.reason) == [.notOnThisDevice])
    }

    @Test func anImageThatIsNotAPNGLeavesTheDrawingAsItsData() async throws {
        let world = try await GoldenWorld.make()
        let images = SetImages([GoldenWorld.drawingAsset: DrawingImage(png: try FixtureBytes.drawing())])
        let sink = MemoryExportSink()
        let report = try await world.exporter(drawings: images).export(to: sink)

        #expect(sink.text(Golden.n1File) == Golden.n1Exported)
        #expect(sink.files[ExportNames.drawingImage(GoldenWorld.drawingAsset)] == nil)
        #expect(report.leftOut.count == 2)
    }

    @Test func thePreviewSaysWhatIsMissingWritesNothingAndAsksForNoImage() async throws {
        let world = try await GoldenWorld.make()
        let images = SetImages([:])
        let before = try FileManager.default.subpathsOfDirectory(atPath: world.root.path(percentEncoded: false))
        let preview = try await world.exporter(drawings: images).preview()

        #expect(preview.notes == 2)
        #expect(preview.files == 2)
        #expect(
            preview.missing == [
                LeftOut(
                    note: GoldenWorld.n1, segment: GoldenWorld.voiceElsewhere, asset: GoldenWorld.elsewhereAsset,
                    kind: .audio, reason: .notOnThisDevice)
            ])
        #expect(images.askedCount == 0)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: world.root.path(percentEncoded: false)) == before)
    }

    /// A recording that sync knows of, by its row, but whose file has not come down: the row
    /// says where it is. One whose file is here leaves, whatever its row says.
    @Test func aRowThatSaysElsewhereIsBelievedOnlyWhenTheFileIsNotHere() async throws {
        let world = try World()
        let audio = try FixtureBytes.recording()
        var receipts: [SegmentID] = []
        for (number, placeFile) in [(UInt64(0xc1), false), (0xc2, true)] {
            let capture: CaptureID = fixedID(number)
            let asset: AssetID = fixedID(number + 0x100)
            if placeFile { _ = try await world.assets.place(audio, as: asset, kind: .audio) }
            let row = Asset(
                id: asset, segmentID: SegmentID(capture), kind: .audio, byteCount: Int64(audio.count),
                sha256: String(repeating: "ab", count: 32), availability: .remote, upload: .published)
            let start = t0.addingTimeInterval(Double(number))
            _ = try await world.notes.record(
                NewCapture(
                    id: capture, kind: .voice, origin: CaptureOrigin(source: .device(thisDevice), surface: .app),
                    launchID: fixedID(0x99), placement: .newNote, startedAt: start,
                    endedAt: start.addingTimeInterval(30), body: .file(row, duration: .seconds(30))))
            receipts.append(SegmentID(capture))
        }
        let preview = try await world.exporter().preview()
        #expect(preview.files == 1)
        #expect(preview.missing.map(\.segment) == [receipts[0]])
        #expect(preview.missing.map(\.reason) == [.notOnThisDevice])

        let sink = MemoryExportSink()
        let report = try await world.exporter().export(to: sink)
        #expect(report.leftOut.map(\.segment) == [receipts[0]])
        #expect(sink.files[ExportNames.attachment(fixedID(0x1c2), kind: .audio)] == audio)
        #expect(sink.files[ExportNames.attachment(fixedID(0x1c1), kind: .audio)] == nil)
        let notHere = sink.files.filter { $0.key.folder == nil }.values.map { String(decoding: $0, as: UTF8.self) }
        #expect(notHere.filter { $0.contains("*Recording, 0:30: not on this device, not exported.*") }.count == 1)
        #expect(notHere.filter { $0.contains("[Recording, 0:30](attachments/") }.count == 1)
    }

    @Test func aFileOfAKindThisBuildDoesNotKnowStaysBehindWithNoLine() async throws {
        let note = Build.note(fixedID(0x60), at: t0)
        let photo = try Segment(
            id: fixedID(0x61), noteID: note.id, kind: .unknown("photo"), origin: .device(otherDevice), startedAt: t0,
            endedAt: t0, text: "Caption.", textOrigin: .unknown("caption"), state: .unknown("photo.ready"),
            assetID: fixedID(0x62), revision: 1)
        let world = try World(seed: [record(note, [photo])])
        let preview = try await world.exporter().preview()
        #expect(preview.missing.map(\.reason) == [.unknownKind])

        let sink = MemoryExportSink()
        let report = try await world.exporter().export(to: sink)
        #expect(report.leftOut.map(\.isMissing) == [true])
        #expect(sink.files.count == 1)
        #expect(
            sink.files.values.first.map { String(decoding: $0, as: UTF8.self) }?.hasSuffix("---\n\nCaption.\n") == true)
    }

    @Test func everyShownNoteLeavesAcrossPagesWithANameOfItsOwn() async throws {
        let count = Exporter.pageSize + 51
        var seed: [NoteRecord] = []
        for index in 0..<count {
            let at = t0.addingTimeInterval(Double(index * 60))
            let note = Build.note(fixedID(UInt64(0x1000 + index)), at: at, title: "Same title", titleOrigin: .user)
            seed.append(
                record(
                    note,
                    [
                        try Build.typed(
                            fixedID(UInt64(0x5000 + index)), in: note.id, from: at, text: "Line.", origin: .cli)
                    ]))
        }
        let world = try World(seed: seed)
        #expect(try await world.exporter().preview().notes == count)

        let sink = MemoryExportSink()
        let report = try await world.exporter().export(to: sink)
        #expect(report.notes == count)
        #expect(Set(sink.order).count == count)
        #expect(sink.order.first?.name == "2026-11-18 Same title 00001096.md")
    }

    @Test func aFailedWriteStopsTheExportAndSaysWhy() async throws {
        let world = try await GoldenWorld.make()
        let folder = try freshFolder()
        let blocker = folder.appending(path: "export", directoryHint: .notDirectory)
        try Data("a file where the folder would go".utf8).write(to: blocker)
        let error = await #expect(throws: KnotError.self) {
            try await world.exporter().export(to: FolderExportSink(root: blocker))
        }
        #expect(error?.code == KnotError.writeFailed.code)
    }

    @Test func noTextOrNameReachesTheLog() async throws {
        let canary = "Quillfarrow"
        let note = Build.note(fixedID(0x70), at: t0, title: "\(canary) title", titleOrigin: .user)
        let text = try Build.typed(fixedID(0x71), in: note.id, from: t0, text: "\(canary) text.", origin: .cli)
        var voice = try Build.voice(
            fixedID(0x72), in: note.id, from: t0.addingTimeInterval(5), transcript: canary, device: otherDevice)
        voice.assetID = fixedID(0x73)
        let world = try World(seed: [record(note, [text, voice])])
        let kept = KeptLog()
        let exporter = world.exporter(log: KnotLog(.export, sink: kept))
        _ = try await exporter.preview()
        let report = try await exporter.export(to: MemoryExportSink())

        #expect(kept.lines.count == 2)
        for line in kept.lines {
            #expect(!line.contains(canary))
            for path in report.written { #expect(!line.contains(path.name)) }
        }
    }
}
