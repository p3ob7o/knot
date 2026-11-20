// Stage 2's runner: the real CKSyncEngine, driven from the command line of a simulator, so
// that an agent runs each step with `simctl launch --console` and reads the lines it prints.
// Every line is a count, a size, a duration, a code or a digest. The text it writes is
// synthetic. The account's identifier is never printed, not even hashed.
//
// Through the engine, with automatic sync off unless `listen`:
//   seed N M                 make N notes of M segments each, locally (-SP4TextBytes B, -SP4Voice)
//   delete-notes K           mark the first K notes deleted, locally
//   edit-titles              give every note a new title, locally
//   move                     move one segment of a note that has two or more to a new note
//   sync                     fetch, send, fetch (-SP4Builder engine, -SP4IgnorePause,
//                            -SP4CancelTask MS, -SP4CancelOps MS, -SP4MaxBytes B, -SP4Trace)
//   listen SECONDS           automatic sync on, wait, report (-SP4NoExclude, -SP4Trace)
//   delete-zone              remove the Stream zone (development environment only)
//   state-tracked N          add N pending saves to the engine's own list, read the state's size, remove them
//   dump, reset-local, account, delegate-weak
// Straight to CKDatabase, outside the engine, development environment only:
//   future-write, future-read            a field from a newer build, kept by the server?
//   size-probe plain|encrypted LO HI     the largest string field a record takes, to 1 KiB
//   asset-probe BYTES                    one asset of that size
//   probe-cleanup                        remove the Probe zone
//   attachments-put, attachments-delete-zone, asset-fetch
//   schema-seed                          one note and one segment with every field set, so the
//                                        development schema holds every field before a deploy
//   -SP4Container dev | spike4, -SP4Timeout SECONDS (300)
//
// It runs only in a build signed with the team, whose Info.plist says KnotSyncAvailable = YES.

import CloudKit
import CryptoKit
import Foundation

enum LiveRunner {
    static func run(_ arguments: [String]) async -> Int32 {
        guard let index = arguments.firstIndex(of: "-SP4Live"), index + 1 < arguments.count else {
            say("usage: see LiveRunner.swift")
            return 2
        }
        let command = arguments[index + 1]
        let rest = Array(arguments[(index + 2)...]).filter { !$0.hasPrefix("-SP4") }
        let options = Options(arguments)
        let target: LiveSync.Target
        do {
            target = try LiveSync.target(requested: options.container)
        } catch {
            say("refused \(error)")
            return 3
        }
        say("target container=\(target.container) environment=\(target.environment)")
        let database = CKContainer(identifier: target.container).privateCloudDatabase
        let directCommands = ["schema-seed", "future-write", "future-read", "size-probe", "asset-probe", "probe-cleanup",
                      "attachments-put", "attachments-delete-zone", "asset-fetch", "delete-zone"]
        if directCommands.contains(command), target.environment != "Development" {
            say("refused \(command) outside the development environment")
            return 3
        }
        let file = storeFile(for: target)
        switch command {
        case "account": return await account(target)
        case "delegate-weak": return delegateWeak(target)
        case "reset-local":
            try? FileManager.default.removeItem(at: file)
            say("reset-local done")
            return 0
        case "size-probe": return await sizeProbe(database, rest)
        case "asset-probe": return await assetProbe(database, Int(rest.first ?? "") ?? 1_000_000)
        case "probe-cleanup": return await direct(database, "probe-cleanup") {
            _ = try await database.modifyRecordZones(saving: [], deleting: [probeZone])
        }
        case "attachments-put": return await attachmentsPut(database)
        case "attachments-delete-zone": return await direct(database, "attachments-delete-zone") {
            _ = try await database.modifyRecordZones(saving: [], deleting: [Zones.attachments])
        }
        case "asset-fetch": return await assetFetch(database)
        case "schema-seed": return await schemaSeed(database)
        default: break
        }
        let store = load(file)
        var code: Int32 = 0
        let start = Date()
        switch command {
        case "seed":
            let notes = Int(rest.first ?? "") ?? 1
            let segments = Int(rest.dropFirst().first ?? "") ?? 1
            await seed(store, notes: notes, segments: segments, textBytes: options.textBytes, voice: options.voice)
        case "delete-notes":
            let k = Int(rest.first ?? "") ?? 1
            await store.write { r in
                for id in r.notes.keys.sorted(by: { $0.uuidString < $1.uuidString }).prefix(k) { r.deleteNote(id, at: Date()) }
            }
            say("delete-notes \(k) pending=\(await store.replica.pending.count)")
        case "edit-titles":
            await store.write { r in
                for (i, id) in r.notes.keys.sorted(by: { $0.uuidString < $1.uuidString }).enumerated() {
                    r.setTitle(id, "Edited title \(i)", at: Date())
                }
            }
            say("edit-titles pending=\(await store.replica.pending.count)")
        case "move":
            await store.write { r in
                let byNote = Dictionary(grouping: r.segments.values.map(\.value).filter { $0.deletedAt == nil }, by: \.noteID)
                guard let (_, group) = byNote.first(where: { $0.value.count >= 2 }),
                      let segment = group.sorted(by: { $0.id.uuidString < $1.id.uuidString }).last else { return }
                r.move(segment.id, toNewNote: KnotID.v7(at: Date(), sequence: 1))
            }
            say("move pending=\(await store.replica.pending.count)")
        case "sync":
            code = await sync(store, target: target, options: options, deleteZone: false)
        case "delete-zone":
            code = await sync(store, target: target, options: options, deleteZone: true)
        case "listen":
            code = await listen(store, target: target, options: options, seconds: Double(rest.first ?? "") ?? 60)
        case "state-tracked":
            code = await stateTracked(store, target: target, count: Int(rest.first ?? "") ?? 1000)
        case "future-write":
            code = await futureWrite(database, store)
        case "future-read":
            code = await futureRead(database, store)
        case "dump":
            break
        default:
            say("unknown command \(command)")
            return 2
        }
        await report(store, trace: options.trace)
        await save(store, to: file)
        say("done \(command) code=\(code) \(milliseconds(since: start)) ms")
        return code
    }

