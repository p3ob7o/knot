#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCapture
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

    /// The names of the points the child can stop at. A name the child does not know is refused,
    /// at once, at any size of run: a point that matches nothing would never kill.
    ///
    /// - `store:<point>`: a `StoreKillPoint`, inside the store's transaction (`StoreHooks`).
    /// - `engine:<point>`: an `EngineKillPoint`, which the capture engine awaits with the
    ///   capture's ID. A package that adds the engine's kill points to the soak needs only a file
    ///   of its own in Tests/KnotSoak/.
    /// - `log:<event>`: the moment a part of the child writes that log event, on any of the logs
    ///   the child gives its parts. Only the events listed here.
    /// - `step:<name>`: a moment of the child's own script: `after_begin`, `after_checkpoint`,
    ///   `during_recording`, each time more of a recording is durable, and `after_end`.
    enum KillPointNames {
        static let steps: Set<String> = ["after_begin", "after_checkpoint", "during_recording", "after_end"]
        /// The log events of the engine, ingest and recovery that a kill point may name.
        static let logEvents: Set<String> = [
            "capture_began", "capture_ended", "capture_fell_back", "store_answered_late", "inbox_item_stored",
            "inbox_item_kept", "capture_recovered", "start_waits_for_open_capture",
            // The recorder's (WP-12): a start live, a stop's last sync done, a copy in place.
            "recording_live", "recording_stopped", "recording_converted",
        ]

        static var all: [String] {
            StoreKillPoint.allCases.map { "store:\($0.rawValue)" }
                + EngineKillPoint.allCases.map { "engine:\($0.rawValue)" }
                + logEvents.sorted().map { "log:\($0)" } + steps.sorted().map { "step:\($0)" }
        }

        static func isKnown(_ name: String) -> Bool { all.contains(name) }
    }

    /// The one kill point a launch is armed with, and how many times the child passes it before
    /// it stops there (`KillPointNames`).
    ///
    /// At its count the child says `stopped <point>` and waits there to be killed, holding the
    /// thread it stopped on: the store's writer inside its transaction, or the thread that wrote
    /// the log line.
    final class KillArming: Sendable {
        let point: String?
        private let count: Int
        private let passed = Mutex(0)

        /// How long a stopped child waits to be killed before it ends by itself: longer than any
        /// wait of its parent (`SuiteWait.limit`, ten minutes).
        static let stopLimit: TimeInterval = 15 * 60

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
            Say.line(SoakLine.stopped(name).rendered)
            // The process ends here, by its parent's SIGKILL, or by itself when its parent has gone
            // (`ParentWatch`) or after `stopLimit`.
            let until = Date().addingTimeInterval(Self.stopLimit)
            while Date() < until { sleep(1) }
            Say.fail("waited \(Int(Self.stopLimit)) s at \(name) and no parent killed it")
        }

        /// WP-15: whether the engine stops a write inside the item lock at `name`, its one point
        /// there, `engine:between_typed_manifest_and_payload`. At the armed count it answers true,
        /// and the engine's `reach` of the same point that follows, outside the lock, stops.
        func stopsInsideWrite(_ name: String) -> Bool {
            guard isTheStop(name) else { return false }
            stopDue.withLock { $0 = name }
            return true
        }

        /// The point `stopsInsideWrite` answered true for, which the next `reach` of it stops at.
        private let stopDue = Mutex<String?>(nil)

        /// Passes one of the script's own steps, which wait without holding a thread.
        func step(_ name: String) async {
            await reach("step:\(name)")
        }

        /// Passes a point that is reached in async code, the engine's or the script's: the stop
        /// waits without holding a thread.
        func reach(_ name: String) async {
            let due = stopDue.withLock { due in
                defer { if due == name { due = nil } }
                return due == name
            }
            guard due || isTheStop(name) else { return }
            Say.line(SoakLine.stopped(name).rendered)
            let until = Date().addingTimeInterval(Self.stopLimit)
            while Date() < until { try? await Task.sleep(for: .seconds(1)) }
            Say.fail("waited \(Int(Self.stopLimit)) s at \(name) and no parent killed it")
        }

        /// The store's seams, which pass each `StoreKillPoint` the store reaches.
        var storeHooks: StoreHooks {
            StoreHooks(reached: { [self] point in pass("store:\(point.rawValue)") })
        }
    }

    /// Ends the child when its parent goes: a child whose parent died, or that a parent started
    /// and dropped, must not live on. The parent's exit reaches the child as a kernel event.
    enum ParentWatch {
        /// Starts the watch. The caller keeps what it returns for as long as the child runs.
        static func start() -> any DispatchSourceProcess {
            let parent = getppid()
            guard parent > 1 else { Say.fail("started with no parent") }
            let watch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .global())
            watch.setEventHandler { Say.fail("its parent ended") }
            watch.resume()
            // The parent may have ended before the watch began.
            if getppid() != parent { Say.fail("its parent ended") }
            return watch
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
                Say.line(SoakLine.logged(record.category.rawValue + " " + record.line).rendered)
            }
            arming.pass("log:\(record.event)")
        }
    }
#endif
