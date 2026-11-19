import Foundation
import KnotCore
import Testing

/// A segment for rule tests.
func segment(
    _ number: Int, note: NoteID, kind: SegmentKind = .typed, start: Date, end: Date?, text: String = "words",
    state: SegmentState? = nil, owner: DeviceID? = nil, deleted: Date? = nil, conflictOf: SegmentID? = nil
) -> Segment {
    try! Segment(
        id: id(number), noteID: note, kind: kind, origin: fromDevice, startedAt: start, endedAt: end, text: text,
        textOrigin: kind == .voice ? .rawTranscript : .typed, processingOwner: owner,
        state: state ?? (kind == .voice ? .voice(.ready) : .typed(.ready)), conflictOf: conflictOf,
        deletedAt: deleted)
}

@Suite struct DomainValueTests {
    @Test func anUnknownValueIsKeptAndWrittenBack() throws {
        struct Record: Codable, Equatable {
            var kind: SegmentKind
            var origin: SegmentOrigin
            var textOrigin: TextOrigin
            var state: SegmentState
            var upload: AssetUpload
        }
        let json =
            #"{"kind":"photo","origin":"watch-bridge","state":"photo.developing","textOrigin":"ocr","upload":"queued"}"#
        let record = try JSONDecoder().decode(Record.self, from: Data(json.utf8))
        #expect(record.kind == .unknown("photo"))
        #expect(record.kind.isUnknown)
        #expect(record.origin == .unknown("watch-bridge"))
        #expect(record.textOrigin == .unknown("ocr"))
        #expect(record.state == .unknown("photo.developing"))
        #expect(record.upload == .unknown("queued"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(String(decoding: try encoder.encode(record), as: UTF8.self) == json)
    }

    static let everyState: [SegmentState] =
        TypedState.allCases.map(SegmentState.typed)
        + [
            .voice(.recording), .voice(.recovered), .voice(.recorded), .voice(.transcribing),
            .voice(.transcribed), .voice(.cleaning), .voice(.ready), .voice(.discarded), .voice(.onWatch),
            .voice(.delivered), .voice(.failed(.transcribe, KnotError.transcriptionFailed.code)),
            .voice(.failed(.clean, KnotError.writeFailed.code)),
            .ink(.drawing), .ink(.recognising), .ink(.ready), .ink(.discarded),
            .ink(.failed(KnotError.recognitionFailed.code)),
        ]

    @Test(arguments: everyState)
    func segmentStateKeepsItsTextForm(state: SegmentState) {
        #expect(SegmentState(rawValue: state.rawValue) == state)
        #expect(!state.isUnknown)
    }

    @Test(arguments: ["voice.failed.transcribe.", "voice.failed.sing.x", "typed.drafted", "ink", "", "voice.ready.x"])
    func malformedStateTextIsUnknownNotDropped(text: String) {
        #expect(SegmentState(rawValue: text) == .unknown(text))
    }

    @Test func placementAndOutcomeTextForms() {
        let note: NoteID = id(7)
        for placement in [CapturePlacement.window, .newNote, .named(note)] {
            #expect(CapturePlacement(rawValue: placement.rawValue) == placement)
        }
        for outcome in [CaptureOutcome.open, .stored, .discardedEmpty, .failed(KnotError.diskFull.code)] {
            #expect(CaptureOutcome(rawValue: outcome.rawValue) == outcome)
        }
        for state in [JobState.queued, .running, .done, .failed(KnotError.jobDiedTwice.code)] {
            #expect(JobState(rawValue: state.rawValue) == state)
        }
        #expect(CapturePlacement(rawValue: "named:nope") == nil)
    }
}

@Suite struct CursorTests {
    let store: StoreID = id(1)

    @Test func tokenRoundTrips() {
        let cursor = StoreCursor(storeID: store, generation: 2, counter: 1840)
        #expect(StoreCursor(token: cursor.token) == cursor)
        #expect(StoreCursor(token: "nonsense") == nil)
        #expect(StoreCursor(token: "\(store).-1.5") == nil)
    }

    @Test func cursorChecks() throws {
        let cursor = StoreCursor(storeID: store, generation: 2, counter: 1840)
        try cursor.check(storeID: store, generation: 2, counter: 1840)
        try cursor.check(storeID: store, generation: 2, counter: 2000)
        #expect(throws: KnotError.cursorAheadOfStore) { try cursor.check(storeID: store, generation: 2, counter: 1839) }
        #expect(throws: KnotError.cursorForeign) { try cursor.check(storeID: store, generation: 3, counter: 5000) }
        #expect(throws: KnotError.cursorForeign) { try cursor.check(storeID: id(2), generation: 2, counter: 5000) }
    }

