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

    @Test func whatThisBuildDoesNotKnowIsKeptAndWrittenBackByteForByte() throws {
        // docs/architecture.md §4: a kind, an origin, a state or a field that this build does
        // not know is kept and never dropped, inbox manifests included.
        let golden = Data(CaptureManifestGolden.formatOneWithUnknownFields.utf8)
        let manifest = try CaptureManifest.decode(golden)
        #expect(manifest.kind == .unknown("photo"))
        #expect(manifest.origin.surface == .unknown("car_play"))
        #expect(manifest.unknownFields["lens"] == #"{"focal_mm":24,"front":false}"#)
        #expect(manifest.unknownFields["tags"] == #"["x",null]"#)
        #expect(
            String(decoding: try manifest.encoded(), as: UTF8.self) == CaptureManifestGolden.formatOneWithUnknownFields)
    }

    @Test func anUnknownNumberComesBackExactly() throws {
        // 9007199254740993 does not fit a Double.
        let data = Self.golden(replacing: "future_count", with: "9007199254740993")
        let manifest = try CaptureManifest.decode(data)
        let written = String(decoding: try manifest.encoded(), as: UTF8.self)
        #expect(written.contains(#""future_count":9007199254740993"#))
        #expect(written == String(decoding: data, as: UTF8.self))
        #expect(try CaptureManifest.decode(Data(written.utf8)) == manifest)
    }

    @Test func aManifestThatNamesAKeyTwiceIsRefused() {
        let twice = CaptureManifestGolden.formatOne.replacingOccurrences(
            of: #""format":1,"#, with: #""format":1,"format":2,"#)
        #expect(twice != CaptureManifestGolden.formatOne)
        #expect(throws: KnotError.inboxItemUnreadable) { try CaptureManifest.decode(Data(twice.utf8)) }
    }

    @Test(arguments: [
        "01", #""\q""#, "[1,]", "{\"a\":1,}", "+1", "1.", ".5", "1e", "0x10", "tru", "nul", "NaN", "-", "[1 2]",
        "{\"a\" 1}", "{1:2}", #""\u12""#, "\"a\u{0001}b\"", "[", "{", "\"open", "1-2",
    ])
    func anUnknownValueThatIsNotJSONMakesTheManifestUnreadable(value: String) {
        do {
            _ = try CaptureManifest.decode(Self.golden(replacing: "future", with: value))
            Issue.record("A manifest that is not valid JSON was read.")
        } catch {
            #expect(error.code == KnotError.inboxItemUnreadable.code)
        }
    }

    @Test(arguments: [
        "0", "-0", "12345678901234567890123456789012345678901234567890", "1.5e-300", "-2E+5", #""é\n\"""#, "true",
        "false", "null", "[]", "{}", "[1, {\"a\": [null, \"x\"]}]", " { \"b\" : [ 1 , 2 ] } ",
    ])
    func anUnknownValueThatIsJSONIsKept(value: String) throws {
        let manifest = try CaptureManifest.decode(Self.golden(replacing: "future", with: value))
        #expect(manifest.unknownFields["future"] == value.trimmingCharacters(in: .whitespaces))
        #expect(try CaptureManifest.decode(manifest.encoded()) == manifest)
    }

    @Test func nestingPastTheCapIsRefusedNotRecursedThrough() throws {
        let deep = String(repeating: "[", count: 1_000) + String(repeating: "]", count: 1_000)
        #expect(throws: KnotError.self) { try CaptureManifest.decode(Self.golden(replacing: "future", with: deep)) }
        let shallow = String(repeating: "[", count: 10) + String(repeating: "]", count: 10)
        _ = try CaptureManifest.decode(Self.golden(replacing: "future", with: shallow))
    }

    @Test func anUnknownPlacementIsANewerKnotsAndTheFileIsKept() {
        let data = Self.golden(replacing: "placement", with: #""pinned:top""#)
        #expect(throws: KnotError.inboxItemNewerVersion.about(capture: Self.capture)) {
            try CaptureManifest.decode(data)
        }
        let broken = Self.golden(replacing: "placement", with: #""named:not-an-id""#)
        #expect(throws: KnotError.inboxItemUnreadable.about(capture: Self.capture)) {
            try CaptureManifest.decode(broken)
        }
    }

    @Test func aFormatThisBuildDoesNotSupportIsRefused() throws {
        for format in ["0", "-1", "2"] {
            #expect(throws: KnotError.self) {
                try CaptureManifest.decode(Self.golden(replacing: "format", with: format))
            }
        }
    }

    @Test func theEncoderHoldsTheBoundsTheDecoderHolds() {
        var negative = Self.manifest
        negative.duration = .seconds(-1)
        #expect(throws: KnotError.self) { try negative.encoded() }
        var revision = Self.manifest
        revision.revision = -1
        #expect(throws: KnotError.self) { try revision.encoded() }
        var size = Self.manifest
        size.payloadByteCount = -1
        #expect(throws: KnotError.self) { try size.encoded() }
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
        manifest.payloadSHA256 = String(repeating: "p", count: Limits.manifestBytes)
        #expect(throws: KnotError.manifestTooLarge.about(capture: Self.capture)) { try manifest.encoded() }
    }
}
