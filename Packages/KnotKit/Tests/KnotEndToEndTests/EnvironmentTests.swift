import Foundation
import KnotAudio
import KnotFakes
import KnotSpeech
import KnotTestSupport
import Testing

@testable import KnotApp
@testable import KnotCore

@Suite("The live environment")
struct EnvironmentTests {
    /// On each platform the list names. The iPhone's composition is this package's code, built
    /// with the iPhone's configuration: what the composition does differently on iOS at compile
    /// time is the watch link's entry point, which leaves the iPhone's `WatchLink` unavailable,
    /// as the Mac's agent entry point leaves the Mac's environment as it is.
    @Test(
        "unavailable-ports-of-live-match-allowed-list", .tags(.named),
        arguments: [StoreLocations.Platform.iOS, .macOS])
    func unavailablePortsMatchTheAllowedList(_ platform: StoreLocations.Platform) {
        let folder = LiveFolder()
        defer { folder.remove() }
        // `.live` as the app composes it, KnotSpeech's transcriber included. Nothing is opened.
        var seams = LiveComposition.Seams.forTests
        seams.transcriber = nil
        let composition = LiveComposition(configuration: folder.configuration(platform: platform), seams: seams)
        #expect(composition.locations != nil)
        let unavailable = UnavailablePorts.of(composition.environment)
        let allowed = UnavailablePorts.allowed(at: UnavailablePorts.comingMilestone, on: platform)
        #expect(
            unavailable.sorted() == allowed.sorted(),
            "unavailable but not allowed: \(unavailable.subtracting(allowed).sorted()); allowed but filled: \(allowed.subtracting(unavailable).sorted())"
        )
        // What M1 needs is there.
        for port: EnvironmentPort in [
            .notes, .assets, .settings, .fetcher, .recorder, .transcriber, .engine, .queue, .gates,
        ] {
            #expect(!unavailable.contains(port), "\(port) is unavailable")
        }
    }

    /// The whole list, level by level on each platform, as the plan's table of milestone builds
    /// gives it: a change to it changes this table too.
    @Test("The allowed list, level by level, on iOS and on the Mac")
    func allowedListByLevel() {
        let always: Set<EnvironmentPort> = [.watchLink]
        let ink: Set<EnvironmentPort> = [.inkRecogniser, .drawingImages]
        let beforeM2: Set<EnvironmentPort> = [
            .player, .recordingState, .freeSpace, .installIdentity, .lifecycle, .recordingActivity,
        ]
        let iOS: [MilestoneLevel: Set<EnvironmentPort>] = [
            .m1: always.union(ink).union(beforeM2).union([.notifier, .sync, .surfaces, .cues]),
            .m2: always.union(ink).union([.notifier, .sync]),
            .m3: always.union(ink).union([.notifier, .sync]),
            .m4: always.union(ink),
            .m5: always, .m6: always, .m7: always,
        ]
        let mac: [MilestoneLevel: Set<EnvironmentPort>] = [
            .m1: always.union(ink).union(beforeM2).union([.notifier, .sync, .surfaces, .cues]),
            .m2: always.union(ink).union([.recordingActivity, .notifier, .sync, .surfaces, .cues]),
            .m3: always.union(ink).union([.recordingActivity, .notifier, .sync, .surfaces, .cues]),
            .m4: always.union(ink).union([.recordingActivity]),
            .m5: always.union([.recordingActivity]), .m6: always.union([.recordingActivity]),
            .m7: always.union([.recordingActivity]),
        ]
        for level in MilestoneLevel.allCases {
            #expect(UnavailablePorts.allowed(at: level, on: .iOS) == iOS[level], "iOS at \(level.infoValue)")
            #expect(UnavailablePorts.allowed(at: level, on: .macOS) == mac[level], "the Mac at \(level.infoValue)")
        }
    }

    @Test(
        "The allowed list only shrinks from one milestone to the next, and holds only the Watch's link and the Mac's Live Activity at M7"
    )
    func allowedListShrinks() {
        for platform: StoreLocations.Platform in [.iOS, .macOS] {
            var previous: Set<EnvironmentPort>?
            for level in MilestoneLevel.allCases {
                let allowed = UnavailablePorts.allowed(at: level, on: platform)
                if let previous { #expect(allowed.isSubset(of: previous), "\(level) on \(platform)") }
                #expect(!allowed.contains(.notes) && !allowed.contains(.engine) && !allowed.contains(.clock))
                previous = allowed
            }
            let last = UnavailablePorts.allowed(at: .m7, on: platform)
            #expect(last == (platform == .macOS ? [.watchLink, .recordingActivity] : [.watchLink]))
        }
    }

    @Test("A port that the unavailable environment holds is reported as unavailable")
    func everyUnavailablePortIsSeen() {
        let all = Set(EnvironmentPort.allCases).subtracting([.clock, .ids])
        #expect(UnavailablePorts.of(.unavailable) == all)
    }

    /// The gates of each level, as the plan lists them: sync and the command line open at M4,
    /// ink at M5. A development build has no level and every gate open.
    @Test("gates-listed-for-each-milestone-level", .tags(.named))
    func gatesForEachLevel() {
        let open: [MilestoneLevel?: Set<Feature>] = [
            nil: [.sync, .commandLine, .ink],
            .m1: [],
            .m2: [],
            .m3: [],
            .m4: [.sync, .commandLine],
            .m5: [.sync, .commandLine, .ink],
            .m6: [.sync, .commandLine, .ink],
            .m7: [.sync, .commandLine, .ink],
        ]
        #expect(open.count == MilestoneLevel.allCases.count + 1)
        let folder = LiveFolder()
        defer { folder.remove() }
        for (level, expected) in open {
            let gates = folder.compose(level: level).environment.gates
            let opened = Set(Feature.allCases.filter { gates.isOpen($0) })
            #expect(opened == expected, "level \(level?.infoValue ?? "none")")
        }
    }

    @Test("A debug development build honours the launch arguments for .preview and a temporary store")
    func launchArguments() {
        #expect(LiveConfiguration.selectsPreview(["Knot", "-KnotPreview"], flavour: .dev))
        #expect(!LiveConfiguration.selectsPreview(["Knot"], flavour: .dev))
        #expect(
            LaunchArguments.read(["Knot", "-KnotTemporaryStore", "smoke-1"], flavour: .dev).temporaryStore
                == .named("smoke-1"))
        #expect(LaunchArguments.read(["Knot"], flavour: .dev).temporaryStore == .none)
        for refused in ["../up", ".hidden", "", "a/b", String(repeating: "x", count: 65), "é", "-KnotPreview"] {
            #expect(
                LaunchArguments.read(["-KnotTemporaryStore", refused], flavour: .dev).temporaryStore == .refused,
                "\(refused)")
        }
        #expect(LaunchArguments.read(["-KnotTemporaryStore"], flavour: .dev).temporaryStore == .refused)
    }

    @Test("A milestone build honours neither launch argument, whatever its configuration")
    func milestoneBuildHonoursNoArgument() {
        let arguments = ["Knot", "-KnotPreview", "-KnotTemporaryStore", "smoke-1"]
        #expect(!LiveConfiguration.selectsPreview(arguments, flavour: .milestone))
        #expect(
            LaunchArguments.read(arguments, flavour: .milestone)
                == LaunchArguments(preview: false, temporaryStore: .none))
        #expect(LaunchArguments.read(["-KnotTemporaryStore", "../up"], flavour: .milestone).temporaryStore == .none)
    }

    /// A temporary store asked for by a name that is refused gets no store place, never the
    /// build's default container, where a UI test would then write.
    @Test("A refused temporary-store name gets no store, and says why")
    func refusedTemporaryStoreGetsNoStore() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        var configuration = folder.configuration()
        configuration.refusal = .devStoreFolderInvalid
        let composition = LiveComposition(configuration: configuration, seams: .forTests)
        #expect(composition.locations == nil)
        let report = try #require(await launch(composition))
        #expect(report.outcome(of: .openStore) == .failed(KnotError.devStoreFolderInvalid.code))
        await #expect(throws: KnotError.devStoreFolderInvalid) {
            try await composition.environment.engine.begin(
                CaptureRequest(kind: .typed, surface: .app, text: "a synthetic line for no store"))
        }
        // Nothing was made in the build's container.
        #expect((try FileManager.default.contentsOfDirectory(atPath: folder.container.path)).isEmpty)
    }

    /// The app a UI test starts through `KnotLauncher` (Apps/UITestSupport) carries the mark
    /// `KNOT_AGENT=1` and nothing else of a test: no test bundle, no runner's variables, no
    /// simulator on the Mac. Such a process refuses the hardware input and a model install.
    @Test("An app launched with the UI test launcher's mark refuses the hardware input and a model install")
    func launcherMarkRefusesHardwareInput() {
        let mark = ["KNOT_AGENT": "1"]
        let launched = HardwareInputPolicy.Process(
            environment: mark, bundlePaths: ["/Applications/Knot Dev.app"], processName: "Knot", isSimulator: false)
        #expect(HardwareInputPolicy.refusal(for: launched) == .agent)
        var unmarked = launched
        unmarked.environment = [:]
        #expect(HardwareInputPolicy.refusal(for: unmarked) == nil)
        let installing = SpeechInstallPolicy.Process(
            environment: mark, bundlePaths: ["/Applications/Knot Dev.app"], processName: "Knot")
        #expect(SpeechInstallPolicy.refusal(for: installing) != nil)
    }

    @Test("An agent's process never opens the milestone store")
    func agentRefusedTheMilestoneStore() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        var configuration = folder.configuration(level: .m1)
        configuration.flavour = .milestone
        let composition = LiveComposition(configuration: configuration, seams: .forTests)
        #expect(composition.locations == nil)
        #expect(composition.locationsError == KnotError.agentRefusedMilestoneStore)
    }
}

