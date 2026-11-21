import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import KnotUI
import Testing

/// Settings (docs/product-spec.md §11), the player, and the theme layer.
@MainActor
@Suite struct SettingsAndThemeTests {
    @Test func theRowsFollowTheDevice() async {
        let rig = StoreRig()
        let phone = SettingsViewModel(environment: rig.environment, context: rig.context(), platform: .iPhone)
        await phone.load()
        #expect(phone.isAvailable)
        #expect(phone.rows == [.appendWindow, .cleanup, .englishVariant, .exportAll, .recentlyDeleted, .about])

        let mac = SettingsViewModel(
            environment: rig.environment, context: rig.context(sync: .available(signedInToICloud: true)),
            platform: .mac)
        await mac.load()
        #expect(
            mac.rows == [
                .appendWindow, .cleanup, .englishVariant, .sync, .hotkey, .launchAtLogin, .commandLineAccess,
                .exportAll, .recentlyDeleted, .about,
            ])
        #expect(mac.hotkeyText == "Not chosen")
    }

    @Test func aChangeIsSavedWhole() async throws {
        let rig = StoreRig()
        let model = SettingsViewModel(environment: rig.environment, context: rig.context(), platform: .iPhone)
        await model.load()
        await model.setAppendWindow(minutes: 0)
        #expect(model.appendWindowText == "Off: every capture is its own note")
        await model.setCleanupEnabled(false)
        await model.setEnglishVariant(.locale("en_GB"))
        let saved = try await rig.settings.load()
        #expect(saved.appendWindow == .off)
        #expect(saved.cleanupEnabled == false)
        #expect(saved.englishVariant == .locale("en_GB"))
        // Mac rows do nothing on a phone, and sync waits for a build that can sync.
        await model.setCommandLineAccess(true)
        await model.setSyncEnabled(true)
        #expect(try await rig.settings.load().commandLineAccess == false)
        #expect(try await rig.settings.load().syncEnabled == nil)
    }

    @Test func aFailedSaveLeavesTheSettingsAsTheyWere() async throws {
        let rig = StoreRig()
        let model = SettingsViewModel(environment: rig.environment, context: rig.context(), platform: .mac)
        await model.load()
        rig.settings.failNextSaves(with: KnotError.writeFailed)
        await model.setLaunchAtLogin(true)
        #expect(model.saveProblem == KnotError.writeFailed.code)
        #expect(model.settings.launchAtLogin == false)
        await model.setLaunchAtLogin(true)
        #expect(model.saveProblem == nil)
        #expect(model.settings.launchAtLogin == true)
    }

    @Test func unreadableSettingsShowTheDefaultsAndChangeNothing() async {
        var environment = AppEnvironment.unavailable
        environment.settings = UnavailableSettingsStore()
        let model = SettingsViewModel(
            environment: environment, context: UIContext(thisDevice: environment.ids.make(), sync: .notInThisBuild),
            platform: .iPad)
        await model.load()
        #expect(!model.isAvailable)
        #expect(model.settings == .defaults)
        await model.setAppendWindow(minutes: 10)
        #expect(model.settings.appendWindow == .default)
    }

    @Test func cleanupSaysWhyItCannotRun() async {
        let rig = StoreRig()
        let cleaner = ScriptedCleaner(availability: .unavailable(.appleIntelligenceOff))
        var environment = rig.environment
        environment.cleaner = cleaner
        let model = SettingsViewModel(environment: environment, context: rig.context(), platform: .iPhone)
        await model.load()
        #expect(model.cleanupNote == "Turn on Apple Intelligence to clean up transcripts.")
        cleaner.setAvailability(.available)
        await model.load()
        #expect(model.cleanupNote == nil)
    }

    @Test func withLiveActivitiesOffSettingsSaysTheLockScreenOpensKnot() async {
        let rig = StoreRig()
        let off = SettingsViewModel(
            environment: rig.environment, context: rig.context(), platform: .iPhone, liveActivitiesEnabled: false)
        #expect(off.lockScreenNote?.contains("opens Knot") == true)
        let on = SettingsViewModel(
            environment: rig.environment, context: rig.context(), platform: .iPhone, liveActivitiesEnabled: true)
        #expect(on.lockScreenNote == nil)
        let mac = SettingsViewModel(
            environment: rig.environment, context: rig.context(), platform: .mac, liveActivitiesEnabled: false)
        #expect(mac.lockScreenNote == nil)
    }

    @Test func thePlayerPlaysAndPauses() async throws {
        let player = FakeAudioPlayer()
        let file = URL(filePath: "/synthetic/recording.m4a")
        player.script(file, length: .seconds(42))
        let model = PlayerViewModel(player: player)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        await model.toggle(file)
        #expect(await eventually("the player to play") { model.isPlaying })
        await model.toggle(file)
        #expect(await eventually("the player to pause") { !model.isPlaying })
        #expect(model.position.of == .seconds(42))
    }

    @Test func reduceMotionTurnsEveryAnimationOff() {
        for kind in MotionKind.allCases {
            #expect(Theme.placeholder.motion.animation(for: kind, reduceMotion: true) == nil)
            #expect(Theme.placeholder.motion.animation(for: kind, reduceMotion: false) != nil)
        }
    }

    @Test func clockTextReadsAsMinutesAndSeconds() {
        #expect(ClockText.of(.seconds(42)) == "0:42")
        #expect(ClockText.of(.seconds(725)) == "12:05")
        #expect(ClockText.of(.seconds(3723)) == "1:02:03")
    }

    @Test func liveEntryPointIsDeclared() {
        #expect(String(reflecting: KnotUILive.self) == "KnotUI.KnotUILive")
    }
}
