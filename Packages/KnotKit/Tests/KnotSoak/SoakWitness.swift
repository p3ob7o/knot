import CryptoKit
import Foundation
import GRDB
import KnotCore
import KnotStore

@testable import KnotSoakChild

/// The parent as the witness (docs/architecture.md §17): it keeps every save the child said the
/// engine acknowledged, with its revision and the hash of its text, and once the last launch has
/// recovered it checks each one against the store. A capture that vanished whole therefore fails
/// the run, as does one that kept less than it was acknowledged with.
struct SoakWitness {
    /// One acknowledged save of one capture.
    typealias State = SoakLine.Acknowledgement.State

    struct Acknowledgement: Hashable, Sendable {

        let index: Int
        let capture: CaptureID
        let revision: Int64
        /// The UTF-8 length and digest of the capture's whole text at that save.
        let bytes: Int
        let digest: String
        let state: State
        /// Whether that text is only spaces and line breaks.
        let blank: Bool
        /// The launch that acknowledged it.
        let launch: Int
    }

    /// One thing the soak found wrong: a code, and the IDs and indexes it concerns, never text.
    struct Problem: Hashable, Sendable, CustomStringConvertible {
        let code: String
        let ids: [String]
        /// The launch whose acknowledgement it breaks, if any.
        var launch: Int?

        var description: String {
            ([code] + ids).joined(separator: " ") + (launch.map { " (acknowledged in launch \($0))" } ?? "")
        }
    }

    private(set) var acknowledgements: [CaptureID: [Acknowledgement]] = [:]
    /// The highest index of the script whose capture a launch began.
    private(set) var highestIntent = -1
    private(set) var acknowledged = 0
    /// The captures the script discarded, or was about to: one may end empty, whatever it was
    /// acknowledged with before.
    private(set) var discarding: Set<CaptureID> = []

    /// How one launch ended, as the parent saw it.
    enum LaunchEnd: Sendable {
        /// Killed at its armed kill point, which it said it reached.
        case killedAtPoint(String)
        /// Killed after its nth acknowledgement, wherever it was.
        case killedAnywhere
        /// Ran its part and quit by itself, with status 0.
        case quit
        /// Anything else: an error, or a wait that ran out.
        case failed
    }

    /// Takes in what one launch printed, and returns what is wrong with its account. Every line
    /// must parse; the launch says which launch it is first; its intents run from the start of
    /// its range with no gap; a launch that quit says `done` after an intent for every index of
    /// its range; and a launch killed at its point said it stopped at that point and no other.
    mutating func absorb(_ lines: [String], launch: Int, range: Range<Int>, end: LaunchEnd) -> [Problem] {
        var problems: [Problem] = []
        func problem(_ code: String, _ ids: String...) {
            problems.append(Problem(code: code, ids: ["launch=\(launch)"] + ids))
        }
        var parsed: [SoakLine] = []
        for (number, line) in lines.enumerated() {
            guard let read = SoakLine.parse(line) else {
                // Its length only: a line that does not parse may hold anything.
                problem("unreadable_line", "line=\(number + 1)", "bytes=\(line.utf8.count)")
                continue
            }
            parsed.append(read)
        }
        if parsed.first != .launch(launch) { problem("launch_line_missing") }
        var intents: [Int] = []
        var stops: [String] = []
        for line in parsed {
            switch line {
            case .intent(let index):
                intents.append(index)
                highestIntent = max(highestIntent, index)
            case .discarding(_, let capture):
                discarding.insert(capture)
            case .ack(let a):
                acknowledgements[a.capture, default: []].append(
                    Acknowledgement(
                        index: a.index, capture: a.capture, revision: a.revision, bytes: a.bytes, digest: a.digest,
                        state: State(rawValue: a.state.rawValue) ?? .open, blank: a.blank, launch: launch))
                acknowledged += 1
                if !intents.contains(a.index) { problem("acknowledged_without_intent", "index=\(a.index)") }
            case .stopped(let point):
                stops.append(point)
            default:
                break
            }
        }
        if intents != Array(range.lowerBound..<(range.lowerBound + intents.count)) || intents.count > range.count {
            problem("intents_out_of_order", "from=\(range.lowerBound)", "count=\(intents.count)")
        }
        switch end {
        case .quit:
            if parsed.last != .done || intents.count != range.count {
                problem("launch_did_not_finish", "intents=\(intents.count)", "of=\(range.count)")
            }
            if !stops.isEmpty { problem("stopped_and_quit") }
        case .killedAtPoint(let armed):
            if stops != [armed] { problem("stopped_at_other_point", "armed=\(armed)") }
        case .killedAnywhere:
            if !stops.isEmpty { problem("stopped_unarmed") }
        case .failed:
            break
        }
        return problems
    }