@Suite("The diagnostics export")
struct DiagnosticsTests {
    /// A made-up word, which must reach no field of the file.
    static let canary = "quorvantine"

    @Test("The diagnostics file holds capture rows, job rows, counts and timings, and no note text")
    func exportHoldsNoText() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let composition = folder.compose()
        _ = try #require(await launch(composition))
        let state = try await typeLine("a synthetic \(Self.canary) line", in: composition)
        _ = try await composition.environment.engine.end(state.captureID)
        _ = try await composition.environment.notes.search(Self.canary, limit: 10)

        let data = await composition.diagnostics.exportData()
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.lowercased().contains(Self.canary))
        let file = try JSONDecoder.iso8601.decode(DiagnosticsFile.self, from: data)
        #expect(file.store.open)
        #expect(file.store.consistencyProblems.isEmpty)
        #expect(file.captures.map(\.id) == [state.captureID.description])
        #expect(file.captures.first?.outcome == "stored")
        #expect(file.captures.first?.kind == "typed")
        #expect(file.launch?.steps.count == 4)
        #expect(file.timings[MeasuredMoment.typedTextOnDisk.rawValue]?.count ?? 0 >= 1)
        #expect(file.timings[MeasuredMoment.searchResults.rawValue]?.count == 1)
        #expect(file.timings[MeasuredMoment.launchOpenStore.rawValue]?.count == 1)
        let today = file.weekCounts.values.reduce(0) { $0 + ($1["captures_typed"] ?? 0) }
        #expect(today == 1)
        // The content hash of a capture stays out of the file, by its name or its value.
        #expect(!json.contains("contentHash") && !json.contains("content_hash"))
        #expect(!json.contains(folder.container.path))
    }

    @Test("A store that will not open still exports, with its code")
    func exportWithoutAStore() async throws {
        let folder = LiveFolder()
        defer { folder.remove() }
        let composition = folder.compose()
        let file = await composition.diagnostics.export()
        #expect(!file.store.open)
        #expect(file.store.problem == KnotError.storeNotOpen.code)
        #expect(file.captures.isEmpty)
    }

    @Test("The suggested file name is the time alone")
    func fileName() {
        let folder = LiveFolder()
        defer { folder.remove() }
        let name = folder.compose().diagnostics.suggestedFileName(at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(name == "knot-diagnostics-20270115T080000Z.json")
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
