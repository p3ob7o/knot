import Foundation

/// `knot-eval cleanup`, which scores cleanup. WP-14 builds it, and this file is WP-14's.
enum CleanupCommand {
    /// Runs the command with the arguments that follow `cleanup`, and returns the exit status.
    static func run(_ arguments: [String]) async -> Int32 {
        FileHandle.standardError.write(Data("knot-eval cleanup: not built yet. WP-14 builds it.\n".utf8))
        return 2
    }
}
