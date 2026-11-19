import Foundation
import KnotCore
import KnotTestSupport
import Testing

@Suite struct StoreLocationsTests {
    let app = URL(fileURLWithPath: "/containers/app/Library/Application Support", isDirectory: true)
    let group = URL(fileURLWithPath: "/containers/group", isDirectory: true)

    @Test("store-locations-missing-group-container", .tags(.named))
    func aMissingGroupContainerIsRefused() {
        for platform in [StoreLocations.Platform.iOS, .macOS] {
            for flavour in [StoreLocations.Flavour.dev, .milestone] {
                #expect(throws: KnotError.groupContainerMissing) {
                    try StoreLocations.resolve(
                        flavour: flavour, platform: platform, appContainer: app, groupContainer: nil, environment: [:])
                }
            }
        }
        // No default path stands in: the watch, which has no group, is the only platform
        // that resolves without one.
        #expect(
            (try? StoreLocations.resolve(
                flavour: .dev, platform: .watchOS, appContainer: app, groupContainer: nil, environment: [:])) != nil)
    }

    @Test func onIOSTheDatabaseStaysInTheAppsOwnContainer() throws {
        let locations = try StoreLocations.resolve(
            flavour: .dev, platform: .iOS, appContainer: app, groupContainer: group, environment: [:])
        #expect(locations.database.path == "/containers/app/Library/Application Support/KnotStore/knot.sqlite")
        #expect(locations.assets.path == "/containers/app/Library/Application Support/KnotStore/Assets")
        #expect(locations.recording.path == "/containers/app/Library/Application Support/KnotStore/Recording")
        #expect(locations.inbox.path == "/containers/group/KnotStore/Inbox")
        #expect(locations.recordingState.path == "/containers/group/KnotStore/RecordingState")
    }

    @Test func onTheMacEverythingIsInTheGroupSoTheToolOpensTheSameStore() throws {
        let milestone = try StoreLocations.resolve(
            flavour: .milestone, platform: .macOS, appContainer: app, groupContainer: group,
            devStoreFolder: "wp-02", environment: [:])
        #expect(milestone.database.path == "/containers/group/KnotStore/knot.sqlite")
        #expect(milestone.inbox.path == "/containers/group/KnotStore/Inbox")

        // A development build's store sits in a folder named for its worktree.
        let dev = try StoreLocations.resolve(
            flavour: .dev, platform: .macOS, appContainer: app, groupContainer: group, devStoreFolder: "wp-02",
            environment: [:])
        #expect(dev.database.path == "/containers/group/wp-02/KnotStore/knot.sqlite")
        for unsafe in ["", "..", "a/b", "."] {
            let plain = try StoreLocations.resolve(
                flavour: .dev, platform: .macOS, appContainer: app, groupContainer: group, devStoreFolder: unsafe,
                environment: [:])
            #expect(plain.database.path == "/containers/group/KnotStore/knot.sqlite")
        }
    }

    @Test func anAgentCannotOpenTheMilestoneStore() throws {
        for platform in [StoreLocations.Platform.iOS, .macOS, .watchOS] {
            #expect(throws: KnotError.agentRefusedMilestoneStore) {
                try StoreLocations.resolve(
                    flavour: .milestone, platform: platform, appContainer: app, groupContainer: group,
                    environment: ["KNOT_AGENT": "1"])
            }
        }
        _ = try StoreLocations.resolve(
            flavour: .dev, platform: .macOS, appContainer: app, groupContainer: group, environment: ["KNOT_AGENT": "1"])
    }

    @Test func everythingV1WritesIsUnderKnotStoreNeverTheRetiredFolder() throws {
        let retired = app.appending(path: "Knot")
        let capture: CaptureID = id(1)
        for platform in [StoreLocations.Platform.iOS, .macOS, .watchOS] {
            let locations = try StoreLocations.resolve(
                flavour: .dev, platform: platform, appContainer: app, groupContainer: group, environment: [:])
            let paths = [
                locations.database, locations.assets, locations.recording, locations.inbox, locations.recordingState,
                locations.outbox, locations.asset(id(2), kind: .audio), locations.inboxManifest(capture),
                locations.inboxPayload(capture, kind: .voice), locations.recordingManifest(capture),
                locations.recordingAudio(capture, fileExtension: "caf"), locations.outboxManifest(capture),
                locations.outboxAudio(capture),
            ]
            for path in paths {
                #expect(path.pathComponents.contains(StoreLocations.rootFolderName), "\(path.path)")
                #expect(!path.path.hasPrefix(retired.path + "/"), "\(path.path)")
            }
        }
    }

    @Test func aPathOnDiskComesFromAnID() {
        let locations = StoreLocations.testing(root: URL(fileURLWithPath: "/tmp/test-store", isDirectory: true))
        let asset = AssetID(uuid: UUID(uuidString: "01234567-89ab-7fff-bfff-ffffffffff3c")!)
        #expect(
            locations.asset(asset, kind: .audio).path
                == "/tmp/test-store/KnotStore/Assets/3c/01234567-89ab-7fff-bfff-ffffffffff3c.m4a")
        #expect(
            locations.asset(asset, kind: .ink).path
                == "/tmp/test-store/KnotStore/Assets/3c/01234567-89ab-7fff-bfff-ffffffffff3c.drawing")
        let capture = CaptureID(asset)
        #expect(locations.inboxManifest(capture).lastPathComponent == "01234567-89ab-7fff-bfff-ffffffffff3c.json")
        #expect(locations.inboxPayload(capture, kind: .typed).lastPathComponent.hasSuffix(".txt"))
    }
}