    struct Options {
        var container: String?
        var timeout: Double
        var textBytes: Int?
        var voice: Bool
        var engineBuilder: Bool
        var ignorePause: Bool
        var cancelTaskAfter: Int?
        var cancelOpsAfter: Int?
        var trace: Bool
        var noExclude: Bool
        var maxBytes: Int?

        init(_ a: [String]) {
            container = LiveRunner.value(after: "-SP4Container", in: a).map {
                $0 == "spike4" ? LiveSync.spikeContainer : $0 == "dev" ? LiveSync.developmentContainer : $0
            }
            timeout = LiveRunner.value(after: "-SP4Timeout", in: a).flatMap(Double.init) ?? 300
            textBytes = LiveRunner.value(after: "-SP4TextBytes", in: a).flatMap(Int.init)
            voice = a.contains("-SP4Voice")
            engineBuilder = LiveRunner.value(after: "-SP4Builder", in: a) == "engine"
            ignorePause = a.contains("-SP4IgnorePause")
            cancelTaskAfter = LiveRunner.value(after: "-SP4CancelTask", in: a).flatMap(Int.init)
            cancelOpsAfter = LiveRunner.value(after: "-SP4CancelOps", in: a).flatMap(Int.init)
            trace = a.contains("-SP4Trace")
            noExclude = a.contains("-SP4NoExclude")
            maxBytes = LiveRunner.value(after: "-SP4MaxBytes", in: a).flatMap(Int.init)
        }
    }

    // MARK: - Through the engine

    static func account(_ target: LiveSync.Target) async -> Int32 {
        let container = CKContainer(identifier: target.container)
        do {
            let status = try await container.accountStatus()
            say("account status=\(status.rawValue) (0 couldNotDetermine, 1 available, 2 restricted, 3 noAccount, 4 temporarilyUnavailable)")
            return 0
        } catch let error as CKError {
            say("account error code=\(error.errorCode)")
            return 1
        } catch {
            say("account error \(type(of: error))")
            return 1
        }
    }

