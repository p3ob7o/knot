#if os(macOS)
    import Foundation

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

        /// The time box of a soak run: 180 s, and four times that under the sanitizer. A sanitized
        /// child is several times slower, and on the hosted runner the soak's tests start their
        /// sanitized children together: there a run of 30 captures needed about 350 s, against
        /// 30 s on the build Mac (the nightly of 2026-11-24). A run its box cuts short is never
        /// green, whatever its box.
        static let box: Duration = .seconds(underThreadSanitizer ? 720 : 180)

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
