import Foundation
import KnotCore
import Synchronization
import Testing

/// A runner under test, with a way to end its time now, as the system does when the time it
/// granted runs out.
public struct BackgroundRunnerSubject: Sendable {
    public let runner: any BackgroundRunner
    /// Ends the runner's time now, while work runs.
    public let endTimeNow: @Sendable () async -> Void

    public init(runner: any BackgroundRunner, endTimeNow: @escaping @Sendable () async -> Void) {
        self.runner = runner
        self.endTimeNow = endTimeNow
    }
}

/// The contract suite of `BackgroundRunner` (docs/notes/SP-1.md; docs/architecture.md §5): a
/// runner runs the work it is given and returns when it finishes; a failure of the work comes
/// back as it is; a cancelled caller cancels the work, which yields; and when the time ends,
/// the work sees its cancellation and `run` throws `no_background_time`.
public enum BackgroundRunnerContract {
    public static func run(_ make: @Sendable () async -> BackgroundRunnerSubject) async throws {
        let subject = await make()
        let runner = subject.runner
        #expect(!runner.name.isEmpty)

        let finished = SuiteFlag()
        let ran = await SuiteWait.value("a run of short work to return") {
            await outcome(
                of: runner,
                BackgroundWork { report in
                    for step in 1...4 { report(BackgroundProgress(fraction: Double(step) / 4, step: .transcribe)) }
                    finished.set()
                })
        }
        #expect(ran == .some(nil), "The run returns without an error.")
        #expect(finished.isSet, "The work runs to its end.")

        let failed = await SuiteWait.value("a run of failing work to return") {
            await outcome(of: runner, BackgroundWork { _ throws(KnotError) in throw KnotError.transcriptionFailed })
        }
        #expect(failed??.code == KnotError.transcriptionFailed.code, "A failure of the work comes back as it is.")

        // A cancelled caller cancels the work, which yields, and the caller sees the yield
        // (finding 73).
        let sawCancellation = SuiteFlag()
        let started = SuiteFlag()
        let caller = Task { await outcome(of: runner, longWork(started: started, sawCancellation: sawCancellation)) }
        await SuiteWait.until("the runner to begin the work", { started.isSet })
        caller.cancel()
        let yielded = await SuiteWait.value("a cancelled caller's run to return") { await caller.value } ?? nil
        #expect(
            yielded?.code == KnotError.cancelled.code,
            "A cancelled caller sees the step yield: \(String(describing: yielded?.code)).")
        #expect(sawCancellation.isSet, "A cancelled caller cancels the work.")

        // The end of the time cancels the work, and `run` says the time ended (finding 73).
        let endSubject = await make()
        let sawEnd = SuiteFlag()
        let startedAgain = SuiteFlag()
        let endRunner = endSubject.runner
        let running = Task { await outcome(of: endRunner, longWork(started: startedAgain, sawCancellation: sawEnd)) }
        await SuiteWait.until("the runner to begin the work", { startedAgain.isSet })
        await endSubject.endTimeNow()
        let ended = await SuiteWait.value("the run to return once its time ended") { await running.value } ?? nil
        #expect(
            ended?.code == KnotError.noBackgroundTime.code, "The end of the time: \(String(describing: ended?.code)).")
        #expect(sawEnd.isSet, "The work sees its cancellation when the time ends.")
    }

    /// The error `run` threw, or `nil` when it returned.
    static func outcome(of runner: any BackgroundRunner, _ work: BackgroundWork) async -> KnotError? {
        do {
            try await runner.run(work)
            return nil
        } catch {
            return error
        }
    }

    /// Work that runs until it is cancelled, and then yields. Its wait is ten minutes, so that
    /// work that saw no cancellation is told apart by what happens, however loaded the machine.
    static func longWork(started: SuiteFlag, sawCancellation: SuiteFlag) -> BackgroundWork {
        BackgroundWork { _ throws(KnotError) in
            started.set()
            do {
                try await Task.sleep(for: .seconds(600))
            } catch {
                sawCancellation.set()
                throw KnotError.cancelled
            }
        }
    }

}

/// A flag the suites set from one task and read from another.
final class SuiteFlag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}
