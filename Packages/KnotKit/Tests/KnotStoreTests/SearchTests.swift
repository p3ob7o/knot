import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Testing

@testable import KnotStore

/// Search (docs/architecture.md §17 and §19): text full of query syntax is text, and the
/// answers are a plain scan's.
@Suite struct SearchTests {
    /// The notes a plain scan finds: every shown note whose title or live segments hold every
    /// word of the query, each as a whole word or the start of one, in the order of the stream.
    static func plainScan(_ query: String, in records: [NoteRecord]) -> [NoteID] {
        let wanted = TitleRule.words(of: query)
        guard !wanted.isEmpty else { return [] }
        return records.filter(\.isShown).filter { record in
            let words = ([record.note.title ?? ""] + record.liveSegments.map(\.text)).flatMap(TitleRule.words(of:))
            return wanted.allSatisfy { query in words.contains { $0.hasPrefix(query) } }
        }.sorted { StreamRule.precedes($0.note, $1.note) }.map(\.note.id)
    }

    /// Every note the store holds, read one by one, deleted ones included.
    static func everyNote(_ database: StoreDatabase) async throws -> [NoteRecord] {
        let notes = NoteRepository(database: database)
        let ids = try await database.pool.read { db in try String.fetchAll(db, sql: "SELECT id FROM note") }
        var records: [NoteRecord] = []
        for id in ids.compactMap(NoteID.init) {
            if let record = try await notes.note(id) { records.append(record) }
        }
        return records
    }

    @Test("search-text-full-of-query-syntax", .tags(.named))
    func searchTextFullOfQuerySyntax() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 41, clock: clock)
        let database = try openStore(in: folders.make(), clock: clock, ids: ids)
        let notes = NoteRepository(database: database)
        let captures = Captures(clock: clock, ids: ids, device: database.deviceID)
        let texts = [
            "Ask Sam OR Kim about the NEAR dock", "The quote \" stays and col:value too", "Star* gazing and ^caret",
            "Don't forget the -minus and (brackets)", "AND then NOT this", "Plain synthetic words", "café crème brûlée",
            "naïve résumé 👋🏽 emoji", "a {curly} set and 100% sure",
        ]
        for (index, text) in texts.enumerated() {
            _ = try await notes.record(captures.typed(text, from: Double(index * 10), to: Double(index * 10) + 1))
        }
        let queries = [
            "\"", "\"\"", "*", "OR", "or", "AND", "NOT", "NEAR", "NEAR(ask sam)", "col:value", "col:", "^caret",
            "-minus",
            "(brackets)", "{curly}", "star*", "\"quote", "ask OR kim", "100%", "%", "_", "don't", "Don’t", "caf",
            "café",
            "cafe\u{301}", "brûl", "naïve", "👋🏽", "'", "\\", ";", "') OR 1=1 --", "\u{0}", "", "   ", "a b c d e f",
        ]
        let records = try await Self.everyNote(database)
        for query in queries {
            let found = try await notes.search(query, limit: 100)
            #expect(found == Self.plainScan(query, in: records), "Search for \(query.debugDescription)")
        }
        #expect(try await notes.search("ask OR kim", limit: 10).count == 1, "OR is a word, and every word must match.")
        #expect(try await notes.search("near", limit: 10).count == 1)
        expectConsistent(database)
    }

    /// For a seeded store, whole-word and prefix queries return the same notes as a scan of the
    /// text, across typed, spoken and handwritten segments and titles, and never a deleted note.
    @Test("search-checked-against-plain-scan", .tags(.named), arguments: [1, 2, 3])
    func searchCheckedAgainstPlainScan(seed: UInt64) async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: seed, clock: clock)
        let database = try openStore(in: folders.make(), clock: clock, ids: ids)
        let notes = NoteRepository(database: database)
        let captures = Captures(clock: clock, ids: ids, device: database.deviceID)
        var random = SplitMix(seed: seed)
        let vocabulary = [
            "apple", "apples", "applause", "banana", "band", "bandit", "cherry", "chair", "dock", "docket", "élan",
            "über", "zebra", "zero", "Zürich", "garden", "gardener", "night", "nightly", "o'clock", "rock'n'roll",
        ]
        func sentence() -> String {
            (0..<random.next(in: 1...6)).map { _ in vocabulary[random.next(in: 0...(vocabulary.count - 1))] }
                .joined(separator: random.next(in: 0...3) == 0 ? ", " : " ")
        }
        var minute = 0.0
        var recorded: [CaptureReceipt] = []
        for _ in 0..<60 {
            minute += Double(random.next(in: 1...12))
            switch random.next(in: 0...3) {
            case 0, 1:
                recorded.append(try await notes.record(captures.typed(sentence(), from: minute, to: minute + 0.5)))
            case 2:
                let recording = try await notes.record(captures.recording(from: minute, to: minute + 1))
                let segment = recording.segmentIDs[0]
                _ = try await notes.appendTranscript(
                    TranscriptionRun(
                        startsAt: .zero,
                        pieces: [TranscriptPiece(text: sentence(), range: Duration.zero..<Duration.seconds(1))],
                        resumeAt: nil,
                        provenance: TranscriptionProvenance(engine: "engine", locale: "en_GB", osBuild: "b")),
                    to: segment, job: JobID.transcribe(of: segment))
                _ = try await notes.applyCleanup(
                    CleanupResult(
                        outcome: .declined(.cleanupRefused), title: sentence(),
                        provenance: CleanupProvenance(osBuild: "b"),
                        modelName: "model"),
                    to: segment)
                recorded.append(recording)
            default:
                let drawing = try await notes.record(captures.drawing(from: minute, to: minute + 1))
                _ = try await notes.applyRecognition(
                    InkRecognition(
                        text: sentence(),
                        provenance: RecognitionProvenance(engineVersion: 9, language: "en-GB", osBuild: "b")),
                    to: drawing.segmentIDs[0])
                recorded.append(drawing)
            }
        }
        // Titles, deleted notes and deleted segments.
        for receipt in recorded.shuffled(using: &random).prefix(8) {
            _ = try? await notes.setTitle(sentence(), of: receipt.noteID, ifRevision: nil)
        }
        for receipt in recorded.shuffled(using: &random).prefix(6) {
            _ = try await notes.delete(.note(receipt.noteID))
        }
        for receipt in recorded.shuffled(using: &random).prefix(6) {
            _ = try? await notes.delete(.segment(receipt.segmentIDs[0]))
        }
        let records = try await Self.everyNote(database)
        var queries = vocabulary + vocabulary.map { String($0.prefix(3)) } + vocabulary.map { String($0.prefix(1)) }
        queries += (0..<20).map { _ in
            "\(vocabulary[random.next(in: 0...20)]) \(vocabulary[random.next(in: 0...20)].prefix(2))"
        }
        for query in queries {
            let found = try await notes.search(query, limit: 1_000)
            #expect(found == Self.plainScan(query, in: records), "Search for \(query.debugDescription), seed \(seed)")
            let deleted = Set(records.filter { !$0.isShown }.map(\.note.id))
            #expect(deleted.isDisjoint(with: found), "Never a deleted note.")
        }
        // The limit takes the first in the stream's order.
        let all = try await notes.search("a", limit: 1_000)
        #expect(try await notes.search("a", limit: 3) == Array(all.prefix(3)))
        expectConsistent(database)
    }
}

/// A small seeded generator, so that a failure names the seed that repeats it.
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}
