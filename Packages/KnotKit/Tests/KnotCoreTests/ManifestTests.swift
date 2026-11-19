import Foundation
import KnotCore
import KnotTestSupport
import Testing

@Suite struct CaptureManifestTests {
    static let capture = CaptureID(uuid: UUID(uuidString: "019a9b3c-7e00-7000-8000-000000000001")!)
    static let launch = LaunchID(uuid: UUID(uuidString: "019a9b3c-7e00-7000-8000-000000000002")!)
    static let note = NoteID(uuid: UUID(uuidString: "019a9b3c-7e00-7000-8000-000000000003")!)
    static let watch = DeviceID(uuid: UUID(uuidString: "019a9b3c-7e00-7000-8000-000000000004")!)

    static let manifest: CaptureManifest = {
        var manifest = CaptureManifest(
            captureID: capture, kind: .voice,
            origin: CaptureOrigin(source: .device(watch), surface: .watch), launchID: launch,
            startedAt: Date(timeIntervalSince1970: 1_795_000_000),
            endedAt: Date(timeIntervalSince1970: 1_795_000_042.5),
            duration: .milliseconds(42_500), placement: .window, shownNoteID: note, revision: 3,
            payloadByteCount: 21_000, payloadSHA256: String(repeating: "ab", count: 32))
        return manifest
    }()

    @Test func theFormatMatchesItsGoldenFile() throws {
        let golden = Data(CaptureManifestGolden.formatOne.utf8)
        let encoded = try Self.manifest.encoded()
        #expect(
            String(decoding: encoded, as: UTF8.self)
                == String(decoding: golden, as: UTF8.self))
        #expect(try CaptureManifest.decode(golden) == Self.manifest)
    }

    @Test func everyPlacementAndAnOpenCaptureRoundTrip() throws {
        for placement in [CapturePlacement.window, .newNote, .named(Self.note)] {
            var manifest = Self.manifest
            manifest.placement = placement
            manifest.endedAt = nil
            manifest.duration = nil
            manifest.shownNoteID = nil
            manifest.payloadByteCount = nil
            manifest.payloadSHA256 = nil
            #expect(try CaptureManifest.decode(manifest.encoded()) == manifest)
        }
    }

    @Test func aFieldThisBuildDoesNotKnowIsKeptAndWrittenBack() throws {
        let golden = Data(CaptureManifestGolden.formatOneWithUnknownFields.utf8)
        let manifest = try CaptureManifest.decode(golden)
        #expect(manifest.kind == .unknown("photo"))
        #expect(manifest.origin.surface == .unknown("car_play"))
        #expect(manifest.unknownFields["lens"] == .object(["focal_mm": .number(24), "front": .bool(false)]))
        #expect(manifest.unknownFields["tags"] == .array([.string("x"), .null]))
        #expect(
            String(decoding: try manifest.encoded(), as: UTF8.self)
                == String(decoding: golden, as: UTF8.self))
    }

    @Test func aNewerFormatIsRefusedAndNamesItsCapture() throws {
        let json = #"{"capture_id":"\#(Self.capture)","format":2,"something":"new"}"#
        do {
            _ = try CaptureManifest.decode(Data(json.utf8))
            Issue.record("A manifest of a newer format was read.")
        } catch {
            #expect(error.code == KnotError.inboxItemNewerVersion.code)
            #expect(error.context.captureID == Self.capture)
        }
    }

    @Test(arguments: ["", "{", "[]", #"{"format":1}"#, #"{"format":"one"}"#])
    func anUnreadableManifestIsRefused(json: String) {
        #expect(throws: KnotError.inboxItemUnreadable) { try CaptureManifest.decode(Data(json.utf8)) }
    }

    /// The golden manifest with one field replaced by `value`, as raw JSON.
    static func golden(replacing key: String, with value: String) -> Data {
        var object =
            try! JSONSerialization.jsonObject(with: Data(CaptureManifestGolden.formatOne.utf8)) as! [String: Any]
        object[key] = "VALUE"
        let text = String(
            decoding: try! JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
        return Data(text.replacingOccurrences(of: "\"VALUE\"", with: value).utf8)
    }

    @Test(arguments: [
        ("duration_seconds", "1e300"), ("duration_seconds", "-1e300"), ("duration_seconds", "9.3e15"),
        ("duration_seconds", "-1"), ("revision", "-1"), ("revision", "1e300"), ("payload_bytes", "-5"),
        ("payload_bytes", "9223372036854775808"), ("format", "1e300"),
    ])
    func aNumberOutOfRangeIsRefusedNotATrap(key: String, value: String) {
        #expect(throws: KnotError.inboxItemUnreadable.about(capture: Self.capture)) {
            try CaptureManifest.decode(Self.golden(replacing: key, with: value))
        }
    }

    @Test func aManifestOverItsBoundIsRefused() throws {
        #expect(throws: KnotError.manifestTooLarge) {
            try CaptureManifest.decode(Data(repeating: 0x20, count: Limits.manifestBytes + 1))
        }
        var manifest = Self.manifest
        manifest.unknownFields["padding"] = .string(String(repeating: "p", count: Limits.manifestBytes))
        #expect(throws: KnotError.manifestTooLarge.about(capture: Self.capture)) { try manifest.encoded() }
    }
}
