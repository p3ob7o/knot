import Foundation
import KnotCapture
import KnotCore
import KnotSpeech
import KnotStore

/// A step of the launch sequence (docs/architecture.md §13), in its order.
///
/// `recovery` holds three of the steps that §13 lists, in their order, through KnotCapture's
/// `LaunchRecovery.run(ingest:)`: recover the recordings earlier launches left, ingest
/// `Inbox/`, then finish the open captures of earlier launches. Ingest comes before the open
/// captures are finished, because the two orders give different results (§5). Its breaker
/// covers the three together.
public enum LaunchStep: String, Hashable, Sendable, Codable, CaseIterable {
    case openStore = "open_store"
    case recovery
    case resumeJobs = "resume_jobs"
    /// The store's purge, as housekeeping (`StorePurge`): once the store is open and recovery
    /// has run, never before.
    case purge
    case startSync = "start_sync"

    var moment: MeasuredMoment {
        switch self {
        case .openStore: .launchOpenStore
        case .recovery: .launchRecovery
        case .resumeJobs: .launchResumeJobs
        case .purge: .launchPurge
        case .startSync: .launchStartSync
        }
    }
}

/// Why a step did not run.
public enum LaunchSkip: String, Hashable, Sendable, Codable {
    /// The step needs the store, which did not open.
    case storeNotOpen = "store_not_open"
    /// The last two launches died inside the step.
    case diedTwice = "died_twice"
    /// Jobs and sync wait for recovery and ingest, which did not end.
    case recoveryDidNotEnd = "recovery_did_not_end"
    /// The `sync` gate of this build is closed.
    case gateClosed = "gate_closed"
    /// The sync switch is off on this device.
    case switchedOff = "switched_off"
    /// No package has filled the step's port in this build.
    case notInThisBuild = "not_in_this_build"
}

/// What one step came to.
public enum LaunchStepOutcome: Hashable, Sendable, Codable {
    case done
    case failed(ErrorCode)
    case skipped(LaunchSkip)
}

/// One step and what it came to.
public struct LaunchStepResult: Hashable, Sendable, Codable {
    public var step: LaunchStep
    public var outcome: LaunchStepOutcome
    /// How long the step ran, none for a step that was skipped.
    public var milliseconds: Int?
}

/// What the launch sequence did, step by step. It holds codes and counts, never content.
public struct LaunchReport: Hashable, Sendable, Codable {
    public var steps: [LaunchStepResult]
    /// What is wrong with the store when it did not open, which the stream shows.
    public var storeProblem: ErrorCode?
    /// How many captures recovery ended, by the outcome they ended with.
    public var recovered: [String: Int]

    public func outcome(of step: LaunchStep) -> LaunchStepOutcome? {
        steps.first { $0.step == step }?.outcome
    }
}

