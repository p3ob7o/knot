import Foundation
import GRDB
import Testing

@testable import KnotApp
@testable import KnotCore
@testable import KnotStore

@Suite("Raw store export")
struct StoreExportTests {
    private let manager = FileManager.default

    @Test("An open store exports a checked SQLite snapshot and keeps accepting captures")
    func openStore() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let composition = folder.compose()
        _ = try #require(await launch(composition))
        let ports = try composition.gate.ports()
        defer { try? ports.opened.database.close() }
        let typed = try await RestoreTests.typeAndEnd("A synthetic export note", in: composition)
        let ids = SystemIDGenerator()
        let voice: CaptureID = ids.make()
        let assetID = AssetID(voice)
        let bytes = Data([7, 8, 9])
        let placed = try await composition.environment.assets.place(bytes, as: assetID, kind: .audio)
        let asset = Asset(
            id: assetID, segmentID: SegmentID(voice), kind: .audio, byteCount: placed.byteCount, sha256: placed.sha256)
        let now = Date()
        _ = try await composition.environment.notes.record(
            NewCapture(
                id: voice, kind: .voice, origin: CaptureOrigin(source: .device(composition.deviceID), surface: .app),
                launchID: ids.make(), placement: .window, startedAt: now, endedAt: now,
                body: .file(asset, duration: .seconds(1)), revision: 1))
        try Data([0]).write(to: folder.locations.storeRoot.appending(path: ".knot.sqlite.test.partial"))

        let report = try await composition.exportStore(into: folder.container)
        #expect(report.usedDatabaseBackup)
        let names = try manager.contentsOfDirectory(atPath: report.folder.path)
        #expect(names.contains("knot.sqlite"))
        #expect(!names.contains { $0.hasPrefix("knot.sqlite-") || $0.hasPrefix(".knot.sqlite") })

        // Give the export the usual store layout so StoreDatabase can open it.
        let reopenedRoot = folder.container.appending(path: "reopened", directoryHint: .isDirectory)
        try manager.createDirectory(at: reopenedRoot, withIntermediateDirectories: false)
        let exported = StoreLocations.testing(root: reopenedRoot)
        try manager.moveItem(at: report.folder, to: exported.storeRoot)
        var readonly = Configuration()
        readonly.readonly = true
        let queue = try DatabaseQueue(path: exported.database.path, configuration: readonly)
        #expect(try await queue.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") } == "delete")
        try queue.close()

        let database = try StoreDatabase.open(locations: exported, role: .app)
        defer { try? database.close() }
        let notes = NoteRepository(database: database)
        let segment = try #require(await notes.segment(SegmentID(typed.captureID)))
        #expect(segment.text == "A synthetic export note.")
        #expect(try await notes.asset(assetID)?.sha256 == placed.sha256)

