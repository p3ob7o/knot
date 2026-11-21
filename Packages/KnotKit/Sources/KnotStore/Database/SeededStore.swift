import Foundation
import GRDB
import KnotCore

/// A seeded synthetic store, made by a build at a milestone tag and committed, so that every
/// later build can open it, migrate it and pass the whole `NoteStore` contract suite on it
/// (docs/architecture.md §7, "Snapshots"). It holds work in flight: an open capture, a queued
/// job and a pending delete, beside finished notes of each kind. Its text is synthetic.
///
/// `KnotStoreCrashHost seed <folder>` makes one. Its manifest, `seeded.json` beside the
/// `KnotStore/` folder, names what a later build checks is still there.
public enum SeededStore {
    /// What a seeded store holds, by ID.
    public struct Manifest: Codable, Hashable, Sendable {
        public var storeID: StoreID
        public var schemaVersion: Int
        public var notes: [NoteID]
        /// The capture left open, by a launch that is not the one that reads it.
        public var openCapture: CaptureID
        /// The queued transcribe job of a stored recording.
        public var queuedJob: JobID
        /// A deleted note that the purge has not removed.
        public var deletedNote: NoteID
    }

    public static let manifestName = "seeded.json"

    /// A clock fixed at one moment, so that a seeded store's dates are the same every time.
    private struct FixedClock: WallClock {
        let date: Date
        func now() -> Date { date }
    }

    /// Makes a seeded store at `locations`, which must hold none yet, and writes its manifest.
    public static func make(at locations: StoreLocations) async throws(KnotError) -> Manifest {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let clock = FixedClock(date: start.addingTimeInterval(3_600))
        let ids = SystemIDGenerator(clock: clock)
        let database = try StoreDatabase.open(locations: locations, role: .app, clock: clock, ids: ids)
        defer { try? database.close() }
        let notes = NoteRepository(database: database)
        let assets = AssetRepository(locations: locations)
        let device = CaptureOrigin(source: .device(database.deviceID), surface: .app)
        let earlier: LaunchID = ids.make()
        func at(_ minute: Double) -> Date { start.addingTimeInterval(minute * 60) }
        func typed(_ text: String, _ from: Double, _ to: Double?, placement: CapturePlacement = .window) -> NewCapture {
            NewCapture(
                id: ids.make(), kind: .typed, origin: device, launchID: earlier, placement: placement,
                startedAt: at(from), endedAt: to.map(at), body: .text(text), revision: 1)
        }

        // A finished note of a typed line and a recording, whose transcribe job waits.
        let first = try await notes.record(typed("Synthetic seeded line about the garden", 0, 0.5))
        let audio = Data("synthetic seeded audio".utf8)
        let recordingID: CaptureID = ids.make()
        let audioID: AssetID = ids.make()
        let stored = try await assets.place(audio, as: audioID, kind: .audio)
        let recording = try await notes.record(
            NewCapture(
                id: recordingID, kind: .voice, origin: device, launchID: earlier, placement: .window,
                startedAt: at(1), endedAt: at(2),
                body: .file(
                    Asset(
                        id: audioID, segmentID: SegmentID(recordingID), kind: .audio, byteCount: stored.byteCount,
                        sha256: stored.sha256), duration: .seconds(60))))
        // A note made by "New note", then deleted and waiting for the purge.
        let deleted = try await notes.record(typed("Synthetic seeded line to delete", 3, 3.2, placement: .newNote))
        _ = try await notes.delete(.note(deleted.noteID))
        // A note from the command line, with a title.
        let tool = try await notes.record(
            NewCapture(
                id: ids.make(), kind: .typed, origin: CaptureOrigin(source: .cli, surface: .commandLine),
                launchID: earlier, placement: .newNote, startedAt: at(30), endedAt: at(30),
                body: .text("Synthetic seeded line from the tool")))
        _ = try await notes.setTitle("Seeded tool", of: tool.noteID, ifRevision: nil)
        // A typed capture left open by a launch that died.
        let open = typed("Synthetic seeded draft", 60, nil)
        _ = try await notes.record(open)

        let manifest = Manifest(
            storeID: database.storeID, schemaVersion: StoreSchema.currentVersion,
            notes: [first.noteID, deleted.noteID, tool.noteID], openCapture: open.id,
            queuedJob: JobID.transcribe(of: recording.segmentIDs[0]), deletedNote: deleted.noteID)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let url = locations.storeRoot.deletingLastPathComponent().appending(path: manifestName)
            try encoder.encode(manifest).write(to: url, options: .atomic)
        } catch {
            throw KnotError.writeFailed
        }
        // The store is committed as one file, its journal folded in.
        do {
            try await database.pool.writeWithoutTransaction { db in _ = try db.checkpoint(.truncate) }
        } catch {
            throw StoreErrors.knotError(error)
        }
        return manifest
    }
}
