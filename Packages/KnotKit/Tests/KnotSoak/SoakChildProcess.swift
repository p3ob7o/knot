#if os(macOS)
    import Foundation
    import KnotTestSupport
    import Synchronization
    import Testing

    /// One launch of the soak's child, `KnotSoakChild`, as the parent started it. Its output is
    /// collected as it comes, on the pipe's own queue, and read as lines. The parent waits on it
    /// only through `SuiteWait`, which sleeps between looks, so no wait holds a thread of the
    /// cooperative pool. It kills only this process, by the process ID that starting it gave.
    final class SoakChildProcess: Sendable {
        private let process: Mutex<Process>
        let processID: Int32
        private let collected = Collected()

        /// What the child wrote, as it comes.
        final class Collected: Sendable {
            let output = Mutex(Data())
            /// Whether the child's standard output has reached its end: every line it printed is
            /// read.
            let outputEnded = Mutex(false)
            let errors = Mutex(Data())
        }

        enum StartError: Error { case notBuilt }

        init(arguments: [String]) throws {
            guard let url = CrashHost.executableURL(named: "KnotSoakChild") else { throw StartError.notBuilt }
            let process = Process()
            let out = Pipe()
            let err = Pipe()
            process.executableURL = url
            process.arguments = arguments
            process.standardOutput = out
            process.standardError = err
            let collected = collected
            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    collected.outputEnded.withLock { $0 = true }
                } else {
                    collected.output.withLock { $0.append(data) }
                }
            }
            err.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else {
                    collected.errors.withLock { $0.append(data) }
                }
            }
            try process.run()
            self.processID = process.processIdentifier
            self.process = Mutex(process)
        }

        /// A child that its test dropped, as when the test ended on an error, is killed by its own
        /// process ID: no child outlives its test.
        deinit {
            process.withLock { process in
                if process.isRunning { _ = Darwin.kill(processID, SIGKILL) }
            }
        }

        /// The whole lines the child printed so far.
        var lines: [String] {
            let text = collected.output.withLock { String(decoding: $0, as: UTF8.self) }
            var lines = text.components(separatedBy: "\n")
            lines.removeLast()  // what follows the last newline: nothing, or a line not ended yet
            return lines
        }

        /// What the child wrote to its standard error: its own failures, with codes only.
        var errorText: String { collected.errors.withLock { String(decoding: $0, as: UTF8.self) } }

        var isRunning: Bool { process.withLock { $0.isRunning } }

        /// The child's exit status, once it has ended by itself.
        var exitStatus: Int32? {
            process.withLock { process in
                guard !process.isRunning else { return nil }
                return process.terminationReason == .exit ? process.terminationStatus : nil
            }
        }

        /// Waits until `condition` holds of the lines so far, or the child has ended.
        func wait(for what: String, until condition: @escaping @Sendable ([String]) -> Bool) async {
            await SuiteWait.until("the soak's child to \(what)") { [self] in
                !isRunning || condition(lines)
            }
        }

        /// Waits for the child to end by itself, and for the last of its lines.
        func waitForExit() async {
            await SuiteWait.until("the soak's child to end") { [self] in
                !isRunning && collected.outputEnded.withLock { $0 }
            }
        }

        /// Kills the child where it stands with `SIGKILL`, by its own process ID, and waits until
        /// it is gone.
        func kill() async {
            process.withLock { process in
                if process.isRunning { _ = Darwin.kill(processID, SIGKILL) }
            }
            await SuiteWait.until("the soak's child to exit after its kill") { [self] in
                !isRunning && collected.outputEnded.withLock { $0 }
            }
        }
    }
#endif