    static func seed(_ store: SpikeStore, notes: Int, segments: Int, textBytes: Int?, voice: Bool) async {
        // Every date is in the past, a second apart per note, as captures would be.
        let start = Date().addingTimeInterval(-Double(notes) - 60)
        await store.write { replica in
            for n in 0..<notes {
                let note = UUID()
                replica.createNote(note, at: start.addingTimeInterval(Double(n)))
                for s in 0..<segments {
                    let base = "Synthetic segment \(s) of note \(n). "
                    let text = textBytes.map { String(repeating: "a", count: max(0, $0 - base.utf8.count)) + base } ?? base
                    replica.append(UUID(), to: note, kind: Tag(voice ? "voice" : "typed"), text: text,
                                   origin: voice ? TextOrigin.rawTranscript : TextOrigin.typed,
                                   startedAt: start.addingTimeInterval(Double(n) + Double(s) / 100))
                }
            }
        }
        say("seed notes=\(notes) segments=\(notes * segments) textBytes=\(textBytes ?? 0) voice=\(voice) pending=\(await store.replica.pending.count)")
    }

    static func engine(_ store: SpikeStore, target: LiveSync.Target, options: Options, automatic: Bool)
        async -> (CKSyncEngine, SyncAdapter) {
        let adapter = SyncAdapter(store: store, generation: await store.generation,
                                  useEngineBuilder: options.engineBuilder, excludeAttachments: !options.noExclude,
                                  maxBytes: options.maxBytes)
        let engine = LiveSync.makeEngine(adapter: adapter, state: await store.savedState, target: target,
                                         automaticallySync: automatic)
        return (engine, adapter)
    }

