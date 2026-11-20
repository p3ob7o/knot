import Foundation
import KnotCore
import KnotExport
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

/// A fixed ID, so that golden files can name it: `019a9b3c-7e00-7000-8000-` and twelve hex
/// digits of `number`.
func fixedID<Tag: IdentifierTag>(_ number: UInt64, prefix: String = "019a9b3c-7e00") -> Identifier<Tag> {
    let tail = String(number, radix: 16)
    let text = "\(prefix)-7000-8000-" + String(repeating: "0", count: 12 - tail.count) + tail
    guard let id = Identifier<Tag>(text) else { preconditionFailure("not an ID: \(text)") }
    return id
}

/// 2026-11-18T11:06:40Z, the fakes' first time.
let t0 = Date(timeIntervalSince1970: 1_795_000_000)

let thisDevice: DeviceID = fixedID(0xd1)
let otherDevice: DeviceID = fixedID(0xd2)

/// The synthetic bytes of a stored recording and a stored drawing.
///
/// Export copies a recording's file as it is and never reads its audio, so the recording is
/// bytes made here, not speech: nothing from `Fixtures/generated/`, which each Mac makes for
/// itself and a fresh checkout does not have (Fixtures/README.md). Its length comes from its
/// segment. The drawing and the image come from committed fixtures.
enum FixtureBytes {
    /// 4 KiB of a fixed pattern, behind the box header that opens an `.m4a` file. The same
    /// bytes on every run.
    static func recording() throws -> Data {
        let header = Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypM4A ".utf8)
        return header + Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    static func drawing() throws -> Data {
        try Data(contentsOf: FixtureFiles.url("ink/line.json"))
    }

    /// A synthetic PNG: the eight bytes that open every PNG file, then a fixture's bytes.
    static func png() throws -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            + (try Data(contentsOf: FixtureFiles.url("ink/line.svg")))
    }
}

