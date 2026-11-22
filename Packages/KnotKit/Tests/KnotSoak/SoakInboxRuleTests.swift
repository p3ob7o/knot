#if os(macOS)
    import Foundation
    import KnotCore
    import KnotTestSupport
    import Testing

    @testable import KnotSoakChild

    /// The soak's rule for what `Inbox/` holds once the last launch has recovered
    /// (`InboxEntries`, `SoakRules.inboxPartialsAreRed`), on a store folder with real entries.
    @Suite struct SoakInboxRuleTests {
        private func inbox(_ names: [String]) throws -> (StoreLocations, URL) {
            let folder = SoakFolders.make("inbox-rule")
            let locations = StoreLocations.testing(root: folder)
            try FileManager.default.createDirectory(at: locations.inbox, withIntermediateDirectories: true)
            for name in names {
                try Data("{}".utf8).write(to: locations.inbox.appending(path: name, directoryHint: .notDirectory))
            }
            return (locations, folder)
        }

        private let capture = CaptureID(uuid: UUID())

        /// The temporary `DurableFile` writes beside an item's manifest, cut before its rename.
        private func partial(_ locations: StoreLocations) -> String {
            ".\(locations.inboxManifest(capture).lastPathComponent).\(UUID().uuidString.lowercased())"
                + DurableFile.partialSuffix
        }

        @Test func onePartialIsCountedAndIsRedOnceTheSwitchIsOn() throws {
            let (empty, emptyFolder) = try inbox([])
            SoakFolders.remove(emptyFolder)
            let name = partial(empty)
            let (locations, folder) = try inbox([name])
            defer { SoakFolders.remove(folder) }
            let entries = try #require(InboxEntries.list(locations))
            #expect(entries.partials == [name])
            #expect(entries.others == 0)
            // Seen after a kill, as the launch's report saw it.
            #expect(SoakWitness.inboxProblems(entries, known: [name], red: false).isEmpty)
            #expect(SoakRules.inboxPartialsAreRed, "WP-15 turned it, with the fix.")
            // The same store is red once the switch is on.
            #expect(SoakWitness.inboxProblems(entries, known: [name], red: true).map(\.code) == ["inbox_partials_left"])
            // And a partial no kill accounts for is red either way.
            for red in [false, true] {
                #expect(
                    SoakWitness.inboxProblems(entries, known: [], red: red).map(\.code).contains(
                        "inbox_partials_beyond_kills"))
            }
        }

        @Test func aDotNamedFileThatIsNoPartialIsRedEitherWay() throws {
            let (probe, probeFolder) = try inbox([])
            SoakFolders.remove(probeFolder)
            let hidden = "." + probe.inboxPayload(capture, kind: .typed).lastPathComponent
            let wrongSuffix = ".\(probe.inboxManifest(capture).lastPathComponent).\(UUID().uuidString.lowercased()).tmp"
            let notAnItemFile = ".notes.\(UUID().uuidString.lowercased())" + DurableFile.partialSuffix
            for name in [hidden, wrongSuffix, notAnItemFile] {
                let (locations, folder) = try inbox([name])
                defer { SoakFolders.remove(folder) }
                let entries = try #require(InboxEntries.list(locations))
                #expect(entries.partials.isEmpty, "\(name.count) bytes")
                for red in [false, true] {
                    #expect(
                        SoakWitness.inboxProblems(entries, known: [], red: red).map(\.code) == ["inbox_items_left"])
                }
            }
        }

        /// The same rule for `Recording/`: the temporary of a peaks file's atomic creation, cut by a
        /// kill, is counted and passes while its switch is off; a name like it that is not one is an
        /// entry like any other.
        @Test func aPeaksTemporaryIsCountedAndPassesWhileTheSwitchIsOff() throws {
            let folder = SoakFolders.make("recording-rule")
            defer { SoakFolders.remove(folder) }
            let locations = StoreLocations.testing(root: folder)
            try FileManager.default.createDirectory(at: locations.recording, withIntermediateDirectories: true)
            let peaks = locations.recordingPeaks(capture).lastPathComponent
            let temporary = "\(peaks).sb-02b61b33-LRPMB3"
            for name in [temporary, "\(peaks).sb-zz", "\(peaks).tmp"] {
                try Data([0]).write(to: locations.recording.appending(path: name, directoryHint: .notDirectory))
            }
            let entries = try #require(RecordingEntries.list(locations))
            #expect(entries.peaksTemporaries == [temporary])
            #expect(entries.others == 2)
            #expect(
                SoakWitness.peaksProblems(entries.peaksTemporaries, known: [temporary], allowance: 0, red: false)
                    .isEmpty)
            #expect(SoakRules.peaksTemporariesAreRed == false, "WP-12 turns it, with the fix.")
            #expect(
                SoakWitness.peaksProblems(entries.peaksTemporaries, known: [temporary], allowance: 0, red: true).map(
                    \.code)
                    == ["peaks_temporaries_left"])
            #expect(
                SoakWitness.peaksProblems(entries.peaksTemporaries, known: [], allowance: 0, red: false).map(\.code)
                    == ["peaks_temporaries_beyond_kills"])
        }
    }
#endif
