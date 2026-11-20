import Darwin
import Foundation
import GRDB
import Security
import notify

// The spike's synthetic store and the facts each process reports about itself. The app
// and every packaging of the tool compile this file. Nothing here is Knot's real store:
// the schema is two tables, the text is synthetic, and the folder carries the spike's name
// so that it can be removed by name.

enum Spike {
    /// The Darwin notification a writer posts after a commit (docs/architecture.md §7).
    static let changed = "com.p3ob7o.knot.dev.sp3.changed"
    /// The spike's folder inside the group container, and every file it may hold.
    static let folder = "SP3-spike"
    static let files = ["spike.sqlite", "spike.sqlite-wal", "spike.sqlite-shm", "group-export.md"]

    /// The app groups this process claims, read from its own signature, so that a tool with
    /// no Info.plist knows them too. Every piece claims two forms of the development group:
    /// `group.com.p3ob7o.knot.dev` and the Team-ID form, `<team>.com.p3ob7o.knot.dev`.
    static var claimedGroups: [String] {
        guard let task = SecTaskCreateFromSelf(nil) else { return [] }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil)
        return value as? [String] ?? []
    }

    /// `--team-group` on the command line picks the Team-ID form; otherwise the `group.` form.
    static let wantsTeamGroup = CommandLine.arguments.contains("--team-group")

    static var groupForm: String { wantsTeamGroup ? "team" : "group." }

    static var appGroup: String {
        let groups = claimedGroups
        let pick = groups.first { $0.hasPrefix("group.") == !wantsTeamGroup }
        return pick ?? "none claimed"
    }

    static var variant: String {
        Bundle.main.object(forInfoDictionaryKey: "KnotSP3Variant") as? String ?? "no Info.plist"
    }

    /// The user's real home, which a sandboxed process's NSHomeDirectory() is not.
    static var realHome: String {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: dir)
    }

    /// A path with the user's home written as `~`, so no report names a user's folder.
    static func tilde(_ path: String) -> String {
        let home = realHome
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static var sandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    /// What the process is: its packaging, its identity as the bundle reports it, and its
    /// sandbox.
    static func identity() -> [String: Any] {
        [
            "variant": variant,
            "bundleID": Bundle.main.bundleIdentifier ?? "none",
            "executable": tilde(Bundle.main.executablePath ?? CommandLine.arguments[0]),
            "sandboxed": sandboxed,
            "sandboxContainerID": ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "none",
            "home": tilde(NSHomeDirectory()),
            "appGroup": appGroup,
            "groupForm": groupForm,
            "claimedGroups": claimedGroups,
        ]
    }

    static func groupContainer() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static func spikeFolder() throws -> URL {
        guard let group = groupContainer() else { throw SpikeError.noGroupContainer }
        let folder = group.appending(path: Spike.folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Opens the store as Knot's real store is configured (docs/architecture.md §7): a pool
    /// in WAL mode, synchronous FULL, fullfsync on the writer, a 5-second busy timeout.
    static func openStore() throws -> DatabasePool {
        let url = try spikeFolder().appending(path: "spike.sqlite")
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
            if !db.configuration.readonly { try db.execute(sql: "PRAGMA fullfsync = ON") }
        }
        let pool = try DatabasePool(path: url.path, configuration: config)
        try pool.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS spike_note (
                        id INTEGER PRIMARY KEY, origin TEXT NOT NULL, text TEXT NOT NULL, createdAt REAL NOT NULL);
                    CREATE TABLE IF NOT EXISTS spike_counter (id INTEGER PRIMARY KEY CHECK (id = 1), value INTEGER NOT NULL);
                    INSERT OR IGNORE INTO spike_counter (id, value) VALUES (1, 0);
                    """)
        }
        return pool
    }

    struct State: Sendable {
        var counter: Int
        var notes: Int
        var lastOrigin: String?
        var journalMode: String

        var json: [String: Any] {
            ["counter": counter, "notes": notes, "lastOrigin": lastOrigin ?? "none", "journalMode": journalMode]
        }
    }

    static func read(_ pool: DatabasePool) throws -> State {
        try pool.read { db in
            State(
                counter: try Int.fetchOne(db, sql: "SELECT value FROM spike_counter WHERE id = 1") ?? 0,
                notes: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM spike_note") ?? 0,
                lastOrigin: try String.fetchOne(db, sql: "SELECT origin FROM spike_note ORDER BY id DESC LIMIT 1"),
                journalMode: try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "unknown")
        }
    }

    /// Writes one synthetic note and raises the counter in one transaction, then posts the
    /// Darwin notification. Returns the new counter and whether the post succeeded.
    static func add(_ pool: DatabasePool, origin: String, text: String) throws -> (counter: Int, posted: Bool) {
        let counter = try pool.write { db -> Int in
            try db.execute(
                sql: "INSERT INTO spike_note (origin, text, createdAt) VALUES (?, ?, ?)",
                arguments: [origin, text, Date().timeIntervalSince1970])
            try db.execute(sql: "UPDATE spike_counter SET value = value + 1 WHERE id = 1")
            return try Int.fetchOne(db, sql: "SELECT value FROM spike_counter WHERE id = 1") ?? 0
        }
        return (counter, notify_post(changed) == UInt32(NOTIFY_STATUS_OK))
    }

    /// The probe each process runs: who it is, whether it reaches the group container, and
    /// whether it can open the store for reading and writing.
    static func probe(origin: String, write: Bool) -> [String: Any] {
        var result = identity()
        guard let group = groupContainer() else {
            result["groupContainer"] = "none"
            result["store"] = "no group container"
            return result
        }
        result["groupContainer"] = tilde(group.path)
        do {
            let pool = try openStore()
            result["store"] = "opened"
            result["before"] = try read(pool).json
            if write {
                let written = try add(pool, origin: origin, text: "synthetic SP-3 probe")
                result["wrote"] = true
                result["posted"] = written.posted
                result["after"] = try read(pool).json
            }
        } catch {
            result["store"] = "failed"
            result["error"] = describe(error)
        }
        return result
    }

    /// Removes the spike's own files from the group container, by name, and its folder if
    /// that leaves it empty. Returns what it removed.
    static func cleanup() -> [String: Any] {
        guard let group = groupContainer() else { return ["removed": [String](), "error": "no group container"] }
        let folder = group.appending(path: Spike.folder, directoryHint: .isDirectory)
        var removed: [String] = []
        for name in files {
            let url = folder.appending(path: name)
            if (try? FileManager.default.removeItem(at: url)) != nil { removed.append(name) }
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if left.isEmpty, (try? FileManager.default.removeItem(at: folder)) != nil { removed.append(Spike.folder + "/") }
        return ["removed": removed, "left": left]
    }

    static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }

    static func json(_ object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

enum SpikeError: Error, CustomStringConvertible {
    case noGroupContainer
    var description: String { "the app group's container is not available to this process" }
}
