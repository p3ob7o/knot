import Foundation
import KnotCore
import KnotTestSupport
import Testing

@Suite struct StoreLocationsTests {
    let app = URL(fileURLWithPath: "/containers/app/Library/Application Support", isDirectory: true)
    let group = URL(fileURLWithPath: "/containers/group", isDirectory: true)

    @Test("store-locations-missing-group-container", .tags(.named))
    func aMissingGroupContainerIsRefused() {
        // No default path stands in, on any platform: the Watch has a group too.
        for platform in [StoreLocations.Platform.iOS, .macOS, .watchOS] {
            for flavour in [StoreLocations.Flavour.dev, .milestone] {
                #expect(throws: KnotError.groupContainerMissing) {
                    try StoreLocations.resolve(
                        flavour: flavour, platform: platform, appContainer: app, appGroup: .present(container: nil),
                        devStoreFolder: "wp-02", environment: [:])
                }
            }
        }
    }

    @Test func onTheWatchTheRecordingStateIsInTheGroupAndTheOutboxIsNot() throws {
        let locations = try StoreLocations.resolve(
            flavour: .dev, platform: .watchOS, appContainer: app, appGroup: .present(container: group), environment: [:]
        )
        #expect(locations.recordingState.path == "/containers/group/KnotStore/RecordingState")
        #expect(locations.outbox.path == "/containers/app/Library/Application Support/KnotStore/Outbox")
        #expect(locations.recording.path == "/containers/app/Library/Application Support/KnotStore/Recording")
    }

    @Test func onIOSTheDatabaseStaysInTheAppsOwnContainer() throws {
        let locations = try StoreLocations.resolve(
            flavour: .dev, platform: .iOS, appContainer: app, appGroup: .present(container: group), environment: [:])
        #expect(locations.database.path == "/containers/app/Library/Application Support/KnotStore/knot.sqlite")
        #expect(locations.assets.path == "/containers/app/Library/Application Support/KnotStore/Assets")
        #expect(locations.recording.path == "/containers/app/Library/Application Support/KnotStore/Recording")
        #expect(locations.inbox.path == "/containers/group/KnotStore/Inbox")
        #expect(locations.recordingState.path == "/containers/group/KnotStore/RecordingState")
    }

    @Test func onTheMacEverythingIsInTheGroupSoTheToolOpensTheSameStore() throws {
        let milestone = try StoreLocations.resolve(
            flavour: .milestone, platform: .macOS, appContainer: app, appGroup: .present(container: group),
            devStoreFolder: "wp-02", environment: [:])
        #expect(milestone.database.path == "/containers/group/KnotStore/knot.sqlite")
        #expect(milestone.inbox.path == "/containers/group/KnotStore/Inbox")

        // A development build's store sits in a folder named for its worktree.
        let dev = try StoreLocations.resolve(
            flavour: .dev, platform: .macOS, appContainer: app, appGroup: .present(container: group),
            devStoreFolder: "wp-02",
            environment: [:])
        #expect(dev.database.path == "/containers/group/wp-02/KnotStore/knot.sqlite")
    }

    @Test func aMacDevelopmentBuildWithNoWorktreeFolderIsRefused() {
        // Development builds from two worktrees never share a store (docs/architecture.md §7),
        // so there is no shared fallback.
        #expect(throws: KnotError.devStoreFolderInvalid) {
            try StoreLocations.resolve(
                flavour: .dev, platform: .macOS, appContainer: app, appGroup: .present(container: group),
                environment: [:])
        }
    }

    @Test func anAgentCannotOpenTheMilestoneStore() throws {
        for platform in [StoreLocations.Platform.iOS, .macOS, .watchOS] {
            #expect(throws: KnotError.agentRefusedMilestoneStore) {
                try StoreLocations.resolve(
                    flavour: .milestone, platform: platform, appContainer: app, appGroup: .present(container: group),
                    environment: ["KNOT_AGENT": "1"])
            }
        }
        _ = try StoreLocations.resolve(
            flavour: .dev, platform: .macOS, appContainer: app, appGroup: .present(container: group),
            devStoreFolder: "wp-02",
            environment: ["KNOT_AGENT": "1"])
    }

    @Test func everythingV1WritesIsUnderKnotStoreNeverTheRetiredFolder() throws {
        let retired = app.appending(path: "Knot")
        let capture: CaptureID = id(1)
        for platform in [StoreLocations.Platform.iOS, .macOS, .watchOS] {
            let locations = try StoreLocations.resolve(
                flavour: .dev, platform: platform, appContainer: app, appGroup: .present(container: group),
                devStoreFolder: "wp-02",
                environment: [:])
            let paths = [
                locations.database, locations.assets, locations.recording, locations.inbox, locations.recordingState,
                locations.outbox, locations.asset(id(2), kind: .audio), locations.inboxManifest(capture),
                locations.inboxPayload(capture, kind: .voice), locations.recordingManifest(capture),
                locations.recordingAudio(capture, format: .caf), locations.outboxManifest(capture),
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

@Suite struct StorePathContainmentTests {
    let root = URL(fileURLWithPath: "/tmp/contained", isDirectory: true)

    func isInside(_ url: URL, _ folder: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    @Test func aRecordingStaysInItsFolder() {
        let locations = StoreLocations.testing(root: root)
        for format in RecordingFormat.allCases {
            let url = locations.recordingAudio(id(1), format: format)
            #expect(isInside(url, locations.recording), "\(url.standardizedFileURL.path)")
            #expect(url.lastPathComponent == "\(CaptureID(id(1) as CaptureID)).\(format.fileExtension)")
        }
    }

    @Test(arguments: [
        ("..", false), ("../x", false), ("a/b", false), (".", false), (".hidden", false), ("a\u{0}b", false),
        ("wt name", false), ("é", false), ("", false), (String(repeating: "w", count: 129), false),
        ("wp-02-domain-f78f835066dc3556", true), ("-ok_1.2", true),
    ])
    func aWorktreeFolderNameNeverLeavesTheGroup(name: String, used: Bool) throws {
        let group = URL(fileURLWithPath: "/containers/group", isDirectory: true)
        let resolve = {
            try StoreLocations.resolve(
                flavour: .dev, platform: .macOS, appContainer: root, appGroup: .present(container: group),
                devStoreFolder: name,
                environment: [:])
        }
        if used {
            #expect(try resolve().storeRoot.standardizedFileURL.path == "/containers/group/\(name)/KnotStore")
        } else {
            #expect(throws: KnotError.devStoreFolderInvalid) { try resolve() }
        }
    }

    @Test func everyPathOfAStoreStaysUnderItsRoot() {
        let locations = StoreLocations.testing(root: root)
        let capture: CaptureID = id(2)
        let paths = [
            locations.asset(id(3), kind: .unknown("../../x")), locations.inboxPayload(capture, kind: .unknown("../x")),
            locations.inboxManifest(capture), locations.recordingManifest(capture), locations.outboxAudio(capture),
            locations.outboxManifest(capture),
        ]
        for path in paths { #expect(isInside(path, locations.storeRoot), "\(path.standardizedFileURL.path)") }
    }
}

/// A build made with the local signing configuration has no app group: every agent build,
/// simulator build and gate build. The caller says so, and StoreLocations roots what would
/// sit in the group in the app's own container (the orchestrator's ruling on §7).
@Suite struct StoreLocationsWithoutAppGroupTests {
    let app = URL(fileURLWithPath: "/containers/app/Library/Application Support", isDirectory: true)

    @Test func onIOSInboxAndTheRecordingStateStayInTheAppsContainer() throws {
        let locations = try StoreLocations.resolve(
            flavour: .dev, platform: .iOS, appContainer: app, appGroup: .absent, environment: [:])
        #expect(!locations.hasAppGroup)
        #expect(locations.database.path == "/containers/app/Library/Application Support/KnotStore/knot.sqlite")
        #expect(locations.inbox.path == "/containers/app/Library/Application Support/KnotStore/Inbox")
        #expect(locations.recordingState.path == "/containers/app/Library/Application Support/KnotStore/RecordingState")
    }

    @Test func onTheWatchTheRecordingStateStaysInTheAppsContainer() throws {
        let locations = try StoreLocations.resolve(
            flavour: .dev, platform: .watchOS, appContainer: app, appGroup: .absent, environment: [:])
        #expect(!locations.hasAppGroup)
        #expect(locations.recordingState.path == "/containers/app/Library/Application Support/KnotStore/RecordingState")
        #expect(locations.outbox.path == "/containers/app/Library/Application Support/KnotStore/Outbox")
    }

    @Test func onTheMacTheDatabaseStaysInTheAppsContainerInTheWorktreesFolder() throws {
        let locations = try StoreLocations.resolve(
            flavour: .dev, platform: .macOS, appContainer: app, appGroup: .absent, devStoreFolder: "wp-02",
            environment: [:])
        #expect(!locations.hasAppGroup)
        #expect(locations.database.path == "/containers/app/Library/Application Support/wp-02/KnotStore/knot.sqlite")
        #expect(locations.inbox.path == "/containers/app/Library/Application Support/wp-02/KnotStore/Inbox")
        #expect(throws: KnotError.devStoreFolderInvalid) {
            try StoreLocations.resolve(
                flavour: .dev, platform: .macOS, appContainer: app, appGroup: .absent, environment: [:])
        }
    }

    @Test func aBuildThatHasAGroupSaysSo() throws {
        let group = URL(fileURLWithPath: "/containers/group", isDirectory: true)
        let locations = try StoreLocations.resolve(
            flavour: .dev, platform: .iOS, appContainer: app, appGroup: .present(container: group), environment: [:])
        #expect(locations.hasAppGroup)
        #expect(StoreLocations.testing(root: app).hasAppGroup == false)
    }
}
