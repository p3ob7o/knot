import Foundation
import GRDB
import KnotTestSupport
import Testing

@testable import KnotApp
@testable import KnotCore
@testable import KnotStore

/// Nothing from outside this build reaches the diagnostics file: a value a newer Knot, or
/// anything else, wrote into the store is written only when this build knows it. Each test puts
/// a made-up word where one filter stands, as a newer build would leave it.
@Suite("The diagnostics export's filters")
struct DiagnosticsFilterTests {
    static let word = "quorvantine"

    /// A store holding one stored typed capture, and the composition over it.
    private static func storeWithOneCapture(_ folder: LiveFolder) async throws -> (LiveComposition, CaptureID) {
        let composition = folder.compose()
        _ = try #require(await launch(composition))
        let state = try await typeLine("a synthetic line", in: composition)
        _ = try await composition.environment.engine.end(state.captureID)
        return (composition, state.captureID)
    }

    private static func write(_ sql: String, _ arguments: StatementArguments, in composition: LiveComposition)
        async throws
    {
        try await composition.gate.ports().opened.database.pool.write { db in
            try db.execute(sql: sql, arguments: arguments)
        }
    }

    private static func exported(_ composition: LiveComposition) async throws -> (DiagnosticsFile, String) {
        let data = await composition.diagnostics.exportData()
        return (try JSONDecoder.iso8601.decode(DiagnosticsFile.self, from: data), String(decoding: data, as: UTF8.self))
    }

    @Test("An error code this build does not know is not written")
    func unknownCode() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let (composition, id) = try await Self.storeWithOneCapture(folder)
        try await Self.write(
            "UPDATE capture SET outcome = ? WHERE id = ?", ["failed:\(Self.word)_code", id.description], in: composition
        )
        let (file, json) = try await Self.exported(composition)
        #expect(!json.contains(Self.word))
        #expect(file.captures.first?.outcome == "failed:unlisted_code")
    }

    @Test("An open value this build does not know is written as unknown")
    func unknownOpenValue() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let (composition, id) = try await Self.storeWithOneCapture(folder)
        try await Self.write(
            "UPDATE capture SET surface = ? WHERE id = ?", ["\(Self.word)_surface", id.description], in: composition)
        let (file, json) = try await Self.exported(composition)
        #expect(!json.contains(Self.word))
        #expect(file.captures.first?.surface == "unknown")
    }

    @Test("probe-export-counter-name: a counter name this build does not know is not written")
    func unknownCounterName() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let (composition, _) = try await Self.storeWithOneCapture(folder)
        let day = try #require(try await Self.exported(composition).0.weekCounts.keys.first)
        try await Self.write(
            "INSERT INTO counter (day, name, value) VALUES (?, ?, 1)", [day, "\(Self.word)_counter"], in: composition)
        let (file, json) = try await Self.exported(composition)
        #expect(!json.contains(Self.word))
        #expect(file.weekCounts[day]?["captures_typed"] == 1)
    }
}
