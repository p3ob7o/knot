import Foundation
import KnotCore
import Synchronization

/// The `BackgroundRunner` for the foreground and the Mac (docs/architecture.md §5): the time
/// is the app's own while it runs in front, so work runs straight through.
///
/// Its time ends when the holder says so, as when the app leaves the foreground: `endTime()`
/// cancels the work running now, whose step yields, and `run` throws `no_background_time`.
/// A run that starts afterwards has its time again.
public final class StraightThroughRunner: BackgroundRunner {
    private struct Running {
        let task: Task<Result<Void, KnotError>, Never>
        var timeEnded = false
    }

    public let name: String
    private let running = Mutex<[UUID: Running]>([:])

    public init(name: String = "foreground") {
        self.name = name
    }

    public func run(_ work: BackgroundWork) async throws(KnotError) {
        let key = UUID()
        let task = Task { () -> Result<Void, KnotError> in
            do throws(KnotError) {
                // Nothing here asks for progress: the foreground's time does not run out by itself.
                try await work.body { _ in }
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        running.withLock { $0[key] = Running(task: task) }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        let timeEnded = running.withLock { $0.removeValue(forKey: key)?.timeEnded ?? false }
        if timeEnded { throw KnotError.noBackgroundTime }
        if case .failure(let error) = result { throw error }
    }

    /// Ends the time of the work running now: its task is cancelled, and each `run` throws
    /// `no_background_time`.
    public func endTime() {
        let tasks = running.withLock { running in
            for key in running.keys { running[key]?.timeEnded = true }
            return running.values.map(\.task)
        }
        for task in tasks { task.cancel() }
    }
}