    static func prepare(_ engine: CKSyncEngine, _ store: SpikeStore, options: Options) async {
        await store.setIgnorePause(options.ignorePause)
        if await !store.zoneSaved, await store.questions.isEmpty {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Zones.stream))])
        }
        let pending = await store.replica.pending
        guard !pending.isEmpty else { return }
        if options.engineBuilder {
            let mapping = RecordMapping()
            engine.state.add(pendingRecordZoneChanges: pending.map { .saveRecord(mapping.recordID($0)) })
        } else {
            engine.state.hasPendingUntrackedChanges = true
        }
    }

    static func sync(_ store: SpikeStore, target: LiveSync.Target, options: Options, deleteZone: Bool) async -> Int32 {
        let (engine, adapter) = await engine(store, target: target, options: options, automatic: false)
        if deleteZone {
            engine.state.add(pendingDatabaseChanges: [.deleteZone(Zones.stream)])
        } else {
            await prepare(engine, store, options: options)
        }
        var failed = false
        for step in deleteZone ? ["send"] : ["fetch", "send", "fetch"] {
            let start = Date()
            let work = Task {
                try await withTimeout(seconds: options.timeout) {
                    if step == "fetch" { try await engine.fetchChanges() } else { try await engine.sendChanges() }
                }
            }
            if step == "send", let ms = options.cancelTaskAfter {
                try? await Task.sleep(for: .milliseconds(ms))
                await store.receive(.trace("--- the task awaiting sendChanges is cancelled"), generation: await store.generation)
                work.cancel()
            }
            if step == "send", let ms = options.cancelOpsAfter {
                try? await Task.sleep(for: .milliseconds(ms))
                await store.receive(.trace("--- cancelOperations called"), generation: await store.generation)
                await engine.cancelOperations()
                await store.receive(.trace("--- cancelOperations returned"), generation: await store.generation)
            }
            switch await work.result {
            case .success:
                say("\(step) ok \(milliseconds(since: start)) ms")
            case .failure(let error as CKError):
                failed = true
                say("\(step) error code=\(error.errorCode) retryAfter=\(error.retryAfterSeconds.map { String($0) } ?? "-") \(milliseconds(since: start)) ms")
            case .failure(is TimedOut):
                failed = true
                say("\(step) timedOut after \(milliseconds(since: start)) ms")
            case .failure(let error):
                failed = true
                say("\(step) error \(type(of: error)) \(milliseconds(since: start)) ms")
            }
            if options.cancelTaskAfter != nil || options.cancelOpsAfter != nil, step == "send" {
                await store.receive(.trace("--- send returned; waiting 5 s for late events"), generation: await store.generation)
                try? await Task.sleep(for: .seconds(5))
                await store.receive(.trace("--- end of wait"), generation: await store.generation)
                break
            }
        }
        say("engine pendingRecordZoneChanges=\(engine.state.pendingRecordZoneChanges.count) pendingDatabaseChanges=\(engine.state.pendingDatabaseChanges.count) untracked=\(engine.state.hasPendingUntrackedChanges)")
        await engine.cancelOperations()
        withExtendedLifetime(adapter) {}
        return failed ? 1 : 0
    }

    static func listen(_ store: SpikeStore, target: LiveSync.Target, options: Options, seconds: Double) async -> Int32 {
        let (engine, adapter) = await engine(store, target: target, options: options, automatic: true)
        await prepare(engine, store, options: options)
        say("listen \(Int(seconds)) s, automatic sync on, Attachments excluded=\(!options.noExclude)")
        try? await Task.sleep(for: .seconds(seconds))
        say("engine zonesWithUnfetchedServerChanges=\(engine.state.zoneIDsWithUnfetchedServerChanges.map(\.zoneName)) untracked=\(engine.state.hasPendingUntrackedChanges)")
        await engine.cancelOperations()
        withExtendedLifetime(adapter) {}
        return 0
    }

    /// Statement 4: how the state grows with changes the engine tracks.
    static func stateTracked(_ store: SpikeStore, target: LiveSync.Target, count: Int) async -> Int32 {
        let (engine, adapter) = await engine(store, target: target, options: Options([]), automatic: false)
        let before = await store.savedState?.count ?? 0
        let fake: [CKSyncEngine.PendingRecordZoneChange] = (0..<count).map { _ in
            .saveRecord(CKRecord.ID(recordName: UUID().uuidString, zoneID: Zones.stream))
        }
        engine.state.add(pendingRecordZoneChanges: fake)
        try? await Task.sleep(for: .seconds(3))
        let with = await store.savedState?.count ?? 0
        engine.state.remove(pendingRecordZoneChanges: fake)
        try? await Task.sleep(for: .seconds(3))
        let after = await store.savedState?.count ?? 0
        say("state-tracked count=\(count) bytesBefore=\(before) bytesWith=\(with) bytesAfterRemoving=\(after) perChange=\(count > 0 ? (with - before) / count : 0)")
        withExtendedLifetime(adapter) {}
        return 0
    }

    // MARK: - Straight to CKDatabase

    static let probeZone = CKRecordZone.ID(zoneName: "Probe", ownerName: CKCurrentUserDefaultName)

    static func direct(_ database: CKDatabase, _ name: String, _ body: () async throws -> Void) async -> Int32 {
        let start = Date()
        do {
            try await body()
            say("\(name) ok \(milliseconds(since: start)) ms")
            return 0
        } catch let error as CKError {
            say("\(name) error code=\(error.errorCode) \(milliseconds(since: start)) ms")
            return 1
        } catch {
            say("\(name) error \(type(of: error))")
            return 1
        }
    }

    /// Saves one record and reports the code; deletes it when saved.
    static func trySave(_ database: CKDatabase, _ record: CKRecord) async -> (ok: Bool, code: Int?) {
        do {
            let (saves, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            if case .failure(let error as CKError) = saves[record.recordID] { return (false, error.errorCode) }
            if case .failure = saves[record.recordID] { return (false, -1) }
            _ = try? await database.modifyRecords(saving: [], deleting: [record.recordID])
            return (true, nil)
        } catch let error as CKError {
            if let partial = error.partialErrorsByItemID?[record.recordID] as? CKError { return (false, partial.errorCode) }
            return (false, error.errorCode)
        } catch {
            return (false, -1)
        }
    }

    static func ensureProbeZone(_ database: CKDatabase) async -> Bool {
        do {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: probeZone)], deleting: [])
            return true
        } catch {
            say("probe zone error \((error as? CKError)?.errorCode ?? -1)")
            return false
        }
    }

    /// Statement 8: the largest string a record takes, plain or encrypted, to 1 KiB.
    static func sizeProbe(_ database: CKDatabase, _ rest: [String]) async -> Int32 {
        guard await ensureProbeZone(database) else { return 1 }
        let encrypted = rest.first == "encrypted"
        var lo = Int(rest.dropFirst().first ?? "") ?? 900_000
        var hi = Int(rest.dropFirst(2).first ?? "") ?? 1_100_000
        func attempt(_ n: Int) async -> Bool {
            let record = CKRecord(recordType: "SizeProbe", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: probeZone))
            let value = String(repeating: "a", count: n)
            if encrypted { record.encryptedValues["secret"] = value } else { record["blob"] = value }
            let start = Date()
            let result = await trySave(database, record)
            say("size-probe \(encrypted ? "encrypted" : "plain") bytes=\(n) \(result.ok ? "saved" : "refused code=\(result.code ?? 0)") \(milliseconds(since: start)) ms")
            return result.ok
        }
        guard await attempt(lo) else { say("size-probe the low bound is refused already"); return 1 }
        guard !(await attempt(hi)) else { say("size-probe the high bound is accepted too"); return 0 }
        while hi - lo > 1024 {
            let mid = (lo + hi) / 2
            if await attempt(mid) { lo = mid } else { hi = mid }
        }
        say("size-probe result \(encrypted ? "encrypted" : "plain") largestSaved=\(lo) smallestRefused=\(hi)")
        return 0
    }

    /// Statement 8: one asset of a given size, random bytes so nothing compresses it.
    static func assetProbe(_ database: CKDatabase, _ bytes: Int) async -> Int32 {
        guard await ensureProbeZone(database) else { return 1 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("probe.bin")
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            var generator = SystemRandomNumberGenerator()
            for i in stride(from: 0, to: raw.count, by: 8) {
                var value = generator.next()
                withUnsafeBytes(of: &value) { v in
                    for j in 0..<min(8, raw.count - i) { raw[i + j] = v[j] }
                }
            }
        }
        try? data.write(to: file)
        let record = CKRecord(recordType: "SizeProbe", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: probeZone))
        record["file"] = CKAsset(fileURL: file)
        let start = Date()
        let result = await trySave(database, record)
        say("asset-probe bytes=\(bytes) \(result.ok ? "saved" : "refused code=\(result.code ?? 0)") \(milliseconds(since: start)) ms")
        try? FileManager.default.removeItem(at: folder)
        return result.ok ? 0 : 1
    }

    /// Before a deploy: the development schema gets a field only when a saved record has a
    /// value for it, so one note and one segment carry every field. They are deleted after.
    static func schemaSeed(_ database: CKDatabase) async -> Int32 {
        let mapping = RecordMapping()
        let now = Date()
        let note = NoteValue(id: UUID(), createdAt: now, title: "Schema", titleOrigin: TitleOrigin.user,
                             titleEditedAt: now, closedAt: now, deletedAt: now)
        let segment = SegmentValue(id: UUID(), noteID: note.id, noteGeneration: 1, kind: Tag("voice"), origin: Tag("device"),
                                   startedAt: now, endedAt: now, text: "Schema", textOrigin: TextOrigin.cleaned,
                                   rawTranscript: "schema", processingOwner: UUID(), ownerGeneration: 1, state: Tag("ready"),
                                   assetID: UUID(), conflictOf: UUID(), deletedAt: now)
        guard let n = try? mapping.record(for: .note(note), systemFields: nil),
              let g = try? mapping.record(for: .segment(segment), systemFields: nil) else { return 1 }
        g[Schema.Segment.assetUpload] = "published"
        return await direct(database, "schema-seed") {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Zones.stream)], deleting: [])
            let (saves, _) = try await database.modifyRecords(saving: [n, g], deleting: [])
            for (_, result) in saves { if case .failure(let error) = result { throw error } }
            say("schema-seed note fields=\(n.allKeys().count) segment fields=\(g.allKeys().count)")
            _ = try await database.modifyRecords(saving: [], deleting: [n.recordID, g.recordID])
        }
    }

    /// Statement 11, first half: a field this build does not know, written to a note.
    static func futureWrite(_ database: CKDatabase, _ store: SpikeStore) async -> Int32 {
        guard let id = await store.replica.notes.keys.sorted(by: { $0.uuidString < $1.uuidString }).first else {
            say("future-write no note"); return 1
        }
        return await direct(database, "future-write") {
            let record = try await database.record(for: RecordMapping().recordID(RecordKey(kind: .note, id: id)))
            record["futureField"] = "from a newer build"
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged)
        }
    }

    /// Statement 11, second half: after another device saved the note without the field.
    static func futureRead(_ database: CKDatabase, _ store: SpikeStore) async -> Int32 {
        guard let id = await store.replica.notes.keys.sorted(by: { $0.uuidString < $1.uuidString }).first else {
            say("future-read no note"); return 1
        }
        do {
            let record = try await database.record(for: RecordMapping().recordID(RecordKey(kind: .note, id: id)))
            let title = record.encryptedValues[Schema.Note.title] as? String
            say("future-read futureFieldKept=\(record["futureField"] != nil) titleEdited=\(title?.hasPrefix("Edited title") ?? false) modifiedBy=\(record.lastModifiedUserRecordID != nil)")
            return 0
        } catch {
            say("future-read error \((error as? CKError)?.errorCode ?? -1)")
            return 1
        }
    }

    /// Statement 5: an asset record in the Attachments zone, put there outside the engine.
    static func attachmentsPut(_ database: CKDatabase) async -> Int32 {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("a.bin")
        try? Data(repeating: 7, count: 4096).write(to: file)
        let asset = UUID()
        let record = RecordMapping().assetRecord(assetID: asset, segmentID: UUID(), kind: "audio", byteCount: 4096,
                                                 sha256: "synthetic", fileURL: file)
        let code = await direct(database, "attachments-put") {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: Zones.attachments)], deleting: [])
            let (saves, _) = try await database.modifyRecords(saving: [record], deleting: [])
            if case .failure(let error) = saves[record.recordID] { throw error }
        }
        if code == 0 { UserDefaults.standard.set(asset.uuidString, forKey: "SP4.lastAsset") }
        try? FileManager.default.removeItem(at: folder)
        return code
    }

    /// The design's on-demand read: metadata without the file, then the file.
    static func assetFetch(_ database: CKDatabase) async -> Int32 {
        guard let name = UserDefaults.standard.string(forKey: "SP4.lastAsset") else { say("asset-fetch nothing put"); return 1 }
        let id = CKRecord.ID(recordName: name, zoneID: Zones.attachments)
        do {
            let meta = try await database.records(for: [id], desiredKeys: Schema.Asset.metadataKeys)
            let m = try meta[id]?.get()
            say("asset-fetch metadataOnly hasFile=\(m?[Schema.Asset.file] != nil) byteCount=\((m?[Schema.Asset.byteCount] as? Int64) ?? -1)")
            let full = try await database.records(for: [id])
            let asset = try full[id]?.get()[Schema.Asset.file] as? CKAsset
            let size = (try? asset?.fileURL.map { try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int }) ?? nil
            say("asset-fetch full hasFile=\(asset != nil) fileBytes=\(size.map { String(describing: $0) } ?? "-")")
            return 0
        } catch {
            say("asset-fetch error \((error as? CKError)?.errorCode ?? -1)")
            return 1
        }
    }

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

    // MARK: - Report

    static func report(_ store: SpikeStore, trace: Bool) async {
        let r = await store.replica
        let live = r.segments.values.map(\.value)
        say("store notes=\(r.notes.count) deletedNotes=\(r.notes.values.filter { $0.deletedAt != nil }.count) segments=\(r.segments.count) pending=\(r.pending.count) synced=\(r.synced.count) waiting=\(r.waiting.count) conflictCopies=\(live.filter { $0.conflictOf != nil }.count)")
        say("digest text=\(digest(live.map { "\($0.id):\($0.text):\($0.rawTranscript ?? "")" })) placement=\(digest(live.map { "\($0.id):\($0.noteID):\($0.noteGeneration)" })) notes=\(digest(r.notes.values.map { "\($0.id):\($0.title ?? ""):\($0.deletedAt.map { "\($0.timeIntervalSince1970)" } ?? "")" }))")
        say("state bytes=\(await store.savedState?.count ?? 0) systemFields=\(await store.systemFields.count) zoneSaved=\(await store.zoneSaved)")
        for (name, n) in await store.counters.sorted(by: { $0.key < $1.key }) { say("count \(name)=\(n)") }
        for line in await store.lines { say("line \(line)") }
        for question in await store.questions { say("question \(question)") }
        if trace { for (i, line) in (await store.trace).enumerated() { say("trace \(i) \(line)") } }
    }

    static func digest(_ items: [String]) -> String {
        SHA256.hash(data: Data(items.sorted().joined(separator: "\n").utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
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
