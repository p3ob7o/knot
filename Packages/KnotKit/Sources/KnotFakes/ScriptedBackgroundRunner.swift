#if DEBUG || KNOT_FAKES
    import Foundation
    import KnotCore
    import Synchronization

    /// A `BackgroundRunner` that runs work straight through, and can be scripted to end its time
    /// in the middle, so that the running step is cancelled as a yield (docs/architecture.md §4).
    public final class ScriptedBackgroundRunner: BackgroundRunner {
        private struct State {
            var reports: [BackgroundProgress] = []
            var endAfterReports: Int?
            var timeEnded = false
            var running: Task<Void, any Error>?
        }

        public let name: String
        private let state = Mutex(State())

        public init(name: String = "scripted") {
            self.name = name
        }

        /// Ends the time once the work has reported progress `count` times.
        public func endTime(afterReports count: Int) {
            state.withLock { $0.endAfterReports = count }
        }

        /// Ends the time now, cancelling the work that runs.
        public func endTimeNow() {
            let task = state.withLock { state in
                state.timeEnded = true
                return state.running
            }
            task?.cancel()
        }

        /// Every progress report the work made, in order.
        public var reports: [BackgroundProgress] { state.withLock { $0.reports } }

        public func run(_ work: BackgroundWork) async throws(KnotError) {
            let report: @Sendable (BackgroundProgress) -> Void = { [self] progress in
                let task = state.withLock { state -> Task<Void, any Error>? in
                    state.reports.append(progress)
                    guard let limit = state.endAfterReports, state.reports.count >= limit else { return nil }
                    state.timeEnded = true
                    return state.running
                }
                task?.cancel()
            }
            let task = Task { () async throws -> Void in try await work.body(report) }
            let ended = state.withLock { state in
                state.running = task
                return state.timeEnded
            }
            if ended { task.cancel() }
            let result = await withTaskCancellationHandler {
                await task.result
            } onCancel: {
                task.cancel()
            }
            state.withLock { $0.running = nil }
            let timeEnded = state.withLock { $0.timeEnded }
            switch result {
            case .success:
                if timeEnded { throw KnotError.noBackgroundTime }
            case .failure(let error):
                if timeEnded { throw KnotError.noBackgroundTime }
                throw (error as? KnotError) ?? KnotError.unexpected
            }
        }
    }
#endif
