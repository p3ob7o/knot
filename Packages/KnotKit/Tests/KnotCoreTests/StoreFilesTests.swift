import Foundation
import KnotCore
import KnotTestSupport
import Testing

/// `StoreFiles`: the way into `DurableFile` from `StoreLocations`, which places each path
/// under the root that holds it. On iOS and on the Watch, `Inbox/` and the recording state
/// sit in the app group, and the store in the app's own container (docs/architecture.md §7),
/// so a caller holding one `DurableFile` would be refused on the other root's paths.
@Suite struct StoreFilesTests {
    let app = URL(fileURLWithPath: "/containers/app/Library/Application Support", isDirectory: true)
    let group = URL(fileURLWithPath: "/containers/group", isDirectory: true)
    let capture: CaptureID = id(11)
    let asset: AssetID = id(12)
    /// What `DurableFile` throws for a path outside its root.
    let outsideItsRoot = KnotError.writeFailed.with(.init(posixError: EINVAL))

    /// A power-cut layer on which both containers exist and are synced, as the system leaves them.
    func layerWithContainers() throws -> PowerCutFileLayer {
        let layer = PowerCutFileLayer()
        for path in ["/containers", "/containers/app", "/containers/app/Library", app.path, group.path] {
            try layer.createFolder(URL(fileURLWithPath: path, isDirectory: true))
            try layer.syncFolder(URL(fileURLWithPath: path, isDirectory: true).deletingLastPathComponent())
        }
        return layer
    }

    @Test(arguments: [StoreLocations.Platform.iOS, .watchOS])
    func eachPathIsPlacedUnderTheRootThatHoldsIt(platform: StoreLocations.Platform) throws {
        let locations = try StoreLocations.resolve(
            flavour: .dev, platform: platform, appContainer: app, appGroup: .present(container: group),
            environment: [:])
        #expect(locations.storeRoot != locations.sharedRoot)
        let layer = try layerWithContainers()

        // One DurableFile on the store's root refuses the group's paths: the mistake this
        // entry point exists to rule out.
        #expect(throws: outsideItsRoot) {
            try DurableFile(layer: layer, root: locations.storeRoot).place(
                Data("{}".utf8), at: locations.inboxManifest(capture))
        }

        let files = locations.durableFiles(layer: layer)
        let manifest = Data("{\"format\":1}".utf8)
        let audio = Data("audio".utf8)
        try files.place(manifest, at: locations.inboxManifest(capture))
        try files.place(audio, at: locations.asset(asset, kind: .audio))
        try files.place(manifest, at: locations.recordingManifest(capture))

        // What was placed survives a power cut, under either root.
        layer.cutPower()
        #expect(try layer.read(locations.inboxManifest(capture)) == manifest)
        #expect(try layer.read(locations.asset(asset, kind: .audio)) == audio)
        #expect(try layer.read(locations.recordingManifest(capture)) == manifest)
        #expect(files.root(for: locations.inbox) == locations.sharedRoot)
        #expect(files.root(for: locations.database) == locations.storeRoot)
    }

    @Test func aFileMovedFromTheInboxIntoTheStoreLandsWholeAndLeavesTheInbox() throws {
        let locations = try StoreLocations.resolve(
            flavour: .dev, platform: .iOS, appContainer: app, appGroup: .present(container: group), environment: [:])
        let layer = try layerWithContainers()
        let files = locations.durableFiles(layer: layer)
        let payload = locations.inboxPayload(capture, kind: .voice)
        let stored = locations.asset(asset, kind: .audio)
        try files.place(Data("audio".utf8), at: payload)
        try files.move(payload, to: stored)
        layer.cutPower()
        #expect(try layer.read(stored) == Data("audio".utf8))
        #expect(!layer.exists(payload))
    }

    @Test func aPathUnderNeitherRootIsRefusedAndNothingIsWritten() throws {
        let locations = try StoreLocations.resolve(
            flavour: .dev, platform: .iOS, appContainer: app, appGroup: .present(container: group), environment: [:])
        let layer = try layerWithContainers()
        let files = locations.durableFiles(layer: layer)
        let outside = URL(fileURLWithPath: "/containers/app/Library/Application Support/Knot/captures.sqlite")
        #expect(files.root(for: outside) == nil)
        #expect(throws: outsideItsRoot) { try files.place(Data("x".utf8), at: outside) }
        // A path that only starts with the root's name is not under it.
        let lookalike = URL(fileURLWithPath: "/containers/group/KnotStoreOther/x.json")
        #expect(files.root(for: lookalike) == nil)
        #expect(!layer.exists(outside))
    }

    @Test func aStoreWithOneRootHasOnePlacer() throws {
        let locations = StoreLocations.testing(root: URL(fileURLWithPath: "/work", isDirectory: true))
        let layer = PowerCutFileLayer()
        try layer.createFolder(URL(fileURLWithPath: "/work", isDirectory: true))
        try layer.syncFolder(URL(fileURLWithPath: "/", isDirectory: true))
        let files = locations.durableFiles(layer: layer)
        try files.place(Data("a".utf8), at: locations.inboxManifest(capture))
        try files.place(Data("b".utf8), at: locations.asset(asset, kind: .ink))
        layer.cutPower()
        #expect(try layer.read(locations.inboxManifest(capture)) == Data("a".utf8))
        #expect(try layer.read(locations.asset(asset, kind: .ink)) == Data("b".utf8))
    }
}
