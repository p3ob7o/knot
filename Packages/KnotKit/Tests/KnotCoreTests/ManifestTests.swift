import Foundation
import KnotTestSupport
import Testing

@testable import KnotCore

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

    /// A recording begun by holding the Mac hotkey while typing, which ends the typed capture
    /// it follows (rules 13 and 15 of docs/product-spec.md §3).
    static let following = CaptureManifest(
        captureID: capture, kind: .voice, origin: CaptureOrigin(source: .device(watch), surface: .macPanel),
        launchID: launch, startedAt: Date(timeIntervalSince1970: 1_795_000_000),
        endedAt: Date(timeIntervalSince1970: 1_795_000_012.25), duration: .milliseconds(12_250), placement: .window,
        shownNoteID: note, revision: 0, payloadByteCount: 9_000, payloadSHA256: String(repeating: "cd", count: 32),
        followsCaptureID: CaptureID(uuid: UUID(uuidString: "019a9b3c-7e00-7000-8000-000000000005")!))

    /// A typed draft that a crash left open, with the time of its last durable save.
    static let lastSaved = CaptureManifest(
        captureID: capture, kind: .typed, origin: CaptureOrigin(source: .device(watch), surface: .app),
        launchID: launch, startedAt: Date(timeIntervalSince1970: 1_795_000_000), placement: .window,
        shownNoteID: note, revision: 7, lastSavedAt: Date(timeIntervalSince1970: 1_795_000_031.125))

    /// The watch recording of `manifest`, finished, with its level peaks.
    static let withPeaks: CaptureManifest = {
        var finished = Self.manifest
        finished.peaks = RecordingPeaks(framesPerValue: 2_400, values: [0, 12, 255, 40]).encoded()
        return finished
    }()

    /// The watch recording of `manifest`, ended by itself when a call took the audio session.
    static let withTheRecordingEnding: CaptureManifest = {
        var finished = Self.manifest
        finished.recordingEnding = .interrupted
        return finished
    }()

    /// Finding 27: each new field has its golden file, and a manifest without them keeps the
    /// bytes of format 1 as they were.
    @Test func eachNewFieldMatchesItsGoldenFile() throws {
        for (manifest, golden) in [
            (Self.following, CaptureManifestGolden.formatOneFollowingACapture),
            (Self.lastSaved, CaptureManifestGolden.formatOneWithTheLastSave),
            (Self.withPeaks, CaptureManifestGolden.formatOneWithPeaks),
            (Self.withTheRecordingEnding, CaptureManifestGolden.formatOneWithTheRecordingEnding),
        ] {
            #expect(String(decoding: try manifest.encoded(), as: UTF8.self) == golden)
            #expect(try CaptureManifest.decode(Data(golden.utf8)) == manifest)
        }
        for key in ["follows_capture_id", "last_saved_at", "peaks", "recording_ending"] {
            #expect(!CaptureManifestGolden.formatOne.contains(key), "\(key) is absent when nil.")
            #expect(!String(decoding: try Self.manifest.encoded(), as: UTF8.self).contains(key))
        }
    }

    /// Finding 27: a build that does not know the new fields keeps them as unknown fields and
    /// writes the manifest back byte for byte, so a build that knows them reads them again.
    @Test func aBuildThatDoesNotKnowTheNewFieldsWritesThemBack() throws {
        let newer: Set = ["follows_capture_id", "last_saved_at", "peaks", "recording_ending"]
        for (manifest, golden) in [
            (Self.following, CaptureManifestGolden.formatOneFollowingACapture),
            (Self.lastSaved, CaptureManifestGolden.formatOneWithTheLastSave),
            (Self.withPeaks, CaptureManifestGolden.formatOneWithPeaks),
            (Self.withTheRecordingEnding, CaptureManifestGolden.formatOneWithTheRecordingEnding),
        ] {
            let older = try CaptureManifest.decode(Data(golden.utf8), notKnowing: newer)
            #expect(
                older.followsCaptureID == nil && older.lastSavedAt == nil && older.peaks == nil
                    && older.recordingEnding == nil,
                "It does not read them.")
            #expect(older.unknownFields.count == 1, "It keeps the one it does not know.")
            let written = try older.encoded()
            #expect(String(decoding: written, as: UTF8.self) == golden, "It writes it back byte for byte.")
            #expect(try CaptureManifest.decode(written) == manifest)
        }
    }

    @Test(arguments: [
        ("follows_capture_id", #""not-an-id""#), ("follows_capture_id", "7"), ("last_saved_at", #""yesterday""#),
        ("last_saved_at", "1795000031"), ("peaks", "7"), ("peaks", #""not base64!""#), ("recording_ending", "7"),
    ])
    func aNewFieldThatIsNotWhatItSaysIsUnreadable(key: String, value: String) {
        #expect(throws: KnotError.inboxItemUnreadable.about(capture: Self.capture)) {
            try CaptureManifest.decode(Self.golden(replacing: key, with: value))
        }
    }

    /// A reason a newer build gives is kept as `unknown` and written back byte for byte, and
    /// every reason this build knows round-trips.
    @Test func everyRecordingEndingRoundTripsAndANewerOneIsKept() throws {
        for reason in RecordingEndReason.allCases {
            var manifest = Self.manifest
            manifest.recordingEnding = reason
            #expect(try CaptureManifest.decode(manifest.encoded()) == manifest)
        }
        let golden = CaptureManifestGolden.formatOneWithTheRecordingEnding
        let newer = golden.replacingOccurrences(of: #""interrupted""#, with: #""thermal_shutdown""#)
        let read = try CaptureManifest.decode(Data(newer.utf8))
        #expect(read.recordingEnding == .unknown("thermal_shutdown"), "A reason this build does not know is kept.")
        #expect(read.unknownFields.isEmpty, "As the member it knows.")
        #expect(String(decoding: try read.encoded(), as: UTF8.self) == newer, "And written back as it was.")
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
        // The Duration itself is compared with both bounds, before any conversion.
        var justBelowZero = Self.manifest
        justBelowZero.duration = .nanoseconds(-1)
        #expect(throws: KnotError.self) { try justBelowZero.encoded() }
        var justPastTheLongest = Self.manifest
        justPastTheLongest.duration = .seconds(1_000_000_000) + .nanoseconds(1)
        #expect(throws: KnotError.self) { try justPastTheLongest.encoded() }
        var zero = Self.manifest
        zero.duration = .zero
        #expect(throws: Never.self) { try zero.encoded() }
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

    /// Bytes that are not UTF-8, put in the golden manifest in place of `marker`.
    static func golden(withBytes bytes: [UInt8], at marker: String, in text: String) -> Data {
        let parts = text.components(separatedBy: marker)
        precondition(parts.count == 2, "The marker appears once.")
        return Data(parts[0].utf8) + Data(bytes) + Data(parts[1].utf8)
    }

    /// A manifest is valid JSON as a whole, or it is unreadable: text that is not UTF-8 is
    /// refused wherever it sits, and never repaired, in a field this build does not know as
    /// in one it does, in a key, and in a value nested in an unknown member.
    @Test(arguments: [
        [0xFF] as [UInt8],  // never in UTF-8
        [0xC3, 0x28],  // a lead byte without its continuation
        [0x80],  // a continuation with no lead
        [0xC0, 0xAF],  // an overlong "/"
        [0xED, 0xA0, 0x80],  // a UTF-16 surrogate, encoded
        [0xF4, 0x90, 0x80, 0x80],  // past U+10FFFF
        [0xE2, 0x82],  // cut short
    ])
    func textThatIsNotUTF8IsRefusedWhereverItSits(bytes: [UInt8]) {
        let unknown = String(
            decoding: Self.golden(replacing: "future_note", with: #""a-MARK-b""#), as: UTF8.self)
        let nested = String(
            decoding: Self.golden(replacing: "future_list", with: #"[{"k":"a-MARK-b"}]"#), as: UTF8.self)
        let key = String(decoding: Self.golden(replacing: "future-MARK-key", with: "1"), as: UTF8.self)
        let known = CaptureManifestGolden.formatOne.replacingOccurrences(
            of: #""surface":"watch""#, with: #""surface":"wa-MARK-tch""#)
        for text in [unknown, nested, key, known] {
            let data = Self.golden(withBytes: bytes, at: "-MARK-", in: text)
            #expect(String(validating: data, as: UTF8.self) == nil)
            #expect {
                try CaptureManifest.decode(data)
            } throws: { error in
                (error as? KnotError)?.code == KnotError.inboxItemUnreadable.code
            }
        }
    }

    @Test func anUnknownMemberKeepsItsTextExactlyWhenItIsUTF8() throws {
        let data = Self.golden(replacing: "future_note", with: #""café 東京 🙂 \u00e9""#)
        let manifest = try CaptureManifest.decode(data)
        #expect(manifest.unknownFields["future_note"] == #""café 東京 🙂 \u00e9""#)
        #expect(try manifest.encoded() == data)
    }
}
