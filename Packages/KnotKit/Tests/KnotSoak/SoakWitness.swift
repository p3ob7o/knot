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
        /// Which save of the script it answers.
        let save: Int
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
    /// The temporaries of writes a kill cut that recovery left in `Inbox/`, each once, by name
    /// (`InboxEntries`, `SoakRules.inboxPartialsAreRed`).
    private(set) var partials: Set<String> = []
    var partialsLeft: Int { partials.count }
    /// The kills since the last launch whose report counted all of `Inbox/`: as many temporaries
    /// of cut writes may be new at the next such count.
    private(set) var killsSinceFullCount = 0
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
    mutating func absorb(
        _ lines: [String], launch: Int, range: Range<Int>, end: LaunchEnd, afterKill: Bool,
        capturesDuringRecovery: Bool = false
    ) -> [Problem] {
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
        var recoveryReported = false
        var reportedPartials: Set<String> = []
        var partialCount = 0
        for line in parsed {
            switch line {
            case .intent(let index):
                if !recoveryReported, !capturesDuringRecovery {
                    problem("capture_before_recovery_report", "index=\(index)")
                }
                intents.append(index)
                highestIntent = max(highestIntent, index)
            case .discarding(_, let capture):
                discarding.insert(capture)
            case .ack(let a):
                acknowledgements[a.capture, default: []].append(
                    Acknowledgement(
                        index: a.index, capture: a.capture, revision: a.revision, bytes: a.bytes, digest: a.digest,
                        state: a.state, blank: a.blank, launch: launch, save: a.save))
                acknowledged += 1
                if !intents.contains(a.index) { problem("acknowledged_without_intent", "index=\(a.index)") }
            case .stopped(let point):
                stops.append(point)
            case .recoveryLeft(let open, let inbox, let partials):
                recoveryReported = true
                partialCount = partials
                if open > 0 { problem("recovery_left_rows_open", "count=\(open)") }
                if inbox > 0 { problem("recovery_left_inbox_items", "count=\(inbox)") }
            case .leftOpen(let capture):
                problem("recovery_left_row_open", capture.description)
            case .inboxPartial(let name):
                reportedPartials.insert(name)

            default:
                break
            }
        }
        if reportedPartials.count != partialCount { problem("inbox_partials_miscounted") }
        // A kill cuts at most one write into `Inbox/`: the child's saves run one at a time. A
        // launch that captures while it recovers counts only what is provably an earlier
        // launch's, so the kills before it are left to the next launch that counts everything.
        if afterKill { killsSinceFullCount += 1 }
        if capturesDuringRecovery {
            if SoakRules.inboxPartialsAreRed, !reportedPartials.isEmpty {
                problem("inbox_partials_left", "count=\(reportedPartials.count)")
            }
        } else if recoveryReported {
            problems += Self.partialProblems(
                reportedPartials, known: partials, allowance: killsSinceFullCount, red: SoakRules.inboxPartialsAreRed
            ).map { Problem(code: $0.code, ids: ["launch=\(launch)"] + $0.ids) }
            killsSinceFullCount = 0
        }
        partials.formUnion(reportedPartials)
        if intents != Array(range.lowerBound..<(range.lowerBound + intents.count)) || intents.count > range.count {
            problem("intents_out_of_order", "from=\(range.lowerBound)", "count=\(intents.count)")
        }
        switch end {
        case .quit:
            if !recoveryReported { problem("recovery_not_reported") }
            if parsed.last != .done || intents.count != range.count {
                let last = lines.last?.split(separator: " ").first.map(String.init) ?? "nothing"
                problem(
                    "launch_did_not_finish", "intents=\(intents.count)", "of=\(range.count)",
                    "last=\(SoakLine.parse(lines.last ?? "") == nil ? "unreadable" : last)")
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
    /// consistency check, then the soak's three assertions, then the witness's list. The script
    /// is the one the child ran: the parent knows every text of every save.
    func check(_ locations: StoreLocations, script: SoakScript) async throws -> [Problem] {
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
        let pieces = Self.pieces(segments)
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

        // What the person can get back: the store's own stream, every page of it. A capture that
        // was kept is there, in a note the stream shows, with every piece of its text.
        var shown: [CaptureID: [Segment]] = [:]
        var position: StreamPosition?
        var pagesRead = 0
        repeat {
            let page = try await notes.stream(after: position, limit: 100)
            for record in page.notes where record.isShown {
                for segment in record.liveSegments where segment.conflictOf == nil {
                    shown[CaptureID(segment.pieceOf ?? segment.id), default: []].append(segment)
                }
            }
            pagesRead += 1
            if (page.next != nil && page.next == position) || pagesRead > 10_000 {
                problems.append(Problem(code: "stream_does_not_end", ids: []))
                break
            }
            position = page.next
        } while position != nil

        // The captures of each capture of the script: those the child acknowledged, and those
        // whose stored text carries the script's token for it.
        let tokens = Dictionary(
            script.captures.compactMap { capture in capture.token.map { ($0, capture.index) } },
            uniquingKeysWith: { first, _ in first })
        var captures: [Int: Set<CaptureID>] = [:]
        for (capture, saves) in acknowledgements {
            for save in saves { captures[save.index, default: []].insert(capture) }
        }
        for segment in segments where segment.origin == device && segment.piece == 0 && segment.conflictOf == nil {
            guard let capture = segment.capture, let token = segment.token, let index = tokens[token] else { continue }
            captures[index, default: []].insert(capture)
        }

        // Nothing the stream shows from this device is a capture the script does not account for.
        let accounted = captures.values.reduce(into: Set<CaptureID>()) { $0.formUnion($1) }
        for (capture, segments) in shown.sorted(by: { $0.key < $1.key })
        where segments.contains(where: { $0.origin == device }) && !accounted.contains(capture) {
            problems.append(Problem(code: "segment_of_no_capture_of_the_script", ids: [capture.description]))
        }

        for (index, ids) in captures.sorted(by: { $0.key < $1.key }) {
            let planned = script.captures[index]
            var stored: [CaptureID] = []
            for capture in ids.sorted() {
                let saves = acknowledgements[capture] ?? []
                for save in saves where !Self.isOfTheScript(save, planned) {
                    problems.append(
                        Problem(
                            code: "acknowledgement_not_of_the_script",
                            ids: [capture.description, "index=\(index)", "save=\(save.save)"], launch: save.launch))
                }
                let found = try await expectation(
                    capture, index: index, planned: planned, saves: saves, pieces: pieces[capture] ?? [],
                    shown: shown[capture] ?? [], notes: notes)
                problems += found.problems
                if found.stored { stored.append(capture) }
            }
            // 3'. No capture of the script is stored twice.
            if stored.count > 1 {
                problems.append(
                    Problem(code: "capture_stored_twice", ids: ["index=\(index)"] + stored.map(\.description)))
            }
        }

        // Nothing waits in `Inbox/` once the last launch has recovered: every entry counts,
        // whatever its name, and a folder that cannot be listed is red too.
        problems += Self.inboxProblems(
            InboxEntries.list(locations), known: partials, allowance: killsSinceFullCount,
            red: SoakRules.inboxPartialsAreRed)
        return problems
    }

    /// 3. One capture against the script: an acknowledged capture is in the store, at least at
    /// the revision the engine reported as saved, and its stored text is exactly a text of the
    /// script, at or after the last save acknowledged; the end's own once the end was
    /// acknowledged.
    private func expectation(
        _ capture: CaptureID, index: Int, planned: SoakScript.Capture, saves: [Acknowledgement],
        pieces: [SegmentRow], shown: [Segment], notes: NoteRepository
    ) async throws -> (problems: [Problem], stored: Bool) {
        var problems: [Problem] = []
        let latest = saves.max { ($0.save, $0.revision) < ($1.save, $1.revision) }
        let launch = latest?.launch
        let ids = [capture.description, "index=\(index)"]
        func problem(_ code: String, _ more: [String] = []) {
            problems.append(Problem(code: code, ids: ids + more, launch: launch))
        }
        guard let row = try await notes.capture(capture) else {
            if latest != nil { problem("acknowledged_capture_missing") }
            return (problems, false)
        }
        let highest = saves.map(\.revision).max() ?? 0
        if row.revision < highest {
            problem("revision_below_acknowledged", ["stored=\(row.revision)", "acknowledged=\(highest)"])
        }
        let endAcknowledged = latest.map { $0.state != .open } ?? false
        switch row.outcome {
        case .open:
            return (problems, false)  // reported above
        case .failed(let code):
            problem("capture_failed", [code.rawValue])
            return (problems, false)
        case .discardedEmpty:
            if latest?.state == .ended {
                problem("acknowledged_text_discarded")
            } else if latest?.state == .open, !discarding.contains(capture), !planned.blank {
                problem("acknowledged_text_discarded")
            }
            return (problems, false)
        case .stored:
            // A capture of only spaces and line breaks ends discarded as empty, on the store's
            // path and on `Inbox/`'s, whatever was acknowledged of it.
            if planned.blank {
                problem("blank_capture_kept")
                return (problems, true)
            }
            if latest?.state == .discarded {
                problem("acknowledged_discard_stored")
                return (problems, true)
            }
            // Every piece, read in order through the stream: each the piece its position names,
            // with no gap, all in one note the stream shows.
            guard !shown.isEmpty else {
                problem(pieces.isEmpty ? "stored_capture_without_text" : "stored_capture_not_in_stream")
                return (problems, true)
            }
            let ordered = shown.sorted { $0.piece < $1.piece }
            for (position, piece) in ordered.enumerated()
            where piece.piece != position || piece.id != SegmentID.piece(position, of: capture) {
                problem("pieces_out_of_order", ["piece=\(piece.piece)", "position=\(position)"])
            }
            if Set(ordered.map(\.noteID)).count != 1 { problem("pieces_in_several_notes") }
            let text = ordered.map(\.text).joined()
            // The pieces its text needs, and no more.
            if ordered.count != TextPieces.split(text).count {
                problem("pieces_not_as_the_text_needs", ["pieces=\(ordered.count)"])
            }
            // The texts the store may hold: from the last acknowledged save on, or only the
            // last once the end was acknowledged.
            let first = endAcknowledged ? planned.texts.count - 1 : min(latest?.save ?? 0, planned.texts.count - 1)
            let allowed = planned.texts[first...]
            if !allowed.contains(text) {
                problem("acknowledged_text_not_stored", ["acknowledged_save=\(latest?.save ?? -1)"])
            } else if let latest, row.revision == latest.revision, latest.state == .open,
                text != planned.texts[min(latest.save, planned.texts.count - 1)]
            {
                problem("text_not_of_its_revision", ["revision=\(row.revision)", "save=\(latest.save)"])
            }
            return (problems, true)
        }
    }

    /// What the temporaries of cut writes in `Inbox/` say: more new ones than `allowance`, the
    /// kills that could have cut them, is red by a code of its own; and any at all is red once
    /// `red` is, by `inbox_partials_left`.
    static func partialProblems(_ found: Set<String>, known: Set<String>, allowance: Int, red: Bool) -> [Problem] {
        var problems: [Problem] = []
        let new = found.subtracting(known)
        if new.count > allowance {
            problems.append(
                Problem(code: "inbox_partials_beyond_kills", ids: ["new=\(new.count)", "kills=\(allowance)"]))
        }
        if red, !found.isEmpty {
            problems.append(Problem(code: "inbox_partials_left", ids: ["count=\(found.count)"]))
        }
        return problems
    }

    /// What `Inbox/` holds once the last launch has recovered: every entry counts, dot-named or
    /// not; only the temporaries of cut writes already seen after a kill are set apart.
    static func inboxProblems(_ entries: InboxEntries?, known: Set<String>, allowance: Int = 0, red: Bool)
        -> [Problem]
    {
        guard let entries else { return [Problem(code: "inbox_not_listed", ids: [])] }
        var problems = partialProblems(entries.partials, known: known, allowance: allowance, red: red)
        if entries.others > 0 { problems.append(Problem(code: "inbox_items_left", ids: ["count=\(entries.others)"])) }
        return problems
    }

    /// Whether an acknowledgement names a save the script has, with that save's text.
    static func isOfTheScript(_ save: Acknowledgement, _ planned: SoakScript.Capture) -> Bool {
        let text: String
        switch save.state {
        case .discarded: text = ""
        case .ended: text = planned.texts[planned.texts.count - 1]
        case .open:
            guard planned.texts.indices.contains(save.save) else { return false }
            text = planned.texts[save.save]
        }
        let bytes = Data(text.utf8)
        return bytes.count == save.bytes && digest(bytes) == save.digest
    }

    /// The live pieces of each capture, by position: not deleted, and not conflict copies.
    static func pieces(_ segments: [SegmentRow]) -> [CaptureID: [SegmentRow]] {
        var pieces: [CaptureID: [SegmentRow]] = [:]
        for segment in segments where !segment.deleted && segment.conflictOf == nil {
            guard let capture = segment.capture else { continue }
            pieces[capture, default: []].append(segment)
        }
        return pieces.mapValues { $0.sorted { $0.piece < $1.piece } }
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
        let deleted: Bool
        let text: String
        /// The first word of its text: the script's token for its capture.
        var token: String? { text.split(separator: " ", maxSplits: 1).first.map(String.init) }
    }

    /// Every segment in the store, read on a connection of the witness's own that only reads.
    static func segments(in locations: StoreLocations) throws -> [SegmentRow] {
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: locations.database.path, configuration: configuration)
        defer { try? queue.close() }
        return try queue.read { db in
            try Row.fetchAll(
                db, sql: "SELECT id, capture_id, origin, piece, conflict_of, deleted_at, text FROM segment"
            ).map {
                row in
                let text: String = row["text"]
                return SegmentRow(
                    id: row["id"], capture: (row["capture_id"] as String?).flatMap(CaptureID.init),
                    origin: SegmentOrigin(rawValue: row["origin"]), piece: row["piece"], conflictOf: row["conflict_of"],
                    deleted: (row["deleted_at"] as Double?) != nil, text: text)
            }
        }
    }
}
