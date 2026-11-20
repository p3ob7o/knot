import Foundation
import GRDB
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotStore

/// Every query in the `NoteStore` contract has an index, a stream page is one query, and the
/// test shows each query's plan (docs/architecture.md §17). The gate asserts plans and counts
/// of operations, never times.
@Suite struct QueryPlanTests {
    /// The statements a store ran, as SQL with no values.
    final class Statements: Sendable {
        private let seen = Mutex<[String]>([])

        func add(_ sql: String) { seen.withLock { $0.append(sql) } }

        var all: [String] { seen.withLock { $0 } }

        func clear() { seen.withLock { $0 = [] } }
    }

    /// The tables a query may not scan whole: every table that grows with the notes.
    static let largeTables: Set<String> = [
        "note", "segment", "capture", "asset", "job", "segment_history", "tombstone", "change_log", "revision_floor",
        "counter", "segment_search", "title_search",
    ]

    /// The partial indexes whose scan reads only the rows a query wants.
    static let boundedIndexes = ["capture_open", "note_stream"]

    /// The plan lines of one statement that scan a large table whole.
    static func unindexedScans(in plan: [String]) -> [String] {
        plan.filter { line in
            guard line.hasPrefix("SCAN ") else { return false }
            let table = line.dropFirst("SCAN ".count).split(separator: " ").first.map(String.init) ?? ""
            guard largeTables.contains(table) else { return false }
            // A scan through an index reads the whole index, unless the index is partial and
            // holds only what the query wants: the open captures, or the shown notes in the
            // stream's order, which a page reads to its limit and no further.
            for index in boundedIndexes where line.hasSuffix("USING INDEX \(index)") { return false }
            // A full-text table is searched through its index when the plan names a constraint.
            if let index = line.range(of: "VIRTUAL TABLE INDEX ") {
                let constraint = line[index.upperBound...].split(separator: ":", maxSplits: 1)
                return constraint.count < 2 || constraint[1].isEmpty
            }
            return true
        }
    }

    @Test("query-plan-shows-index-for-every-query", .tags(.named))
    func queryPlanShowsIndexForEveryQuery() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let statements = Statements()
        let hooks = StoreHooks(statements: { statements.add($0) })
        // Every query that the whole contract suite makes the store run.
        let factory: NoteStoreFactory = { setup in
            do {
                let database = try StoreDatabase.open(
                    locations: .testing(root: folders.make()), role: .app, clock: setup.clock, ids: setup.ids,
                    creation: StoreCreation(deviceID: setup.deviceID, generation: setup.generation), hooks: hooks)
                let notes = NoteRepository(database: database)
                try await setWindow(setup.window, in: database)
                if !setup.seed.isEmpty { try await notes.seed(setup.seed) }
                return NoteStoreSubject(store: notes) { try await notes.applySyncedNoteChange($0, to: $1) }
            } catch {
                Issue.record("The store did not open: \(error)")
                return NoteStoreSubject(store: UnavailableNoteStore(), applySyncedNoteChange: nil)
            }
        }
        try await NoteStoreContract.run(factory)
        // And the purge with work to do, which the suite reaches only in part.
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 61, clock: clock)
        let database = try openStore(in: folders.make(), clock: clock, ids: ids, hooks: hooks)
        let notes = NoteRepository(database: database)
        let captures = Captures(clock: clock, ids: ids, device: database.deviceID)
        let receipt = try await notes.record(captures.typed("A synthetic line", from: 0, to: 1))
        _ = try await notes.delete(.note(receipt.noteID))
        clock.advance(by: 40 * 86_400)
        _ = try await notes.purge(before: clock.now())

        let queries = Set(statements.all.filter(Self.isQuery))
        #expect(queries.count > 30, "The suite ran the store's queries: \(queries.count).")
        let plans = try await database.pool.read { db -> [(sql: String, plan: [String])] in
            try queries.sorted().map { sql in
                let placeholders = sql.filter { $0 == "?" }.count
                let rows = try Row.fetchAll(
                    db, sql: "EXPLAIN QUERY PLAN \(sql)",
                    arguments: StatementArguments(Array(repeating: DatabaseValue.null, count: placeholders)))
                return (sql, rows.map { $0["detail"] as String })
            }
        }
        for (sql, plan) in plans {
            let scans = Self.unindexedScans(in: plan)
            #expect(scans.isEmpty, "A query with no index:\n\(sql)\n\(plan.joined(separator: "\n"))")
        }
        print(
            "The plan of every query in the NoteStore contract:\n"
                + plans.map { "\($0.sql)\n    " + $0.plan.joined(separator: "\n    ") }.joined(separator: "\n\n"))
    }

    /// A stream page is one query, whatever its size, and reading a note is one for the note
    /// and one for its segments.
    @Test func aStreamPageIsOneQuery() async throws {
        let folders = TemporaryFolders()
        defer { folders.removeAll() }
        let statements = Statements()
        let clock = FakeClock(Captures.base)
        let ids = SeededIDGenerator(seed: 62, clock: clock)
        let database = try openStore(
            in: folders.make(), clock: clock, ids: ids, hooks: StoreHooks(statements: { statements.add($0) }))
        let notes = NoteRepository(database: database)
        let captures = Captures(clock: clock, ids: ids, device: database.deviceID)
        for minute in stride(from: 0.0, to: 300, by: 10) {
            _ = try await notes.record(captures.typed("Synthetic \(minute)", from: minute, to: minute + 1))
            _ = try await notes.record(captures.typed("More \(minute)", from: minute + 1.5, to: minute + 2))
        }
        var position: StreamPosition?
        var pages = 0
        repeat {
            statements.clear()
            let page = try await notes.stream(after: position, limit: 7)
            #expect(statements.all.filter(Self.isQuery).count == 1, "One page, one query: \(statements.all)")
            #expect(page.notes.allSatisfy { $0.segments.count == 2 })
            position = page.next
            pages += 1
        } while position != nil
        #expect(pages == 5, "30 notes in pages of 7.")
    }

    /// A statement that reads or changes rows by a condition, which needs an index: not a
    /// trigger's statement, not the store's set-up, and not an insert of values.
    static func isQuery(_ sql: String) -> Bool {
        let head = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !head.hasPrefix("--") else { return false }
        if head.hasPrefix("SELECT") || head.hasPrefix("WITH") || head.hasPrefix("UPDATE") || head.hasPrefix("DELETE") {
            return !head.hasPrefix("SELECT COUNT(*) FROM")
        }
        return head.hasPrefix("INSERT") && head.contains("SELECT")
    }
}
