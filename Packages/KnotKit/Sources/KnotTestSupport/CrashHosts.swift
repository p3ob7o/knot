#if os(macOS)
    import Foundation

    /// Finds and runs the crash-host executables that kill tests start and kill
    /// (docs/architecture.md §17). They are built beside the test bundle.
    public enum CrashHost {
        public struct Run: Sendable {
            public let status: Int32
            public let output: String
        }

        /// The executable named `name`, built in the folder that holds the test bundle.
        public static func executableURL(named name: String) -> URL? {
            guard let products = productsFolder() else { return nil }
            let url = products.appendingPathComponent(name)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        /// The folder that holds the running test bundle. This code is linked into each
        /// test bundle, so the binary that holds it lies inside `<products>/<name>.xctest`.
        private static func productsFolder() -> URL? {
            var info = Dl_info()
            guard dladdr(#dsohandle, &info) != 0, let path = info.dli_fname else {
                return nil
            }
            var url = URL(fileURLWithPath: String(cString: path))
            while url.pathComponents.count > 1 {
                url.deleteLastPathComponent()
                if url.pathExtension == "xctest" {
                    return url.deletingLastPathComponent()
                }
            }
            return nil
        }

        /// Runs the executable to its end and returns its status and standard output.
        public static func run(_ url: URL, arguments: [String] = []) throws -> Run {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = url
            process.arguments = arguments
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Run(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }
    }
#endif