    /// Every check of the run, on the store as the last recovery left it: the store's own
    /// consistency check, then the soak's three assertions, then the witness's list.
    func check(_ locations: StoreLocations, seed: UInt64) async throws -> [Problem] {
        var problems: [Problem] = []
        let database = try StoreDatabase.open(locations: locations, role: .app)
        defer { try? database.close() }
        let notes = NoteRepository(database: database)

        // The one consistency check, shared with the store's tests and the diagnostics export.
        for problem in try database.consistencyProblems() {
            problems.append(Problem(code: "consistency_\(problem.code)", ids: problem.ids))
        }

        // 1. No capture row is still open.
        for row in try await notes.openCaptures() {
            problems.append(Problem(code: "capture_left_open", ids: [row.id.description]))
        }

        // 2. Every segment that originated on this device has a capture row.
        let segments = try Self.segments(in: locations)
        let device = SegmentOrigin.device(database.deviceID)
        for segment in segments where segment.origin == device {
            guard let capture = segment.capture else {
                problems.append(Problem(code: "segment_without_capture", ids: [segment.id]))
                continue
            }
            if try await notes.capture(capture) == nil {
                problems.append(Problem(code: "segment_without_capture_row", ids: [segment.id]))
            }
        }

        // 3. Every acknowledged capture is in the store, at least at the revision the engine
        // reported as saved, with the text it acknowledged.
        for (capture, saves) in acknowledgements.sorted(by: { $0.key.description < $1.key.description }) {
            // The highest revision, and at a tie the end, which names how the capture ended.
            func rank(_ save: Acknowledgement) -> (Int64, Int) { (save.revision, save.state == .open ? 0 : 1) }
            guard let latest = saves.max(by: { rank($0) < rank($1) }) else { continue }
            let ids = [capture.description, "index=\(latest.index)"]
            guard let row = try await notes.capture(capture) else {
                problems.append(Problem(code: "acknowledged_capture_missing", ids: ids, launch: latest.launch))
                continue
            }
            if row.revision < latest.revision {
                problems.append(
                    Problem(
                        code: "revision_below_acknowledged",
                        ids: ids + ["stored=\(row.revision)", "acknowledged=\(latest.revision)"], launch: latest.launch)
                )
            }
            switch row.outcome {
            case .open:
                continue  // reported above
            case .discardedEmpty:
                if !discarding.contains(capture), saves.contains(where: { !$0.blank && $0.state != .discarded }) {
                    problems.append(
                        Problem(code: "acknowledged_text_discarded", ids: ids, launch: latest.launch))
                }
            case .failed(let code):
                problems.append(
                    Problem(code: "acknowledged_capture_failed", ids: ids + [code.rawValue], launch: latest.launch))
            case .stored:
                if latest.state == .discarded {
                    problems.append(Problem(code: "acknowledged_discard_stored", ids: ids, launch: latest.launch))
                    continue
                }
                let text = try await notes.segment(SegmentID(capture))?.text
                guard let text else {
                    problems.append(Problem(code: "stored_capture_without_text", ids: ids, launch: latest.launch))
                    continue
                }
                // A later save only adds to the text, so the stored text begins with the text of
                // every acknowledged save.
                for save in saves where save.state != .discarded && !Self.begins(text, with: save) {
                    problems.append(
                        Problem(
                            code: "acknowledged_text_not_stored",
                            ids: [capture.description, "index=\(save.index)", "revision=\(save.revision)"],
                            launch: save.launch))
                }
            }
        }

        // No capture is stored twice: each capture of the script is in at most one stored
        // capture. A script's text begins with a token that names its capture.
        var holders: [String: [String]] = [:]
        for segment in segments where segment.origin == device && segment.piece == 0 && segment.conflictOf == nil {
            guard let capture = segment.capture, let row = try await notes.capture(capture), row.outcome == .stored,
                let token = segment.token, token.hasPrefix("s\(seed)c")
            else { continue }
            holders[token, default: []].append(capture.description)
        }
        for (token, captures) in holders.sorted(by: { $0.key < $1.key }) where captures.count > 1 {
            problems.append(
                Problem(
                    code: "capture_stored_twice",
                    ids: [token.dropFirst("s\(seed)".count).description] + captures.sorted()))
        }

        // Nothing waits in `Inbox/` once the last launch has recovered.
        let left =
            ((try? FileManager.default.contentsOfDirectory(atPath: locations.inbox.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
        if !left.isEmpty { problems.append(Problem(code: "inbox_items_left", ids: ["count=\(left.count)"])) }
        return problems
    }

    /// Whether `text` begins with the text that `save` acknowledged, by the digest of its first
    /// bytes.
    static func begins(_ text: String, with save: Acknowledgement) -> Bool {
        let bytes = Data(text.utf8)
        guard bytes.count >= save.bytes else { return false }
        return digest(bytes.prefix(save.bytes)) == save.digest
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A segment as the witness reads it, straight from the database.
    struct SegmentRow {
        let id: String
        let capture: CaptureID?
        let origin: SegmentOrigin
        let piece: Int
        let conflictOf: String?
        /// The first word of its text: the script's token for its capture.
        let token: String?
    }

    /// Every segment in the store, read on a connection of the witness's own that only reads.
    static func segments(in locations: StoreLocations) throws -> [SegmentRow] {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: locations.database.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, capture_id, origin, piece, conflict_of, text FROM segment").map {
                row in
                let text: String = row["text"]
                return SegmentRow(
                    id: row["id"], capture: (row["capture_id"] as String?).flatMap(CaptureID.init),
                    origin: SegmentOrigin(rawValue: row["origin"]), piece: row["piece"], conflictOf: row["conflict_of"],
                    token: text.split(separator: " ", maxSplits: 1).first.map(String.init))
            }
        }
    }
}
