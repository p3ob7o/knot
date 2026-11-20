// Stage 2's runner: the real CKSyncEngine, driven from the command line of a simulator, so
// that an agent runs each step with `simctl launch --console` and reads the lines it prints.
// Every line is a count, a size, a duration or a code. The text it writes is synthetic.
//
//   -SP4Live account                       the account's status, the container, the environment
//   -SP4Live seed <notes> <segments>       make notes with that many segments each, locally
//   -SP4Live sync                          fetch, send, fetch, with the engine's automatic sync off
//   -SP4Live dump                          counts and the size of the engine's saved state
//   -SP4Live delete-zone                   remove the Stream zone (development environment only)
//   -SP4Live reset-local                   forget the local store and the engine's state
//   -SP4Live delegate-weak                 does the engine keep its delegate alive? (no account needed)
//   -SP4Container dev | spike4             which allowed container (the default follows the build)
//   -SP4Timeout <seconds>                  a limit on each fetch and send (300)
//
// It runs only in a build signed with the team, whose Info.plist says KnotSyncAvailable = YES.

import CloudKit
import CryptoKit
import Foundation

enum LiveRunner {
    static func run(_ arguments: [String]) async -> Int32 {
        guard let index = arguments.firstIndex(of: "-SP4Live"), index + 1 < arguments.count else {
            say("usage: -SP4Live account | seed N M | sync | dump | delete-zone | reset-local")
            return 2
        }
        let command = arguments[index + 1]
        let rest = Array(arguments[(index + 2)...])
        let requested = value(after: "-SP4Container", in: arguments).map {
            $0 == "spike4" ? LiveSync.spikeContainer : $0 == "dev" ? LiveSync.developmentContainer : $0
        }
        let target: LiveSync.Target
        do {
            target = try LiveSync.target(requested: requested)
        } catch {
            say("refused \(error)")
            return 3
        }
        say("target container=\(target.container) environment=\(target.environment)")
        let file = storeFile(for: target)
        switch command {
        case "account":
            return await account(target)
        case "delegate-weak":
            return delegateWeak(target)
        case "reset-local":
            try? FileManager.default.removeItem(at: file)
            say("reset-local done")
            return 0
        default:
            break
        }
        let store = load(file)
        let code: Int32
        switch command {
        case "seed":
            let notes = Int(rest.first ?? "") ?? 1
            let segments = Int(rest.dropFirst().first ?? "") ?? 1
            await seed(store, notes: notes, segments: segments)
            code = 0
        case "sync":
            code = await sync(store, target: target, deleteZone: false, timeout: timeout(arguments))
        case "delete-zone":
            guard target.environment == "Development" else {
                say("refused delete-zone outside the development environment")
                return 3
            }
            code = await sync(store, target: target, deleteZone: true, timeout: timeout(arguments))
        case "dump":
            await dump(store)
            code = 0
        default:
            say("unknown command \(command)")
            return 2
        }
        await save(store, to: file)
        return code
    }

    // MARK: - Commands

    static func account(_ target: LiveSync.Target) async -> Int32 {
        let container = CKContainer(identifier: target.container)
        do {
            let status = try await container.accountStatus()
            say("account status=\(status.rawValue) (0 couldNotDetermine, 1 available, 2 restricted, 3 noAccount, 4 temporarilyUnavailable)")
            if status == .available {
                let user = try await container.userRecordID()
                say("account user=\(short(user.recordName))")
            }
            return 0
        } catch let error as CKError {
            say("account error code=\(error.errorCode)")
            return 1
        } catch {
            say("account error \(type(of: error))")
            return 1
        }
    }

    static func seed(_ store: SpikeStore, notes: Int, segments: Int) async {
        let start = Date()
        await store.write { replica in
            for n in 0..<notes {
                let note = UUID()
                replica.createNote(note, at: start.addingTimeInterval(Double(n)))
                for s in 0..<segments {
                    replica.append(UUID(), to: note, text: "Synthetic segment \(s) of note \(n).",
                                   startedAt: start.addingTimeInterval(Double(n) + Double(s) / 100))
                }
            }
        }
        say("seed notes=\(notes) segments=\(notes * segments) pending=\(await store.replica.pending.count)")
    }

    static func timeout(_ arguments: [String]) -> Double { value(after: "-SP4Timeout", in: arguments).flatMap(Double.init) ?? 300 }