        let assetFile = exported.asset(assetID, kind: .audio)
        #expect(try Data(contentsOf: assetFile) == bytes)
        let claim = assetFile.deletingLastPathComponent().appending(path: ".\(assetID).claim")
        #expect(try manager.destinationOfSymbolicLink(atPath: claim.path) == assetFile.lastPathComponent)
        try await RestoreTests.typeAndEnd("A second synthetic note", in: composition)
        #expect(try await streamTexts(composition).contains("A second synthetic note."))
    }

    @Test("A damaged store exports its database, journals and inbox byte for byte")
    func damagedStore() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let locations = folder.locations
        try manager.createDirectory(at: locations.inbox, withIntermediateDirectories: true)
        let files: [String: Data] = [
            "knot.sqlite": Data([1, 2, 3]),
            "knot.sqlite-wal": Data([4, 5, 6]),
            "knot.sqlite-shm": Data([7, 8, 9]),
            "knot.sqlite-journal": Data([10]),
            ".knot.sqlite.test.partial": Data([11]),
            "Inbox/synthetic.txt": Data("A pending synthetic capture".utf8),
        ]
        for (name, bytes) in files {
            try bytes.write(to: locations.storeRoot.appending(path: name))
        }
        let composition = folder.compose()
        _ = try #require(await launch(composition))
        #expect(throws: KnotError.storeDamaged) { try composition.gate.ports() }

        let report = try await composition.exportStore(into: folder.container)
        #expect(!report.usedDatabaseBackup)
        for (name, bytes) in files {
            #expect(try Data(contentsOf: report.folder.appending(path: name)) == bytes)
            #expect(try Data(contentsOf: locations.storeRoot.appending(path: name)) == bytes)
        }
    }

    @Test("A database from a newer build is exported without opening it")
    func newerStore() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let locations = folder.locations
        try manager.createDirectory(at: locations.storeRoot, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: locations.database.path)
        try await queue.write { db in
            try db.execute(sql: "PRAGMA application_id = \(StoreSchema.applicationID)")
            try db.execute(sql: "PRAGMA user_version = 999")
            try db.execute(sql: "CREATE TABLE synthetic_fixture (value TEXT)")
        }
        try queue.close()
        let before = try Data(contentsOf: locations.database)

        let composition = folder.compose()
        _ = try #require(await launch(composition))
        #expect(throws: KnotError.storeNewerThanBuild) { try composition.gate.ports() }
        let report = try await composition.exportStore(into: folder.container)
        #expect(!report.usedDatabaseBackup)
        #expect(try Data(contentsOf: report.folder.appending(path: "knot.sqlite")) == before)
        #expect(try Data(contentsOf: locations.database) == before)
        #expect(try manager.contentsOfDirectory(atPath: locations.storeRoot.path) == ["knot.sqlite"])
    }

    @Test("A split app group inbox is included before launch", arguments: [false, true])
    func sharedInbox(hasLocalInbox: Bool) async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        var configuration = folder.configuration(platform: .iOS)
        configuration.appGroup = .present(container: folder.container.appending(path: "group"))
        let composition = LiveComposition(configuration: configuration, seams: .forTests)
        let locations = try #require(composition.locations)
        let bytes = Data("Synthetic group capture".utf8)
        try manager.createDirectory(at: locations.inbox, withIntermediateDirectories: true)
        try bytes.write(to: locations.inbox.appending(path: "pending.txt"))
        let localInbox = locations.storeRoot.appending(path: "Inbox", directoryHint: .isDirectory)
        if hasLocalInbox {
            try manager.createDirectory(at: localInbox, withIntermediateDirectories: true)
            try Data([1]).write(to: localInbox.appending(path: "local.txt"))
        }

        let report = try await composition.exportStore(into: folder.container)
        #expect(!report.usedDatabaseBackup)
        #expect(throws: KnotError.storeNotOpen) { try composition.gate.ports() }
        let groupExport = hasLocalInbox ? "SharedInbox/pending.txt" : "Inbox/pending.txt"
        #expect(try Data(contentsOf: report.folder.appending(path: groupExport)) == bytes)
        if hasLocalInbox {
            #expect(try Data(contentsOf: report.folder.appending(path: "Inbox/local.txt")) == Data([1]))
        }
    }

    @Test("Export reports a configuration refusal")
    func refusedLocations() async {
        let folder = LiveFolder()
        defer { folder.remove() }
        var configuration = folder.configuration()
        configuration.refusal = .devStoreFolderInvalid
        let composition = LiveComposition(configuration: configuration, seams: .forTests)
        await #expect(throws: KnotError.devStoreFolderInvalid) {
            try await composition.exportStore(into: folder.container)
        }
    }

    @Test("Exports made at the same UTC time get unique folders")
    func namingAndCollision() throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let locations = folder.locations
        try manager.createDirectory(at: locations.storeRoot, withIntermediateDirectories: true)
        let source = locations.storeRoot.appending(path: "synthetic.txt")
        try Data([1]).write(to: source)
        let date = Date(timeIntervalSince1970: 1_234_567_890)
        let name = "knot-store-20090213T233130Z"
        #expect(LiveComposition.suggestedStoreExportFolderName(at: date) == name)

        let first = try StoreExport.write(into: folder.container, locations: locations, phase: .opening, at: date)
        try Data([2]).write(to: source)
        let second = try StoreExport.write(into: folder.container, locations: locations, phase: .opening, at: date)
        #expect(first.folder.lastPathComponent == name)
        #expect(second.folder.lastPathComponent == name + "-2")
        #expect(try Data(contentsOf: first.folder.appending(path: "synthetic.txt")) == Data([1]))
        #expect(try Data(contentsOf: second.folder.appending(path: "synthetic.txt")) == Data([2]))
    }
}