/// A new, empty folder of this test's own under the system's temporary folder.
func freshFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(
        path: "knot-export-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A store of seeded notes and an asset store on real files.
struct World {
    let clock = FakeClock(t0)
    let notes: InMemoryNoteStore
    let assets: FileAssetStore
    let root: URL

    init(seed: [NoteRecord] = []) throws {
        root = try freshFolder()
        let ids = SeededIDGenerator(seed: 7, clock: clock)
        notes = InMemoryNoteStore(clock: clock, ids: ids, deviceID: thisDevice, seed: seed)
        assets = FileAssetStore(locations: .testing(root: root), layer: PosixFileLayer())
    }

    func exporter(drawings: any DrawingImageSource = NoDrawingImages(), log: KnotLog = KnotLog(.export)) -> Exporter {
        Exporter(notes: notes, assets: assets, drawings: drawings, log: log)
    }
}

func record(_ note: Note, _ segments: [Segment]) -> NoteRecord {
    NoteRecord(note: note, segments: segments, storeID: fixedID(0x5), generation: 0)
}

/// The golden note, its neighbours and their files (`Golden`).
///
/// N1, titled, holds a typed segment with Windows line endings and a blank line at its end, a
/// conflict copy of it, a recording that is here, a drawing that is here, a deleted segment,
/// and a recording that is not on this device. N2, older, has no title, so its first line
/// names it. N3 is deleted, and stays behind.
enum GoldenWorld {
    static let n1: NoteID = fixedID(0x1)
    static let n2: NoteID = fixedID(0x2)
    static let n3: NoteID = fixedID(0x3)
    static let typed: SegmentID = fixedID(0xb1)
    static let voice: SegmentID = fixedID(0xb2)
    static let ink: SegmentID = fixedID(0xb3)
    static let deleted: SegmentID = fixedID(0xb4)
    static let voiceElsewhere: SegmentID = fixedID(0xb5)
    static let n2Typed: SegmentID = fixedID(0xb6)
    static let n3Typed: SegmentID = fixedID(0xb7)
    static let recordingAsset: AssetID = fixedID(0xa2)
    static let drawingAsset: AssetID = fixedID(0xa3)
    static let elsewhereAsset: AssetID = fixedID(0xa5)

    static func seed() throws -> [NoteRecord] {
        var n1 = Build.note(n1, at: t0, title: "Roof, and stamps", titleOrigin: .user)
        n1.updatedAt = t0.addingTimeInterval(600)
        n1.lastCaptureEndedAt = t0.addingTimeInterval(300)
        let typed = try Build.typed(
            typed, in: n1.id, from: t0, text: "Call the roofer about the leak.\r\nAsk for Tuesday.\r\n\r\n",
            origin: .device(thisDevice))
        let copy = try Build.conflictCopy(
            of: typed, losingDevice: otherDevice, text: "\n\nCall the roofer about the leak on Tuesday.")
        var voice = try Build.voice(
            voice, in: n1.id, from: t0.addingTimeInterval(60), transcript: "Buy stamps, and post the forms.",
            device: thisDevice)
        voice.assetID = recordingAsset
        voice.duration = .seconds(42.6)
        var ink = try Segment(
            id: ink, noteID: n1.id, kind: .ink, origin: .device(thisDevice), startedAt: t0.addingTimeInterval(120),
            endedAt: t0.addingTimeInterval(150), text: "call the vet at noon", textOrigin: .recognised,
            state: .ink(.ready), assetID: drawingAsset, revision: 1)
        ink.assetID = drawingAsset
        var deleted = try Build.typed(
            deleted, in: n1.id, from: t0.addingTimeInterval(180), text: "This line was deleted.",
            origin: .device(thisDevice))
        deleted.deletedAt = t0.addingTimeInterval(200)
        var elsewhere = try Build.voice(
            voiceElsewhere, in: n1.id, from: t0.addingTimeInterval(240), transcript: "", device: otherDevice)
        elsewhere.assetID = elsewhereAsset
        elsewhere.duration = .seconds(75)

        let n2Day = t0.addingTimeInterval(-2 * 86_400)
        let n2 = Build.note(n2, at: n2Day)
        let n2Typed = try Build.typed(
            n2Typed, in: n2.id, from: n2Day, text: "  \n\nShopping: milk, eggs\nand bread", origin: .cli)

        var n3 = Build.note(n3, at: t0.addingTimeInterval(-86_400), title: "Deleted note", titleOrigin: .user)
        n3.deletedAt = t0
        let n3Typed = try Build.typed(
            n3Typed, in: n3.id, from: t0.addingTimeInterval(-86_400), text: "Gone.", origin: .device(thisDevice))

        return [
            record(n1, [typed, copy, voice, ink, deleted, elsewhere]),
            record(n2, [n2Typed]),
            record(n3, [n3Typed]),
        ]
    }

    /// The world with the golden notes, and the recording and the drawing that are here.
    static func make() async throws -> World {
        let world = try World(seed: try seed())
        _ = try await world.assets.place(try FixtureBytes.recording(), as: recordingAsset, kind: .audio)
        _ = try await world.assets.place(try FixtureBytes.drawing(), as: drawingAsset, kind: .ink)
        return world
    }
}

/// Gives a set image for some drawings, and counts what it was asked.
final class SetImages: DrawingImageSource {
    private let images: [AssetID: DrawingImage]
    private let asked = Mutex(0)

    init(_ images: [AssetID: DrawingImage]) {
        self.images = images
    }

    var askedCount: Int { asked.withLock { $0 } }

    func image(of asset: AssetID, segment: SegmentID) async -> DrawingImage? {
        asked.withLock { $0 += 1 }
        return images[asset]
    }
}

/// Keeps every log record, for the check that no text reaches a log.
final class KeptLog: LogSink {
    private let records = Mutex<[LogRecord]>([])

    func write(_ record: LogRecord) { records.withLock { $0.append(record) } }

    var lines: [String] {
        records.withLock { $0.map { ([$0.event] + $0.fields.map(\.rendered)).joined(separator: " ") } }
    }
}

extension MemoryExportSink {
    /// The text of the file at a path, or `nil`.
    func text(_ relativePath: String) -> String? {
        files.first { $0.key.relativePath == relativePath }.map { String(decoding: $0.value, as: UTF8.self) }
    }
}
