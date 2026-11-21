#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import KnotStore
    import Synchronization

    /// What the child tells its parent: one line at a time, written straight to the pipe, with
    /// IDs, indexes, numbers, codes and hashes, never a word of a capture's text.
    enum Say {
        static func line(_ line: String) {
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }

        static func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data("KnotSoakChild: \(message)\n".utf8))
            exit(2)
        }
    }

    /// The one kill point a launch is armed with, and how many times the child passes it before
    /// it stops there. A kill point is named in one of three forms, so that a package that adds
    /// kill points to the soak can name points of its own without a change here:
    ///
    /// - `store:<point>`: a `StoreKillPoint`, inside the store's transaction (`StoreHooks`).
    /// - `log:<event>`: the moment a module of the child writes that log event, on any of the
    ///   logs the child gives its parts.
    /// - `step:<name>`: a moment of the child's own script: `after_begin`, `after_checkpoint`,
    ///   `after_end`.
    ///
    /// At its count the child says `stopped <point>` and waits there to be killed, holding the
    /// thread it stopped on: the store's writer inside its transaction, or the thread that wrote
    /// the log line.
    final class KillArming: Sendable {
        let point: String?
        private let count: Int
        private let passed = Mutex(0)

        init(point: String?, after count: Int) {
            self.point = point == "none" ? nil : point
            self.count = max(1, count)
        }

        /// Whether `name` is the armed point at its count. Counts the pass.
        private func isTheStop(_ name: String) -> Bool {
            guard name == point else { return false }
            return passed.withLock { passed in
                passed += 1
                return passed == count
            }
        }

        /// Passes `name` on a thread that may be held: the store's writer, or a log's caller.
        func pass(_ name: String) {
            guard isTheStop(name) else { return }
            Say.line("stopped \(name)")
            // The process ends here, by its parent's SIGKILL.
            while true { sleep(60) }
        }

        /// Passes one of the script's own steps, which wait without holding a thread.
        func step(_ name: String) async {
            guard isTheStop("step:\(name)") else { return }
            Say.line("stopped step:\(name)")
            while true { try? await Task.sleep(for: .seconds(60)) }
        }

        /// The store's seams, which pass each `StoreKillPoint` the store reaches.
        var storeHooks: StoreHooks {
            StoreHooks(reached: { [self] point in pass("store:\(point.rawValue)") })
        }
    }

    /// The child's log: every part writes its lines here. A line names its event, IDs and codes
    /// only, so the child may pass a line of an error on to its parent as it is, which helps a
    /// failed run say what happened. A log event can be the armed kill point.
    struct SoakLogSink: LogSink {
        let arming: KillArming
        /// Whether every line goes to the parent, not only errors: `KNOT_SOAK_ECHO_LOG=1`, to see
        /// what a launch did.
        let echoesAll = ProcessInfo.processInfo.environment["KNOT_SOAK_ECHO_LOG"] == "1"

        func write(_ record: LogRecord) {
            if echoesAll || record.level == .error || record.level == .fault {
                Say.line("log \(record.category.rawValue) \(record.line)")
            }
            arming.pass("log:\(record.event)")
        }
    }
#endif
