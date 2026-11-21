#if os(macOS)
    import Foundation
    import KnotTestSupport
    import Synchronization
    import Testing

    /// The store's crash host, started for one kill test: its output is collected as it comes,
    /// and the test kills it with `SIGKILL` once it has stopped where the test wanted it.
    final class KillableHost: Sendable {
        private let process: Mutex<Process>
        private let output = Output()

        /// What the host printed so far.
        final class Output: Sendable {
            let text = Mutex("")
        }

        init(_ arguments: [String]) throws {
            guard let url = CrashHost.executableURL(named: "KnotStoreCrashHost") else {
                throw HostError.notBuilt
            }
            let process = Process()
            let pipe = Pipe()
            process.executableURL = url
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [output] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                output.text.withLock { $0 += String(decoding: data, as: UTF8.self) }
            }
            try process.run()
            self.process = Mutex(process)
        }

        enum HostError: Error { case notBuilt }

        var text: String { output.text.withLock { $0 } }

        var isRunning: Bool { process.withLock { $0.isRunning } }

        /// Waits, within the suites' limit, until the host printed `line` or ended.
        @discardableResult
        func waitFor(_ line: String, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
            await SuiteWait.until("the crash host to print \(line)", sourceLocation: sourceLocation) { [self] in
                text.contains(line) || !isRunning
            }
            return text.contains(line)
        }

        /// Kills the host where it stands and waits until it is gone.
        func kill() async {
            process.withLock { process in
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            await SuiteWait.until("the crash host to exit") { [self] in !isRunning }
        }

        /// Waits for the host to end by itself, and returns its status.
        func exitStatus() async -> Int32? {
            let ended = await SuiteWait.until("the crash host to end") { [self] in !isRunning }
            return ended ? process.withLock { $0.terminationStatus } : nil
        }
    }
#endif