    static func sync(_ store: SpikeStore, target: LiveSync.Target, deleteZone: Bool, timeout: Double) async -> Int32 {
        let adapter = SyncAdapter(store: store, generation: await store.generation)
        let engine = LiveSync.makeEngine(adapter: adapter, state: await store.savedState, target: target,
                                         automaticallySync: false)
        if deleteZone {
            engine.state.add(pendingDatabaseChanges: [.deleteZone(Zones.stream)])
        } else if !(await store.zoneSaved) {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Zones.stream))])
        }
        if !(await store.replica.pending.isEmpty) { engine.state.hasPendingUntrackedChanges = true }
        var failed = false
        for step in deleteZone ? ["send"] : ["fetch", "send", "fetch"] {
            let start = Date()
            do {
                try await withTimeout(seconds: timeout) {
                    if step == "fetch" { try await engine.fetchChanges() } else { try await engine.sendChanges() }
                }
                say("\(step) ok \(milliseconds(since: start)) ms")
            } catch let error as CKError {
                failed = true
                say("\(step) error code=\(error.errorCode) retryAfter=\(error.retryAfterSeconds.map { String($0) } ?? "-") \(milliseconds(since: start)) ms")
            } catch is TimedOut {
                failed = true
                say("\(step) timedOut after \(milliseconds(since: start)) ms")
            } catch {
                failed = true
                say("\(step) error \(type(of: error)) \(milliseconds(since: start)) ms")
            }
        }
        say("engine pendingRecordZoneChanges=\(engine.state.pendingRecordZoneChanges.count) pendingDatabaseChanges=\(engine.state.pendingDatabaseChanges.count) untracked=\(engine.state.hasPendingUntrackedChanges)")
        await engine.cancelOperations()
        await report(store)
        _ = adapter
        return failed ? 1 : 0
    }

    static func dump(_ store: SpikeStore) async { await report(store) }

    /// The Objective-C configuration holds its delegate weakly; the Swift one does not say.
    static func delegateWeak(_ target: LiveSync.Target) -> Int32 {
        weak var probe: SyncAdapter?
        var engine: CKSyncEngine?
        do {
            let adapter = SyncAdapter(store: SpikeStore(device: UUID()), generation: 1)
            probe = adapter
            engine = LiveSync.makeEngine(adapter: adapter, state: nil, target: target, automaticallySync: false)
        }
        say("delegate engineAlive=\(engine != nil) delegateAliveAfterLastReference=\(probe != nil)")
        engine = nil
        say("delegate delegateAliveAfterEngineReleased=\(probe != nil)")
        return 0
    }

    static func report(_ store: SpikeStore) async {
        let r = await store.replica
        say("store notes=\(r.notes.count) segments=\(r.segments.count) pending=\(r.pending.count) synced=\(r.synced.count) waiting=\(r.waiting.count) conflictCopies=\(r.segments.values.filter { $0.value.conflictOf != nil }.count)")
        say("state bytes=\(await store.savedState?.count ?? 0) systemFields=\(await store.systemFields.count) zoneSaved=\(await store.zoneSaved)")
        for (name, n) in await store.counters.sorted(by: { $0.key < $1.key }) { say("count \(name)=\(n)") }
        for line in await store.lines { say("line \(line)") }
        for question in await store.questions { say("question \(question)") }
    }

    // MARK: - Files

    static func storeFile(for target: LiveSync.Target) -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SP4", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(target.container)-\(target.environment).json")
    }

    static func load(_ file: URL) -> SpikeStore {
        if let data = try? Data(contentsOf: file),
           let persisted = try? JSONDecoder().decode(SpikeStore.Persisted.self, from: data) {
            return SpikeStore(persisted)
        }
        return SpikeStore(device: UUID())
    }

    static func save(_ store: SpikeStore, to file: URL) async {
        do {
            let data = try JSONEncoder().encode(await store.persisted)
            try data.write(to: file, options: .atomic)
        } catch {
            say("save error \(type(of: error))")
        }
    }

    // MARK: - Helpers

    static func say(_ line: String) {
        print("sp4live: \(line)")
        fflush(stdout)
    }

    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    static func short(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func milliseconds(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    struct TimedOut: Error {}

    static func withTimeout(seconds: Double, _ body: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimedOut()
            }
            try await group.next()
            group.cancelAll()
        }
    }
}
