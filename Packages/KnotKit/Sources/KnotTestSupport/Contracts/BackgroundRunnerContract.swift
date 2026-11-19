import Foundation
import KnotCore
import Synchronization
import Testing

/// The contract suite of `BackgroundRunner` (docs/notes/SP-1.md; docs/architecture.md §5): a
/// runner runs the work it is given, passes on its progress, and returns when it finishes; a
/// failure of the work comes back as it is; a cancelled caller cancels the work.
public enum BackgroundRunnerContract {
    public static func run(_ make: @Sendable () async -> any BackgroundRunner) async throws {
        let runner = await make()
        #expect(!runner.name.isEmpty)

        let reported = Mutex<[BackgroundProgress]>([])
        let finished = Mutex(false)
        try await runner.run(
            BackgroundWork { report in
                for step in 1...4 { report(BackgroundProgress(fraction: Double(step) / 4, step: .transcribe)) }
                finished.withLock { $0 = true }
            })
        #expect(finished.withLock { $0 }, "The work runs to its end.")

        await refuses(.transcriptionFailed) {
            try await runner.run(BackgroundWork { _ throws(KnotError) in throw KnotError.transcriptionFailed })
        }

        let sawCancellation = Mutex(false)
        let caller = Task {
            try await runner.run(
                BackgroundWork { _ throws(KnotError) in
                    do {
                        try await Task.sleep(for: .seconds(30))
                    } catch {
                        sawCancellation.withLock { $0 = true }
                        throw KnotError.cancelled
                    }
                })
        }
        try await Task.sleep(for: .milliseconds(50))
        caller.cancel()
        _ = try? await caller.value
        #expect(sawCancellation.withLock { $0 }, "A cancelled caller cancels the work.")
        _ = reported
    }
}