    @Test func revisionChecks() throws {
        let revision = StampedRevision(storeID: store, generation: 1, value: 7)
        #expect(StampedRevision(token: revision.token) == revision)
        try revision.check(storeID: store, generation: 1, current: 7)
        #expect(throws: KnotError.revisionStale) { try revision.check(storeID: store, generation: 1, current: 8) }
        #expect(throws: KnotError.revisionForeign) { try revision.check(storeID: store, generation: 2, current: 7) }
    }
}

@Suite struct ContentHashTests {
    static let secret = StoreSecret(bytes: Array(repeating: 7, count: 32))

    @Test func theSameContentGivesTheSameHash() {
        let one = ContentHash(kind: .typed, content: .text("buy stamps"), secret: Self.secret)
        let two = ContentHash(kind: .typed, content: .text("buy stamps"), secret: Self.secret)
        #expect(one == two)
        #expect(one.hex.count == 64)
    }

    @Test func otherContentAnotherKindOrAnotherStoreGiveAnotherHash() {
        let base = ContentHash(kind: .typed, content: .text("buy stamps"), secret: Self.secret)
        #expect(base != ContentHash(kind: .typed, content: .text("buy stamps!"), secret: Self.secret))
        #expect(base != ContentHash(kind: .voice, content: .text("buy stamps"), secret: Self.secret))
        #expect(
            base
                != ContentHash(
                    kind: .typed, content: .text("buy stamps"),
                    secret: StoreSecret(bytes: Array(repeating: 8, count: 32))))
        #expect(
            ContentHash(kind: .voice, content: .file(sha256: Array(repeating: 1, count: 32)), secret: Self.secret)
                != ContentHash(
                    kind: .voice, content: .file(sha256: Array(repeating: 2, count: 32)), secret: Self.secret))
    }

    @Test func aCaptureRowRoundTrips() throws {
        let capture = Capture(
            id: id(1), kind: .typed, origin: CaptureOrigin(source: .cli, surface: .commandLine), startedAt: at("09:00"),
            endedAt: at("09:00:01"), outcome: .stored, launchID: id(2), placement: .named(id(3)),
            contentHash: ContentHash(kind: .typed, content: .text("x"), secret: Self.secret))
        #expect(try JSONDecoder().decode(Capture.self, from: JSONEncoder().encode(capture)) == capture)
        #expect(!capture.needsRecovery(currentLaunch: id(4)), "A stored capture needs no recovery.")
        var open = capture
        open.outcome = .open
        #expect(open.needsRecovery(currentLaunch: id(4)))
        #expect(!open.needsRecovery(currentLaunch: id(2)), "Recovery never ends a capture of this launch.")
    }

    @Test func domainValuesRoundTrip() throws {
        let note = Note(id: id(1), createdAt: at("09:00"), title: "Roof", titleOrigin: .generated, revision: 12)
        #expect(try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note)) == note)
        var voice = segment(2, note: id(1), kind: .voice, start: at("09:00"), end: at("09:01"), owner: thisDevice)
        voice.transcription = TranscriptionProvenance(engine: "SpeechTranscriber", locale: "en_GB", osBuild: "27C100")
        voice.cleanup = CleanupProvenance(osBuild: "27C100")
        voice.duration = .seconds(60)
        voice.arrivedAt = at("10:00")
        #expect(try JSONDecoder().decode(Segment.self, from: JSONEncoder().encode(voice)) == voice)
        let asset = Asset(id: id(3), segmentID: id(2), kind: .audio, byteCount: 500_000, sha256: "00")
        #expect(asset.availability == .local)
        #expect(asset.upload == .localOnly)
        #expect(try JSONDecoder().decode(Asset.self, from: JSONEncoder().encode(asset)) == asset)
    }
}

@Suite struct SegmentLimitTests {
    static let tooLong = String(repeating: "x", count: Limits.segmentTextBytes + 1)

    static func build(text: String, raw: String? = nil) throws(KnotError) -> Segment {
        try Segment(
            id: id(1), noteID: id(2), kind: .voice, origin: .cli, startedAt: at("09:00"), text: text,
            textOrigin: .rawTranscript, rawTranscript: raw, state: .voice(.ready))
    }

    @Test func aSegmentIsNotBuiltPastTheLimit() throws {
        _ = try Self.build(text: String(repeating: "x", count: Limits.segmentTextBytes))
        #expect(throws: KnotError.textTooLong) { try Self.build(text: Self.tooLong) }
        #expect(throws: KnotError.textTooLong) { try Self.build(text: "x", raw: Self.tooLong) }
    }

    @Test func aSegmentPastTheLimitIsNotDecoded() throws {
        let segment = try Self.build(text: "x")
        let json = String(decoding: try JSONEncoder().encode(segment), as: UTF8.self)
            .replacingOccurrences(of: #""text":"x""#, with: #""text":"\#(Self.tooLong)""#)
        #expect(json.contains(Self.tooLong))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Segment.self, from: Data(json.utf8)) }
    }
}
