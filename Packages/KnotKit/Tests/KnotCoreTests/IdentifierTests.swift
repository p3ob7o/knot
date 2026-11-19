import Foundation
import KnotCore
import Testing

@Suite struct IdentifierTests {
    @Test func versionSevenCarriesItsTimeAndVersion() {
        let uuid = UUIDv7.make(milliseconds: 0x0123_4567_89AB, random: Array(repeating: 0xFF, count: 10))
        #expect(uuid.uuidString.lowercased() == "01234567-89ab-7fff-bfff-ffffffffffff")
        #expect(UUIDVersion(of: uuid) == .fresh)
        #expect(UUIDv7.milliseconds(of: uuid) == 0x0123_4567_89AB)
    }

    @Test func versionSevenFromADateSortsByTime() {
        var generator = SystemRandomNumberGenerator()
        let earlier = UUIDv7.make(at: at("09:00"), using: &generator)
        let later = UUIDv7.make(at: at("09:01"), using: &generator)
        #expect(NoteID(uuid: earlier) < NoteID(uuid: later))
        #expect(UUIDv7.milliseconds(of: earlier) == UInt64(at("09:00").timeIntervalSince1970 * 1000))
    }

    @Test func versionFiveMatchesTheStandard() {
        // RFC 9562, Appendix A.4: "www.example.com" in the DNS namespace.
        let dns = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        let uuid = UUIDv5.make(namespace: dns, name: "www.example.com")
        #expect(uuid.uuidString.lowercased() == "2ed6657d-e927-568b-95e1-2665a8aea6a2")
        #expect(UUIDVersion(of: uuid) == .derived)
    }

    @Test func derivedIDsAreStableAndToldFromFreshOnes() {
        let capture: CaptureID = id(1)
        #expect(SegmentID.piece(0, of: capture) == SegmentID(capture))
        #expect(SegmentID.piece(0, of: capture).version == .fresh)
        #expect(SegmentID.piece(1, of: capture) == SegmentID.piece(1, of: capture))
        #expect(SegmentID.piece(1, of: capture) != SegmentID.piece(2, of: capture))
        #expect(SegmentID.piece(1, of: capture).isDerived)

        let note: NoteID = id(2)
        #expect(NoteID.successor(ofDeleted: note) == NoteID.successor(ofDeleted: note))
        #expect(NoteID.successor(ofDeleted: note).isDerived)
        #expect(!note.isDerived)
        #expect(NoteID.successor(ofDeleted: NoteID.successor(ofDeleted: note)) != NoteID.successor(ofDeleted: note))

        let copy = SegmentID.conflictCopy(of: id(3), losingDevice: otherDevice, losingRevision: 4)
        #expect(copy == SegmentID.conflictCopy(of: id(3), losingDevice: otherDevice, losingRevision: 4))
        #expect(copy != SegmentID.conflictCopy(of: id(3), losingDevice: otherDevice, losingRevision: 5))
        #expect(copy.isDerived)
    }

    @Test func eachRuleDerivesInItsOwnNamespace() {
        let source: CaptureID = id(5)
        let piece = SegmentID.piece(1, of: source)
        let successor = NoteID.successor(ofDeleted: NoteID(source))
        #expect(piece.uuid != successor.uuid)
    }

    @Test func textFormAndFolderName() throws {
        let note = NoteID(uuid: UUID(uuidString: "01234567-89AB-7FFF-BFFF-FFFFFFFFFF3C")!)
        #expect(note.description == "01234567-89ab-7fff-bfff-ffffffffff3c")
        #expect(note.folderName == "3c")
        #expect(NoteID("01234567-89ab-7fff-bfff-ffffffffff3c") == note)
        #expect(NoteID("not an id") == nil)

        let data = try JSONEncoder().encode(note)
        #expect(String(decoding: data, as: UTF8.self) == "\"01234567-89ab-7fff-bfff-ffffffffff3c\"")
        #expect(try JSONDecoder().decode(NoteID.self, from: data) == note)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(NoteID.self, from: Data("\"x\"".utf8)) }
    }

    @Test func orderIsAFixedTieBreakOverTheBytes() {
        let low = NoteID(uuid: UUID(uuidString: "00000000-0000-5000-8000-000000000001")!)
        let high = NoteID(uuid: UUID(uuidString: "ff000000-0000-7000-8000-000000000000")!)
        #expect(low < high)
        #expect([high, low].sorted() == [low, high])
    }
}

@Suite struct OpenEnumTests {
    @Test func everyKnownValueKeepsItsTextForm() {
        for kind in SegmentKind.allCases { #expect(SegmentKind(rawValue: kind.rawValue) == kind) }
        for origin in TextOrigin.allCases { #expect(TextOrigin(rawValue: origin.rawValue) == origin) }
        for origin in TitleOrigin.allCases { #expect(TitleOrigin(rawValue: origin.rawValue) == origin) }
        for kind in AssetKind.allCases { #expect(AssetKind(rawValue: kind.rawValue) == kind) }
        for value in AssetAvailability.allCases { #expect(AssetAvailability(rawValue: value.rawValue) == value) }
        for value in AssetUpload.allCases { #expect(AssetUpload(rawValue: value.rawValue) == value) }
        for value in CaptureSurface.allCases { #expect(CaptureSurface(rawValue: value.rawValue) == value) }
        for origin in [SegmentOrigin.device(thisDevice), .cli, .mcp] {
            #expect(SegmentOrigin(rawValue: origin.rawValue) == origin)
        }
    }
}

@Suite struct IdentifierParsingTests {
    static let canonical = "01234567-89ab-7fff-bfff-ffffffffff3c"

    @Test(arguments: [
        canonical + "\u{0}", canonical + "\u{0}junk", canonical + " ", " " + canonical, "{" + canonical + "}",
        "0123456789ab7fffbfffffffffffff3c", "01234567-89ab-7fff-bfff-ffffffffff3", canonical + "0",
        "01234567_89ab-7fff-bfff-ffffffffff3c", "0123456g-89ab-7fff-bfff-ffffffffff3c",
        "01234567-89ab-7fff-bfff-ffffffffff3\u{FF43}", "",
    ])
    func onlyTheCanonicalFormIsAnID(text: String) {
        #expect(NoteID(text) == nil)
        let json = try! JSONEncoder().encode(text)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(NoteID.self, from: json) }
    }

    @Test func eitherCaseIsTheSameID() throws {
        let lower = try #require(NoteID(Self.canonical))
        #expect(NoteID(Self.canonical.uppercased()) == lower)
        let json = try JSONEncoder().encode(Self.canonical.uppercased())
        #expect(try JSONDecoder().decode(NoteID.self, from: json) == lower)
    }
}

@Suite struct UUIDv7TimeBoundsTests {
    @Test func aDateOutsideTheRangeIsClampedNeverTrappedOrWrapped() {
        var generator = SystemRandomNumberGenerator()
        let far = UUIDv7.make(at: Date(timeIntervalSince1970: 1e20), using: &generator)
        #expect(UUIDv7.milliseconds(of: far) == (1 << 48) - 1)
        let before = UUIDv7.make(at: Date(timeIntervalSince1970: -1e20), using: &generator)
        #expect(UUIDv7.milliseconds(of: before) == 0)
        // Just past 48 bits must not wrap round to a small time.
        let wrap = UUIDv7.make(at: Date(timeIntervalSince1970: Double(1 << 48) / 1000 + 1), using: &generator)
        #expect(UUIDv7.milliseconds(of: wrap) == (1 << 48) - 1)
    }
}
