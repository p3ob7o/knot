import Foundation
import KnotCore
import Synchronization
import Testing

@Suite struct SettingsTests {
    @Test func theDefaults() {
        let settings = Settings.defaults
        #expect(settings.appendWindow.minutes == 5)
        #expect(settings.cleanupEnabled)
        #expect(settings.englishVariant == .followRegion)
        #expect(settings.syncEnabled == nil)
        #expect(settings.hotkey == nil)
        #expect(!settings.launchAtLogin)
        #expect(!settings.commandLineAccess, "Command-line access is off by default.")
    }

    @Test func whichSettingsSync() {
        let synced = SettingKey.allCases.filter { $0.scope == .synced }
        #expect(synced == [.appendWindow, .cleanupEnabled, .englishVariant])
        #expect(SettingKey.allCases.count == 7)
    }

    @Test func theAppendWindowIsBounded() throws {
        #expect(try AppendWindow(minutes: 0).isOff)
        #expect(try AppendWindow(minutes: 1440).minutes == 1440)
        #expect(throws: KnotError.appendWindowInvalid) { try AppendWindow(minutes: -1) }
        #expect(throws: KnotError.appendWindowInvalid) { try AppendWindow(minutes: 1441) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(AppendWindow.self, from: Data("-3".utf8)) }
        #expect(try JSONDecoder().decode(AppendWindow.self, from: Data("7".utf8)).minutes == 7)
    }

    @Test func settingsRoundTripThroughJSON() throws {
        let hotkey = try Hotkey(
            keyCode: 49, modifiers: [.option, .command], isFunctionKey: false, takenByAnotherApp: false)
        let settings = Settings(
            appendWindow: try AppendWindow(minutes: 10), cleanupEnabled: false, englishVariant: .locale("en_GB"),
            syncEnabled: true, hotkey: hotkey, launchAtLogin: true, commandLineAccess: true)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(Settings.self, from: data) == settings)
    }

    @Test(arguments: [
        (EnglishVariant.followRegion, String?.some("GB"), "en_GB"),
        (.followRegion, "AU", "en_AU"),
        (.followRegion, "IT", "en_US"),
        (.followRegion, nil, "en_US"),
        (.locale("en_IN"), "GB", "en_IN"),
        (.locale("en_ZZ"), "GB", "en_US"),
        (.unknown("en-latest"), "GB", "en_US"),
    ])
    func theEnglishVariantFollowsTheRegionAndFallsBackToUSEnglish(
        variant: EnglishVariant, region: String?, expected: String
    ) {
        #expect(variant.resolve(region: region, supported: ["en_US", "en_GB", "en_AU", "en_IN"]) == expected)
    }

    @Test func englishVariantTextForms() {
        #expect(EnglishVariant(rawValue: "follow_region") == .followRegion)
        #expect(EnglishVariant(rawValue: "en_GB") == .locale("en_GB"))
        #expect(EnglishVariant(rawValue: "fr_FR") == .unknown("fr_FR"))
    }

    @Test func aHotkeyNeedsAModifierOrAFunctionKeyAndAFreeKey() throws {
        _ = try Hotkey(keyCode: 49, modifiers: [.command], isFunctionKey: false, takenByAnotherApp: false)
        _ = try Hotkey(keyCode: 122, modifiers: [], isFunctionKey: true, takenByAnotherApp: false)
        #expect(throws: KnotError.hotkeyInvalid) {
            try Hotkey(keyCode: 49, modifiers: [], isFunctionKey: false, takenByAnotherApp: false)
        }
        #expect(throws: KnotError.hotkeyTaken) {
            try Hotkey(keyCode: 49, modifiers: [.command], isFunctionKey: false, takenByAnotherApp: true)
        }
    }

    @Test func syncIsOnByDefaultWhenSignedInAndTheGateIsOpen() {
        let open = MilestoneGates(level: nil)
        let m3 = MilestoneGates(level: .m3)
        #expect(Settings.defaults.syncIsOn(signedInToICloud: true, gates: open, syncAvailable: true))
        #expect(!Settings.defaults.syncIsOn(signedInToICloud: false, gates: open, syncAvailable: true))
        #expect(!Settings.defaults.syncIsOn(signedInToICloud: true, gates: m3, syncAvailable: true))
        #expect(!Settings.defaults.syncIsOn(signedInToICloud: true, gates: open, syncAvailable: false))
        var off = Settings.defaults
        off.syncEnabled = false
        #expect(!off.syncIsOn(signedInToICloud: true, gates: open, syncAvailable: true))
    }
}

@Suite struct FeatureGateTests {
    @Test func theGatesOfEachLevel() {
        let open: [MilestoneLevel?: Set<Feature>] = [
            nil: [.sync, .commandLine, .ink],
            .m1: [], .m2: [], .m3: [],
            .m4: [.sync, .commandLine],
            .m5: [.sync, .commandLine, .ink], .m6: [.sync, .commandLine, .ink], .m7: [.sync, .commandLine, .ink],
        ]
        for (level, features) in open {
            let gates = MilestoneGates(level: level)
            for feature in Feature.allCases {
                #expect(gates.isOpen(feature) == features.contains(feature), "\(String(describing: level)) \(feature)")
            }
        }
    }

    @Test(arguments: [
        ("M1", MilestoneLevel?.some(.m1)), ("M7", .m7), ("none", nil), ("M8", nil), ("m4", nil), ("", nil),
    ])
    func theInfoPlistValue(value: String, level: MilestoneLevel?) {
        #expect(MilestoneGates(infoValue: value).level == level)
    }
}
