import Foundation
import KnotCore
import KnotFakes
import KnotTestSupport
import Synchronization
import Testing

@testable import KnotAudio

#if os(macOS)
    /// The recording state across two processes, the crash host's and the test's, as a widget
    /// reads what the app writes; and the press that meets a state a crash left.
    @Suite struct StateAcrossProcessesTests {
        /// A state one process writes, another reads whole, both ways: the crash host writes and
        /// the test reads, then the test writes and the crash host reads. `state-check` then runs
        /// the same check between two crash hosts, as it does in the iOS Simulator.
        @Test func theStateIsSharedAcrossTwoProcesses() async throws {
            let host = try #require(CrashHost.executableURL(named: "KnotAudioCrashHost"))
            let suite = try TestSuite()
            defer { suite.remove() }
            let store = DefaultsRecordingStateStore(defaults: suite.defaults)
            let capture = CaptureID(uuid: UUID())
            let launch = LaunchID(uuid: UUID())
            let written = try await HostRun.run(
                host,
                [
                    "state", "--write", "--suite", suite.name, "--phase", "recording", "--capture", "\(capture)",
                    "--launch", "\(launch)", "--started-s", "1795000000", "--heartbeat-s", "1795000001.5", "--pid",
                    "4242",
                ])
            #expect(written.status == 0, "\(written.output)")
            let expected = RecordingStateSnapshot(
                phase: .recording, captureID: capture, startedAt: Date(timeIntervalSince1970: 1_795_000_000),
                heartbeat: Date(timeIntervalSince1970: 1_795_000_001.5), ownerLaunch: launch, ownerPID: 4_242)
            #expect(store.read() == expected, "The test reads what the crash host wrote.")

            var stopping = expected
            stopping.phase = .stopping
            stopping.heartbeat = Date(timeIntervalSince1970: 1_795_000_002.25)
            store.write(stopping)
            let read = try await HostRun.run(host, ["state", "--read", "--suite", suite.name])
            #expect(read.status == 0)
            #expect(
                read.output.split(separator: "\n").first.map(String.init)
                    == "state phase stopping capture \(capture) launch \(launch) started 1795000000.000 "
                    + "heartbeat 1795000002.250 pid 4242",
                "The crash host reads what the test wrote: \(read.output)")

            let check = try await HostRun.run(host, ["state-check", "--dir", suite.folder.path])
            #expect(check.status == 0 && check.output.contains("state-check ok\n"), "\(check.output)")
        }

        /// `press-while-saved-recording-state-is-stale`: a press while the saved recording state is
        /// stale recovers the orphan and starts a new recording, with the live cue: a press never
        /// does nothing after a crash (docs/plan/WP-12.md, failure rules).
        ///
        /// The crash host records and writes its state, and is killed, so that the state and the
        /// orphan are real. In a later launch the store reads that state, stale by its heartbeat
        /// 3.5 s after it, as it is when the heartbeat runs more than three seconds ahead of now.
        /// The rule, applied here, with an idle recorder, recovers that capture and starts; carried
        /// out with the recorder's ports, recovery returns the dead capture to its last durable
        /// frame and clears its state, and the start runs to live with the live cue once, and the
        /// state is then the new capture's, recording, with this launch and a fresh heartbeat. In
        /// the other order, with the new recording live, recovery returns the dead one and leaves
        /// the live one and its state alone.
        ///
        /// The suites are named by paths in the tests' own folders, so that nothing reaches the
        /// account's Preferences folder. A process that first opens such a suite after another
        /// process made its file reads what is there, but does not read its own later writes back
        /// (measured on this Mac). So the later launch reads the dead launch's state from the
        /// suite the crash host wrote, as a store reads it, and carries it on in a suite of its
        /// own, where its recovery clears it and its new recording publishes.
        ///
        /// What this process's recorder publishes is read from the writes it made to its store,
        /// not read back from the suite. Once, at the strict pass of a gate, the suite read back
        /// the new recording's own "recording", written 63 ms before, though the stop, in the
        /// recorder's order, had written "stopping" and then idle in this process before it
        /// returned (WP-12b). The reads of what the crash host left stay reads of the suite: they
        /// are what another process sees.
        @Test("press-while-saved-recording-state-is-stale", .tags(.named))
        func aPressWhileTheSavedStateIsStale() async throws {
            let host = try #require(CrashHost.executableURL(named: "KnotAudioCrashHost"))
            let deadSuite = try TestSuite()
            let launchSuite = try TestSuite()
            defer {
                deadSuite.remove()
                launchSuite.remove()
            }
            let folder = try ScratchFolder()

            let dead = try #require(await Self.recordAndKill(host, folder: folder.url, suite: deadSuite.name))
            // The later launch's store reads what the dead launch left.
            let snapshot = DefaultsRecordingStateStore(defaults: deadSuite.defaults).read()
            #expect(snapshot.phase == .recording && snapshot.captureID == dead.capture, "\(snapshot)")
            #expect(snapshot.ownerPID == dead.pid)
            let saved = try #require(SavedRecordingState(snapshot))
            let heartbeat = saved.heartbeatAt
            let later = heartbeat.addingTimeInterval(3.5)
            #expect(saved.isStale(at: later) && saved.isStale(at: heartbeat.addingTimeInterval(-3.5)))
            #expect(!saved.isStale(at: heartbeat.addingTimeInterval(1)))
            let decision = RecordingPressRule.decide(Press(.tap, at: later), recorder: .idle, saved: saved)
            #expect(decision == .recoverOrphanThenStart(dead.capture))

            let store = WatchedStateStore(DefaultsRecordingStateStore(defaults: launchSuite.defaults))
            store.write(snapshot)
            let cues = RecordingCueEmitter()
            let live = LiveRecorder(
                locations: folder.locations, input: injected(),
                settings: LiveRecorder.Settings(syncInterval: .milliseconds(20)), cues: cues, state: store)
            let thisLaunch = LaunchID(uuid: UUID())
            let orphans = try await live.recoverOrphans(currentLaunch: thisLaunch)
            let orphan = try #require(orphans.first { $0.captureID == dead.capture }, "\(orphans)")
            #expect(orphan.ending == .recovered && orphan.frames >= dead.durable, "\(orphan), \(dead.durable) durable")
            #expect(store.writes.last?.snapshot == .idle, "Recovery cleared the dead launch's state.")
            let started = request(thisLaunch)
            let session = try await live.start(started)
            let now = try #require(store.writes.last?.snapshot)
            #expect(now.phase == .recording && now.captureID == started.captureID && now.ownerLaunch == thisLaunch)
            #expect(SavedRecordingState(now).map { !$0.isStale(at: Date()) } == true, "A fresh heartbeat: \(now)")
            _ = await session.stop()
            try await live.removeWorkingFile(of: started.captureID)
            try await live.removeWorkingFile(of: dead.capture)

            // The other order: the new recording is live first.
            let secondSuite = try TestSuite()
            defer { secondSuite.remove() }
            let second = try #require(await Self.recordAndKill(host, folder: folder.url, suite: secondSuite.name))
            let left = DefaultsRecordingStateStore(defaults: secondSuite.defaults).read()
            #expect(left.captureID == second.capture && left.phase == .recording, "\(left)")
            store.write(left)
            let nextLaunch = LaunchID(uuid: UUID())
            let next = request(nextLaunch)
            let running = try await live.start(next)
            let found = try await live.recoverOrphans(currentLaunch: nextLaunch)
            #expect(found.map(\.captureID) == [second.capture], "\(found)")
            #expect(found.first.map { $0.frames >= second.durable } == true)
            let published = store.writes.last?.snapshot
            #expect(
                published?.captureID == next.captureID && published?.phase == .recording,
                "Recovery left the live recording's state alone: \(store.phases)")
            await durable(atLeast: 1_600, of: running)
            let audio = await running.stop()
            #expect(audio.ending == .stopped && audio.frames >= 1_600, "The live recording was not touched: \(audio)")
            // The stop wrote idle before it returned.
            #expect(store.writes.last?.snapshot == .idle, "\(store.phases)")
            // Each start gave the live cue once: read once the recorder has handed over every cue.
            #expect(await cuesHandedOver(by: live, to: cues, refusing: next) == [.recordingLive, .recordingLive])
        }

        /// What a killed recording left: its capture, its process and its last durable count.
        struct Killed {
            let capture: CaptureID
            let pid: Int32
            let durable: Int64
        }

        /// Starts the crash host recording into `folder` with its state in `suite`, waits until
        /// it says some audio is durable, and kills it with SIGKILL, by the process ID it was
        /// started with, then waits for its end.
        static func recordAndKill(_ host: URL, folder: URL, suite: String) async throws -> Killed? {
            let witness = folder.appendingPathComponent("witness-\(UUID().uuidString)")
            let process = Process()
            let pipe = Pipe()
            process.executableURL = host
            process.arguments = [
                "record", "--dir", folder.path, "--witness", witness.path, "--state-suite", suite, "--seconds", "60",
            ]
            process.standardOutput = pipe
            let output = Collected()
            let finished = Collected()
            pipe.fileHandleForReading.readabilityHandler = { handle in output.append(handle.availableData) }
            process.terminationHandler = { _ in finished.append(Data([1])) }
            try process.run()
            let pid = process.processIdentifier
            defer {
                pipe.fileHandleForReading.readabilityHandler = nil
                try? pipe.fileHandleForReading.close()
            }
            @Sendable func lines() -> [Substring] {
                String(decoding: output.data, as: UTF8.self).split(separator: "\n")
            }
            let durable = await SuiteWait.until("a durable count from the crash host") {
                lines().contains { $0.hasPrefix("durable ") && !$0.hasSuffix(" 0") }
            }
            kill(pid, SIGKILL)
            _ = await SuiteWait.until("the killed crash host to end") { !finished.isEmpty }
            guard durable,
                let capture = lines().first(where: { $0.hasPrefix("capture ") }).flatMap({
                    CaptureID(String($0.dropFirst(8)))
                })
            else { return nil }
            let frames = lines().filter { $0.hasPrefix("durable ") }.compactMap {
                $0.split(separator: " ").last.flatMap { Int64($0) }
            }
            return Killed(capture: capture, pid: pid, durable: frames.max() ?? 0)
        }
    }
#endif
