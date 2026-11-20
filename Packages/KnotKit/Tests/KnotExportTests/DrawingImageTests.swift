import Foundation
import KnotCore
import KnotExport
import KnotFakes
import Testing

/// An image that is not whole, by name.
struct BrokenImage: CustomTestStringConvertible, Sendable {
    let name: String
    let data: Data
    var testDescription: String { name }

    static let all: [BrokenImage] = {
        let p = SyntheticPNG.self
        return [
            BrokenImage(name: "the signature alone", data: p.signature),
            BrokenImage(name: "the signature and other bytes", data: p.signature + Data("<svg/>".utf8)),
            BrokenImage(name: "no IEND", data: p.signature + p.ihdr + p.idat),
            BrokenImage(name: "IEND cut short", data: (p.signature + p.ihdr + p.idat + p.iend).dropLast(2)),
            BrokenImage(name: "IHDR not first", data: p.signature + p.idat + p.ihdr + p.iend),
            BrokenImage(
                name: "a chunk longer than the data", data: p.signature + p.ihdr + p.chunk("IDAT", [1]).prefix(9)),
            BrokenImage(
                name: "a wrong CRC", data: p.signature + p.ihdr + p.chunk("IDAT", [0x78, 0x01], crc: 7) + p.iend),
            BrokenImage(name: "bytes after IEND", data: p.signature + p.ihdr + p.idat + p.iend + Data([0])),
            BrokenImage(name: "nothing", data: Data()),
        ]
    }()
}

/// Finding 19: an image that is not whole never takes the drawing's place.
@Suite struct DrawingImageTests {
    @Test(arguments: BrokenImage.all)
    func anImageThatIsNotWholeLeavesTheDrawingAsItsData(image: BrokenImage) async throws {
        let world = try await GoldenWorld.make()
        let id = GoldenWorld.drawingAsset
        let sink = MemoryExportSink()
        let report = try await world.exporter(drawings: SetImages([id: DrawingImage(png: image.data)])).export(to: sink)

        let raw = ExportNames.attachment(id, kind: .ink)
        #expect(sink.files[raw] == (try FixtureBytes.drawing()))
        #expect(sink.files[ExportNames.drawingImage(id)] == nil)
        #expect(report.leftOut.contains { $0.asset == id && $0.reason == .drawingWithoutImage(raw) })
    }

    @Test func aWholeImageTakesTheDrawingsPlace() async throws {
        let world = try await GoldenWorld.make()
        let id = GoldenWorld.drawingAsset
        let png = try FixtureBytes.png()
        let sink = MemoryExportSink()
        let report = try await world.exporter(drawings: SetImages([id: DrawingImage(png: png)])).export(to: sink)

        #expect(sink.files[ExportNames.drawingImage(id)] == png)
        #expect(sink.files[ExportNames.attachment(id, kind: .ink)] == nil)
        #expect(!report.leftOut.contains { $0.asset == id })
    }

    @Test(arguments: BrokenImage.all)
    func aSharedDrawingWithAnImageThatIsNotWholeIsItsData(image: BrokenImage) async throws {
        let world = try await GoldenWorld.make()
        let ink = try #require(try GoldenWorld.seed()[0].segments.first { $0.id == GoldenWorld.ink })
        let images = SetImages([GoldenWorld.drawingAsset: DrawingImage(png: image.data)])
        let item = try #require(
            try await ShareItems.drawing(of: ink, assets: world.assets, drawings: images, timeZone: .gmt))
        #expect(item.typeIdentifier == ShareItem.dataType)
    }
}