/// The launch sequence of the app process (docs/architecture.md §13).
///
/// The shell puts its capture surface on screen first and then starts the sequence, which
/// typing never waits for: until the store is open, a capture goes to `Inbox/`. The steps are
/// open the store, recovery, resume jobs, start sync. A step that fails is logged with its
/// code, and the steps that do not depend on it still run. The steps that need the store are
/// skipped when it did not open. Jobs and sync start only once recovery and ingest have ended.
/// A step in which the last two launches died is skipped and reported.
///
/// It runs once per launch: a second call waits for the first and returns its report.
public actor LaunchSequence {
    // Unowned: the composition holds its sequence, and lives as long as the process.
    private unowned let composition: LiveComposition
    private let breaker: LaunchBreaker
    private let log = KnotLog(.app)
    private var running: Task<LaunchReport, Never>?
    private var finished: LaunchReport?
    private var speechWatch: Task<Void, Never>?
    private var lifecycleWatch: Task<Void, Never>?

    init(composition: LiveComposition) {
        self.composition = composition
        self.breaker = LaunchBreaker(storage: composition.launchState)
    }

    /// Runs the steps, once.
    public func run() async -> LaunchReport {
        if let running { return await running.value }
        let task = Task { await self.steps() }
        running = task
        let report = await task.value
        finished = report
        return report
    }

    /// The report of the sequence once it has run, `nil` before.
    public func reportIfRun() -> LaunchReport? { finished }

    private func steps() async -> LaunchReport {
        watchLifecycle()
        var report = LaunchReport(steps: [], storeProblem: nil, recovered: [:])
        let opened = await step(.openStore, into: &report) { () throws(KnotError) -> Void in
            try await self.openStore()
        }
        if case .failed(let code) = opened { report.storeProblem = code }
        if case .skipped = opened {
            composition.gate.fail(KnotError.storeNotOpen)
            report.storeProblem = KnotError.storeNotOpen.code
        }
        guard case .open(let ports) = composition.gate.phase else {
            for step in [LaunchStep.recovery, .resumeJobs, .purge, .startSync] {
                skip(step, .storeNotOpen, into: &report)
            }
            return report
        }
        var recovered: [String: Int] = [:]
        let recovery = await step(.recovery, into: &report) { () throws(KnotError) -> Void in
            self.composition.recoveryLatch.recoveryRuns()
            recovered = try await self.recover(ports)
        }
        if recovery == .skipped(.diedTwice) { composition.recoveryLatch.recoverySkipped() }
        report.recovered = recovered
        guard recovery == .done else {
            skip(.resumeJobs, .recoveryDidNotEnd, into: &report)
            skip(.purge, .recoveryDidNotEnd, into: &report)
            skip(.startSync, .recoveryDidNotEnd, into: &report)
            return report
        }
        let jobs = await step(.resumeJobs, into: &report) { () throws(KnotError) -> Void in
            try await self.resumeJobs()
        }
        if jobs == .done { watchSpeech() }
        _ = await step(.purge, into: &report) { () throws(KnotError) -> Void in
            try await self.purge(ports)
        }
        await startSync(into: &report)
        return report
    }

    /// Runs `body` as `step`, unless its breaker skips it, and records what it came to.
    private func step(
        _ step: LaunchStep, into report: inout LaunchReport, _ body: () async throws(KnotError) -> Void
    ) async -> LaunchStepOutcome {
        if breaker.shouldSkip(step) {
            breaker.skip(step)
            skip(step, .diedTwice, into: &report)
            return .skipped(.diedTwice)
        }
        breaker.enter(step)
        let interval = composition.timings.begin(step.moment)
        let started = ContinuousClock.now
        let outcome: LaunchStepOutcome
        do throws(KnotError) {
            try await body()
            outcome = .done
            log.log(.info, Self.doneEvent(step))
        } catch {
            outcome = .failed(error.code)
            log.failure(error, Self.failedEvent(step))
        }
        interval.end()
        breaker.leave(step)
        let elapsed = ContinuousClock.now - started
        report.steps.append(
            LaunchStepResult(
                step: step, outcome: outcome,
                milliseconds: Int(
                    elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)))
        return outcome
    }

    private func skip(_ step: LaunchStep, _ reason: LaunchSkip, into report: inout LaunchReport) {
        report.steps.append(LaunchStepResult(step: step, outcome: .skipped(reason), milliseconds: nil))
        log.log(.notice, Self.skippedEvent(step), .flag(Self.reasonFlag(reason), true))
    }

    // MARK: The steps

    /// Opens the store with background time held: on iOS a suspension in the middle of an open,
    /// which may migrate, would be counted as a death inside the step.
    private func openStore() async throws(KnotError) {
        let held = await composition.backgroundTime.hold("knot.launch.open-store")
        do throws(KnotError) {
            try await openStoreHeld()
        } catch {
            await held.release()
            throw error
        }
        await held.release()
    }

    private func openStoreHeld() async throws(KnotError) {
        let composition = composition
        guard let locations = composition.locations else {
            let error = composition.locationsError ?? KnotError.storeNotOpen
            composition.gate.fail(error)
            throw error
        }
        let result: Result<OpenedStore, KnotError> = await withCheckedContinuation { continuation in
            // Opening reads and may migrate the database, which takes a thread for as long as it
            // takes: a thread of its own, never one of the cooperative pool.
            let thread = Thread {
                do throws(KnotError) {
                    let database = try StoreDatabase.open(
                        locations: locations, role: .app, clock: composition.clock, ids: composition.ids,
                        creation: StoreCreation(deviceID: composition.deviceID),
                        migrations: composition.seams.migrations ?? StoreSchema.migrations,
                        hooks: composition.seams.storeHooks)
                    continuation.resume(
                        returning: .success(
                            try OpenedStore(database: database, settingsSuite: composition.configuration.settingsSuite))
                    )
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
            thread.name = "knot.launch.open-store"
            thread.start()
        }
        switch result {
        case .success(let opened):
            _ = composition.gate.open(opened)
            if opened.database.deviceID != composition.deviceID {
                DeviceIdentity(storage: composition.launchState).adopt(opened.database.deviceID)
                log.log(.notice, "launch_device_id_from_store")
            }
        case .failure(let error):
            composition.gate.fail(error)
            throw error
        }
    }

    private func recover(_ ports: StoreGate.Ports) async throws(KnotError) -> [String: Int] {
        guard let locations = composition.locations, let ingest = composition.ingest else {
            throw KnotError.storeNotOpen
        }
        let recovery = LaunchRecovery(
            notes: ports.notes, assets: ports.assets, recorder: composition.environment.recorder,
            queue: composition.environment.queue, launchID: composition.launchID, locations: locations,
            layer: composition.layer)
        let outcomes = try await recovery.run(ingest: ingest)
        var counts: [String: Int] = [:]
        for outcome in outcomes.values {
            let name: String =
                switch outcome {
                case .ended(.stored): "stored"
                case .ended(.discardedEmpty): "discarded_empty"
                case .ended(.failed): "failed"
                case .ended(.open): "open"
                case .workingFileRemoved: "working_file_removed"
                case .kept: "kept"
                case .movedToInbox: "moved_to_inbox"
                }
            counts[name, default: 0] += 1
        }
        log.log(.info, "launch_recovered", .number("captures", outcomes.count))
        return counts
    }

    /// The store's purge, and the removal of the files it names.
    private func purge(_ ports: StoreGate.Ports) async throws(KnotError) {
        guard let locations = composition.locations else { throw KnotError.storeNotOpen }
        let report = try await StorePurge(
            notes: ports.notes, assets: ports.assets, locations: locations, layer: composition.layer,
            clock: composition.clock
        ).run()
        log.log(
            .info, "launch_purged", .number("removed", report.removed), .number("files_removed", report.filesRemoved),
            .number("files_left", report.filesLeft))
    }

    /// Wires the app's foreground events to the calls the modules expose for the app coming
    /// forward (docs/architecture.md §5): the transcriber checks its readiness again, `Inbox/` is
    /// ingested (docs/architecture.md §6, rule 2), and the queue is woken. Each of them holds its
    /// own order: ingest holds the earlier launches' items until recovery has run, and the queue
    /// runs nothing before the launch releases it.
    private func watchLifecycle() {
        guard lifecycleWatch == nil else { return }
        let events = composition.environment.lifecycle.events()
        // Weak: a composition that is dropped, as a test drops one to stand for a kill, must not
        // be kept alive by its own watch, with a queue that could still run jobs.
        lifecycleWatch = Task { [weak composition = self.composition] in
            for await event in events where event == .cameForward {
                guard let composition else { return }
                await KnotSpeechLive.appCameForward(composition.environment)
                if case .open = composition.gate.phase { _ = await composition.ingest?.ingestAll() }
                await composition.gatedQueue?.wake()
            }
        }
    }

    private func resumeJobs() async throws(KnotError) {
        guard let queue = composition.gatedQueue else { throw KnotError.portUnavailable }
        try await queue.resume()
        await queue.release()
    }

    /// Wakes the queue when the speech model arrives, and asks for the model once when it is
    /// not installed (docs/architecture.md §9). The install is refused in a test, an agent's
    /// process and a simulator by KnotSpeech's own policy.
    private func watchSpeech() {
        let environment = composition.environment
        guard let queue = composition.gatedQueue, speechWatch == nil else { return }
        speechWatch = Task {
            for await readiness in KnotSpeechLive.readinessChanges(environment) where readiness == .ready {
                await queue.wake()
            }
        }
        guard composition.seams.installSpeechModel else { return }
        let log = log
        Task {
            guard await environment.transcriber.readiness() == .notInstalled else { return }
            do throws(KnotError) {
                try await environment.transcriber.install { _ in }
                await queue.wake()
            } catch {
                log.failure(error, "launch_speech_model_not_installed", level: .notice)
            }
        }
    }

    private func startSync(into report: inout LaunchReport) async {
        let environment = composition.environment
        guard environment.gates.isOpen(.sync) else {
            skip(.startSync, .gateClosed, into: &report)
            return
        }
        guard !(environment.sync is UnavailableSyncEngine) else {
            skip(.startSync, .notInThisBuild, into: &report)
            return
        }
        guard (try? await environment.settings.load())?.syncEnabled != false else {
            skip(.startSync, .switchedOff, into: &report)
            return
        }
        _ = await step(.startSync, into: &report) { () throws(KnotError) -> Void in
            await environment.sync.start()
        }
    }

    // MARK: Log events, which the facade takes only as names written in the code

    private static func doneEvent(_ step: LaunchStep) -> StaticString {
        switch step {
        case .openStore: "launch_open_store_done"
        case .recovery: "launch_recovery_done"
        case .resumeJobs: "launch_resume_jobs_done"
        case .purge: "launch_purge_done"
        case .startSync: "launch_start_sync_done"
        }
    }

    private static func failedEvent(_ step: LaunchStep) -> StaticString {
        switch step {
        case .openStore: "launch_open_store_failed"
        case .recovery: "launch_recovery_failed"
        case .resumeJobs: "launch_resume_jobs_failed"
        case .purge: "launch_purge_failed"
        case .startSync: "launch_start_sync_failed"
        }
    }

    private static func skippedEvent(_ step: LaunchStep) -> StaticString {
        switch step {
        case .openStore: "launch_open_store_skipped"
        case .recovery: "launch_recovery_skipped"
        case .resumeJobs: "launch_resume_jobs_skipped"
        case .purge: "launch_purge_skipped"
        case .startSync: "launch_start_sync_skipped"
        }
    }

    private static func reasonFlag(_ reason: LaunchSkip) -> StaticString {
        switch reason {
        case .storeNotOpen: "store_not_open"
        case .diedTwice: "died_twice"
        case .recoveryDidNotEnd: "recovery_did_not_end"
        case .gateClosed: "gate_closed"
        case .switchedOff: "switched_off"
        case .notInThisBuild: "not_in_this_build"
        }
    }
}
