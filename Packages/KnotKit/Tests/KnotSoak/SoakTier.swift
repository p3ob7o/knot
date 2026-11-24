#if os(macOS)
    import Foundation

    @testable import KnotSoakChild

    /// Which tier runs the soak's tests. `scripts/verify.sh --soak` sets `KNOT_SOAK_SEED`, and its
    /// tests then run at full size: the capture ledger soak makes 500 captures from that seed, and
    /// the tests that only the soak tier runs, such as every order of the store's saves, run.
    /// Every other run of the package tests, `--quick` and the gate's `package-test`, runs the
    /// same harness on a short script from a fixed seed, so a broken harness fails there too, and
    /// no test of this target is ever skipped.
    enum SoakTier {
        /// The seed `--soak` passes, if this run is the soak tier's.
        static let seed: UInt64? = ProcessInfo.processInfo.environment["KNOT_SOAK_SEED"].flatMap(UInt64.init)

        static var isSoak: Bool { seed != nil }

        /// A run to repeat, as a report printed it (`CaptureLedgerSoak.Configuration.replay`):
        /// the capture ledger soak then runs that configuration, whichever test made it.
        static let replay: String? = ProcessInfo.processInfo.environment["KNOT_SOAK_REPLAY"]

        /// The capture ledger soak at this tier's size, or the run `KNOT_SOAK_REPLAY` names.
        static var ledger: CaptureLedgerSoak.Configuration? {
            if let replay { return CaptureLedgerSoak.Configuration.parse(replay) }
            return CaptureLedgerSoak.Configuration(
                seed: seed ?? 20_261_121, captures: isSoak ? 500 : 40, killPoints: SoakKillPoint.captures,
                everyPointKills: isSoak)
        }
    }

    /// Durations as the soak prints them, the same on every machine: seconds, with one decimal.
    enum SoakTime {
        /// Whether this test process runs under Thread Sanitizer: the sanitizer's runtime, and its
        /// entry `__tsan_init`, is loaded only into a build made with `--sanitize=thread`, as the
        /// nightly's step `tsan` makes the package's tests and the soak's child.
        static let underThreadSanitizer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil

        /// The time box of a soak run, from what its script asks: 60 s, one second for each typed
        /// capture and three for each recording, which records paced audio, converts it, and is
        /// transcribed and cleaned at a later launch's drain; never less than 180 s; and four times
        /// that under the sanitizer. A run its box cuts short is never green, whatever its box.
        ///
        /// Measured with the whole soak step, at the soak tier (2026-11-24): a run of 500 captures
        /// took 136 to 159 s on a quiet build Mac and 177 to 180 s at a gate with the owner at the
        /// Mac, and beside two builds one was cut at 184 s with 386 captures made, about 240 s for
        /// the whole; a run of 200 took 97 to 114 s quiet and 141 to 143 s beside two builds. Their
        /// boxes are now about 750 s and 340 s, as their scripts' mix of kinds gives. Under the sanitizer, on
        /// the hosted runner, the soak's tests start their sanitized children together, and a run
        /// of 30 captures needed about 350 s against 30 s on the build Mac (the nightly of
        /// 2026-11-24): 720 s.
        static func box(for script: SoakScript) -> Duration {
            let recordings = script.captures.filter { $0.kind == .voice }.count
            let typed = script.captures.count - recordings
            let seconds = max(180, 60 + typed + 3 * recordings)
            return .seconds(underThreadSanitizer ? 4 * seconds : seconds)
        }

        static func seconds(_ duration: Duration) -> String {
            let (seconds, attoseconds) = duration.components
            return String(format: "%.1f s", Double(seconds) + Double(attoseconds) / 1e18)
        }
    }

    /// The temporary folders of the soak, outside every worktree and every synced folder. With
    /// `KNOT_TEST_PRIVATE_ROOTS=1` each is written with `/private` in front, as the store's tests
    /// do, so that the whole soak runs once with its root in that form.
    enum SoakFolders {
        static func make(_ name: String) -> URL {
            let temporary = FileManager.default.temporaryDirectory
            let everyPrivate = ProcessInfo.processInfo.environment["KNOT_TEST_PRIVATE_ROOTS"] == "1"
            let base =
                everyPrivate && !temporary.path.hasPrefix("/private/")
                ? URL(fileURLWithPath: "/private" + temporary.path, isDirectory: true) : temporary
            let url = base.appending(
                path: "knot-soak-\(name)-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        static func remove(_ url: URL) {
            try? FileManager.default.removeItem(at: url)
        }
    }
#endif
